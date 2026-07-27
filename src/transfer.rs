use std::{
    cmp,
    io::{self, IsTerminal, Write},
    net::{Ipv4Addr, SocketAddr, SocketAddrV4},
    path::{Component, Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use anyhow::{anyhow, bail, Context, Result};
use indicatif::{MultiProgress, ProgressBar, ProgressStyle};
use quinn::{Endpoint, Incoming};
use sha2::{Digest, Sha256};
use tokio::{
    fs::{self, File, OpenOptions},
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    sync::{Mutex, Semaphore},
    time::timeout,
};
use tracing::{info, warn};

use crate::{
    discovery::{Advertisement, Peer},
    protocol::{
        read_message, write_message, FileRequest, ManifestEntry, TransferRequest, TransferResponse,
        DIGEST_LENGTH, VERSION,
    },
    security::{pinned_client_config, Identity},
    ui::{format_bytes, plural_suffix, print_receiver_ready},
};

const CHUNK_SIZE: usize = 128 * 1024;
const CONTROL_TIMEOUT: Duration = Duration::from_secs(15);
const CHUNK_TIMEOUT: Duration = Duration::from_secs(60);
const MAX_ACTIVE_TRANSFERS: usize = 8;

pub(crate) async fn send_files(paths: &[PathBuf], peer: &Peer) -> Result<()> {
    let files = collect_files(paths).await?;
    let total_size = files.iter().try_fold(0_u64, |total, file| {
        total
            .checked_add(file.size)
            .ok_or_else(|| anyhow!("selected files exceed supported total size"))
    })?;
    let request = TransferRequest {
        version: VERSION,
        files: files
            .iter()
            .map(|file| ManifestEntry {
                path: file.relative_path.clone(),
                size: file.size,
            })
            .collect(),
    };

    println!(
        "Preparing {} file{} ({}) for {} [{}]",
        files.len(),
        plural_suffix(files.len()),
        format_bytes(total_size),
        peer.name,
        peer.id
    );
    println!("Connecting to {}...", peer.address);

    let mut endpoint = Endpoint::client(SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 0).into())?;
    endpoint.set_default_client_config(pinned_client_config(peer.fingerprint)?);
    let connection = endpoint
        .connect(peer.address, "gitler.local")?
        .await
        .with_context(|| format!("failed to connect to {} at {}", peer.name, peer.address))?;
    let (mut control_send, mut control_receive) = connection.open_bi().await?;
    write_message(&mut control_send, &request).await?;
    control_send.finish()?;

    let response: TransferResponse = read_message(&mut control_receive).await?;
    if !response.accepted {
        bail!("receiver rejected transfer: {}", response.message);
    }
    println!("Receiver accepted transfer. Sending files...");

    for (index, file) in files.iter().enumerate() {
        let (mut send, mut receive) = connection.open_bi().await?;
        write_message(&mut send, &FileRequest { index }).await?;
        let progress = transfer_progress(file.size, format!("sending {}", file.relative_path))?;
        let result = stream_file(&file.source_path, file.size, &mut send, &progress).await;
        if result.is_err() {
            progress.finish_and_clear();
        }
        result?;
        send.finish()?;

        let response: TransferResponse = read_message(&mut receive).await?;
        if !response.accepted {
            progress.finish_and_clear();
            bail!(
                "receiver rejected {}: {}",
                file.relative_path,
                response.message
            );
        }
        progress.finish_with_message(format!("sent {}", file.relative_path));
    }

    connection.close(0_u32.into(), b"transfer complete");
    endpoint.wait_idle().await;
    println!(
        "Transfer complete: {} file{} sent.",
        files.len(),
        plural_suffix(files.len())
    );
    Ok(())
}

struct SendFile {
    source_path: PathBuf,
    relative_path: String,
    size: u64,
}

async fn collect_files(paths: &[PathBuf]) -> Result<Vec<SendFile>> {
    if paths.is_empty() {
        bail!("at least one file or directory is required");
    }

    let mut files = Vec::new();
    for path in paths {
        let metadata = fs::metadata(path)
            .await
            .with_context(|| format!("failed to inspect {}", path.display()))?;
        if metadata.is_file() {
            let relative_path = path_file_name(path)?;
            files.push(SendFile {
                source_path: path.clone(),
                relative_path,
                size: metadata.len(),
            });
        } else if metadata.is_dir() {
            let root = path_file_name(path)?;
            collect_directory_files(path, Path::new(&root), &mut files).await?;
        } else {
            bail!("{} is not a regular file or directory", path.display());
        }
    }

    if files.is_empty() {
        bail!("selected directories contain no files");
    }
    let mut paths = std::collections::HashSet::new();
    for file in &files {
        if !paths.insert(file.relative_path.clone()) {
            bail!(
                "selected inputs contain duplicate path `{}`",
                file.relative_path
            );
        }
    }
    Ok(files)
}

async fn collect_directory_files(
    directory: &Path,
    relative_directory: &Path,
    files: &mut Vec<SendFile>,
) -> Result<()> {
    let mut entries = fs::read_dir(directory)
        .await
        .with_context(|| format!("failed to read {}", directory.display()))?;
    while let Some(entry) = entries.next_entry().await? {
        let source_path = entry.path();
        let relative_path = relative_directory.join(entry.file_name());
        let metadata = entry.metadata().await?;
        if metadata.is_file() {
            files.push(SendFile {
                relative_path: manifest_path(&relative_path)?,
                source_path,
                size: metadata.len(),
            });
        } else if metadata.is_dir() {
            Box::pin(collect_directory_files(&source_path, &relative_path, files)).await?;
        }
    }
    Ok(())
}

fn path_file_name(path: &Path) -> Result<String> {
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty())
        .ok_or_else(|| anyhow!("path name must be valid UTF-8"))?;
    Ok(name.to_owned())
}

fn manifest_path(path: &Path) -> Result<String> {
    let mut parts = Vec::new();
    for component in path.components() {
        let Component::Normal(part) = component else {
            bail!("transfer path must contain only normal path components");
        };
        let part = part
            .to_str()
            .ok_or_else(|| anyhow!("transfer path must be valid UTF-8"))?;
        validate_file_name(part)?;
        parts.push(part);
    }
    if parts.is_empty() {
        bail!("transfer path must not be empty");
    }
    Ok(parts.join("/"))
}

pub(crate) async fn receive_files(
    output: PathBuf,
    name: String,
    once: bool,
    max_size: u64,
    accept_all: bool,
    bind: Ipv4Addr,
    port: u16,
) -> Result<()> {
    fs::create_dir_all(&output)
        .await
        .with_context(|| format!("failed to create {}", output.display()))?;
    let identity = Identity::generate()?;
    let endpoint = Endpoint::server(identity.server_config, SocketAddrV4::new(bind, port).into())?;
    let local_address = endpoint.local_addr()?;
    let mut advertisement =
        Advertisement::publish(&name, local_address.port(), identity.fingerprint, bind)?;
    let progress = Arc::new(MultiProgress::new());
    let approval_lock = Arc::new(Mutex::new(()));

    print_receiver_ready(
        &name,
        &output,
        local_address.port(),
        once,
        max_size,
        accept_all,
    );
    if !accept_all && !io::stdin().is_terminal() {
        eprintln!(
            "warning: interactive approval needs a terminal; incoming transfers will be rejected.\n         Use --accept-all only on a trusted network."
        );
    }

    if once {
        let incoming = endpoint
            .accept()
            .await
            .ok_or_else(|| anyhow!("QUIC endpoint closed before a connection arrived"))?;
        let result = handle_connection(
            incoming,
            &output,
            max_size,
            accept_all,
            &progress,
            &approval_lock,
        )
        .await;
        advertisement.shutdown();
        endpoint.close(0_u32.into(), b"receiver stopped");
        endpoint.wait_idle().await;
        return result;
    }

    let permits = Arc::new(Semaphore::new(MAX_ACTIVE_TRANSFERS));
    loop {
        tokio::select! {
            incoming = endpoint.accept() => {
                let Some(incoming) = incoming else {
                    break;
                };
                let permit = match Arc::clone(&permits).try_acquire_owned() {
                    Ok(permit) => permit,
                    Err(_) => {
                        incoming.refuse();
                        warn!("refused transfer because receiver is busy");
                        continue;
                    }
                };
                let output = output.clone();
                let progress = Arc::clone(&progress);
                let approval_lock = Arc::clone(&approval_lock);
                tokio::spawn(async move {
                    let _permit = permit;
                    if let Err(error) = handle_connection(
                        incoming,
                        &output,
                        max_size,
                        accept_all,
                        &progress,
                        &approval_lock,
                    )
                    .await
                    {
                        warn!(%error, "incoming transfer failed");
                    }
                });
            }
            signal = tokio::signal::ctrl_c() => {
                signal.context("failed to listen for Ctrl+C")?;
                break;
            }
        }
    }

    advertisement.shutdown();
    endpoint.close(0_u32.into(), b"receiver stopped");
    endpoint.wait_idle().await;
    Ok(())
}

async fn stream_file<W>(path: &Path, size: u64, send: &mut W, progress: &ProgressBar) -> Result<()>
where
    W: AsyncWrite + Unpin,
{
    let mut file = File::open(path).await?;
    let mut remaining = size;
    let mut buffer = vec![0_u8; CHUNK_SIZE];
    let mut hasher = Sha256::new();

    while remaining > 0 {
        let wanted = cmp::min(remaining, CHUNK_SIZE as u64) as usize;
        let read = file.read(&mut buffer[..wanted]).await?;
        if read == 0 {
            bail!("file changed while sending: reached end before declared size");
        }
        hasher.update(&buffer[..read]);
        timeout(CHUNK_TIMEOUT, send.write_all(&buffer[..read]))
            .await
            .context("receiver stalled while file data was being sent")??;
        remaining -= read as u64;
        progress.inc(read as u64);
    }

    let mut extra = [0_u8; 1];
    if file.read(&mut extra).await? != 0 {
        bail!("file changed while sending: grew beyond declared size");
    }

    let digest: [u8; DIGEST_LENGTH] = hasher.finalize().into();
    timeout(CONTROL_TIMEOUT, send.write_all(&digest))
        .await
        .context("receiver stalled before file digest was sent")??;
    Ok(())
}

async fn handle_connection(
    incoming: Incoming,
    output: &Path,
    max_size: u64,
    accept_all: bool,
    progress: &Arc<MultiProgress>,
    approval_lock: &Arc<Mutex<()>>,
) -> Result<()> {
    let connection = incoming.await?;
    let remote = connection.remote_address();
    info!(%remote, "QUIC connection established");
    let (mut control_send, mut control_receive) = timeout(CONTROL_TIMEOUT, connection.accept_bi())
        .await
        .context("sender did not open a transfer stream in time")??;
    let request: TransferRequest = timeout(CONTROL_TIMEOUT, read_message(&mut control_receive))
        .await
        .context("sender did not provide transfer metadata in time")??;

    if let Err(error) = validate_request(&request, max_size) {
        write_message(
            &mut control_send,
            &TransferResponse::rejected(error.to_string()),
        )
        .await?;
        control_send.finish()?;
        return Err(error);
    }

    if !accept_all && !io::stdin().is_terminal() {
        let error = anyhow!(
            "receiver requires interactive approval, but standard input is not a terminal; rerun in a terminal or use --accept-all only on a trusted network"
        );
        write_message(
            &mut control_send,
            &TransferResponse::rejected(error.to_string()),
        )
        .await?;
        control_send.finish()?;
        return Err(error);
    }

    if !accept_all && !request_approval(remote, &request, approval_lock).await? {
        let error = anyhow!("transfer was declined by receiver");
        write_message(
            &mut control_send,
            &TransferResponse::rejected(error.to_string()),
        )
        .await?;
        control_send.finish()?;
        return Err(error);
    }

    write_message(
        &mut control_send,
        &TransferResponse::accepted(format!("receiving {} files", request.files.len())),
    )
    .await?;
    control_send.finish()?;

    for (expected_index, entry) in request.files.iter().enumerate() {
        let (mut send, mut receive) = timeout(CONTROL_TIMEOUT, connection.accept_bi())
            .await
            .context("sender did not open a file stream in time")??;
        let file_request: FileRequest = timeout(CONTROL_TIMEOUT, read_message(&mut receive))
            .await
            .context("sender did not identify file stream in time")??;
        if file_request.index != expected_index {
            let error = anyhow!(
                "received file stream {} but expected {}",
                file_request.index,
                expected_index
            );
            write_message(&mut send, &TransferResponse::rejected(error.to_string())).await?;
            send.finish()?;
            return Err(error);
        }

        let (mut file, destination) = match create_destination_for_path(output, &entry.path).await {
            Ok(destination) => destination,
            Err(error) => {
                write_message(
                    &mut send,
                    &TransferResponse::rejected(format!("cannot create destination: {error}")),
                )
                .await?;
                send.finish()?;
                return Err(error.into());
            }
        };
        let bar = progress.add(transfer_progress(
            entry.size,
            format!("receiving {}", entry.path),
        )?);
        let receive_result = receive_body(&mut receive, &mut file, entry.size, &bar).await;
        drop(file);

        if let Err(error) = receive_result {
            bar.finish_and_clear();
            let _ = fs::remove_file(&destination).await;
            let _ = write_message(&mut send, &TransferResponse::rejected(error.to_string())).await;
            let _ = send.finish();
            return Err(error);
        }

        write_message(&mut send, &TransferResponse::accepted("integrity verified")).await?;
        send.finish()?;
        bar.finish_with_message(format!("received {}", destination.display()));
        println!("Saved: {}", destination.display());
    }

    connection.closed().await;
    Ok(())
}

async fn receive_body<R>(
    receive: &mut R,
    file: &mut File,
    size: u64,
    progress: &ProgressBar,
) -> Result<()>
where
    R: AsyncRead + Unpin,
{
    let mut remaining = size;
    let mut buffer = vec![0_u8; CHUNK_SIZE];
    let mut hasher = Sha256::new();

    while remaining > 0 {
        let wanted = cmp::min(remaining, CHUNK_SIZE as u64) as usize;
        timeout(CHUNK_TIMEOUT, receive.read_exact(&mut buffer[..wanted]))
            .await
            .context("sender stalled while file data was being received")?
            .context("sender ended file data early")?;
        file.write_all(&buffer[..wanted]).await?;
        hasher.update(&buffer[..wanted]);
        remaining -= wanted as u64;
        progress.inc(wanted as u64);
    }

    let mut expected_digest = [0_u8; DIGEST_LENGTH];
    timeout(CONTROL_TIMEOUT, receive.read_exact(&mut expected_digest))
        .await
        .context("sender stalled before providing file digest")?
        .context("sender omitted file digest")?;
    let actual_digest: [u8; DIGEST_LENGTH] = hasher.finalize().into();
    if actual_digest != expected_digest {
        bail!("SHA-256 digest mismatch");
    }

    file.flush().await?;
    Ok(())
}

async fn request_approval(
    remote: SocketAddr,
    request: &TransferRequest,
    approval_lock: &Arc<Mutex<()>>,
) -> Result<bool> {
    let file_count = request.files.len();
    let total_size = request.files.iter().try_fold(0_u64, |total, file| {
        total
            .checked_add(file.size)
            .ok_or_else(|| anyhow!("transfer size exceeds supported total"))
    })?;
    let preview: Vec<String> = request
        .files
        .iter()
        .take(5)
        .map(|file| format!("  • {} ({})", file.path, format_bytes(file.size)))
        .collect();
    let remaining = file_count.saturating_sub(preview.len());
    let _guard = approval_lock.lock().await;
    tokio::task::spawn_blocking(move || -> io::Result<bool> {
        if !io::stdin().is_terminal() {
            return Ok(false);
        }

        println!("\nIncoming transfer request");
        println!("  From:  {remote}");
        println!(
            "  Total: {} file{} ({})",
            file_count,
            plural_suffix(file_count),
            format_bytes(total_size)
        );
        println!("  Files:");
        for file in preview {
            println!("{file}");
        }
        if remaining > 0 {
            println!("  • and {remaining} more");
        }
        print!("\nAccept this transfer? [y/N] ");
        io::stdout().flush()?;
        let mut answer = String::new();
        io::stdin().read_line(&mut answer)?;
        Ok(matches!(
            answer.trim().to_ascii_lowercase().as_str(),
            "y" | "yes"
        ))
    })
    .await
    .context("receiver approval task failed")?
    .context("failed to read receiver approval")
}

fn validate_request(request: &TransferRequest, max_size: u64) -> Result<()> {
    if request.version != VERSION {
        bail!(
            "unsupported protocol version {}; expected {}",
            request.version,
            VERSION
        );
    }
    if request.files.is_empty() {
        bail!("transfer manifest contains no files");
    }

    let mut paths = std::collections::HashSet::new();
    for file in &request.files {
        validate_manifest_path(&file.path)?;
        if file.size > max_size {
            bail!("file `{}` exceeds receiver size limit", file.path);
        }
        if !paths.insert(&file.path) {
            bail!("transfer manifest contains duplicate path `{}`", file.path);
        }
    }
    Ok(())
}

fn validate_manifest_path(path: &str) -> Result<()> {
    if path.is_empty() || path.len() > 4_096 {
        bail!("transfer path must contain 1 to 4096 UTF-8 bytes");
    }
    if path.contains('\\') {
        bail!("transfer path must use forward-slash separators");
    }
    if path.split('/').any(|component| component.is_empty()) {
        bail!("transfer path contains an empty component");
    }
    for component in path.split('/') {
        validate_file_name(component)?;
    }
    Ok(())
}

fn validate_file_name(file_name: &str) -> Result<()> {
    if file_name.is_empty() || file_name.len() > 255 {
        bail!("file name must contain 1 to 255 UTF-8 bytes");
    }
    if file_name.chars().any(char::is_control) {
        bail!("file name contains control characters");
    }
    if file_name.chars().any(|character| {
        matches!(
            character,
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|'
        )
    }) || file_name.ends_with(' ')
        || file_name.ends_with('.')
    {
        bail!("file name contains a reserved character or suffix");
    }
    if is_reserved_windows_name(file_name) {
        bail!("file name is reserved on Windows");
    }

    let mut components = Path::new(file_name).components();
    match (components.next(), components.next()) {
        (Some(Component::Normal(_)), None) if file_name != "." && file_name != ".." => Ok(()),
        _ => bail!("file name must not contain a path"),
    }
}

fn is_reserved_windows_name(file_name: &str) -> bool {
    let base = file_name
        .split('.')
        .next()
        .unwrap_or_default()
        .to_ascii_uppercase();
    matches!(base.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        || base
            .strip_prefix("COM")
            .or_else(|| base.strip_prefix("LPT"))
            .is_some_and(|number| {
                matches!(number, "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9")
            })
}

async fn create_destination_for_path(
    output: &Path,
    relative_path: &str,
) -> io::Result<(File, PathBuf)> {
    let relative_path = Path::new(relative_path);
    let parent = relative_path.parent().unwrap_or_else(|| Path::new(""));
    let file_name = relative_path
        .file_name()
        .and_then(|file_name| file_name.to_str())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "invalid destination name"))?;
    let directory = output.join(parent);
    fs::create_dir_all(&directory).await?;
    create_destination(&directory, file_name).await
}

async fn create_destination(output: &Path, file_name: &str) -> io::Result<(File, PathBuf)> {
    for index in 0..10_000_u32 {
        let candidate = output.join(collision_name(file_name, index));
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&candidate)
            .await
        {
            Ok(file) => return Ok((file, candidate)),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error),
        }
    }

    Err(io::Error::new(
        io::ErrorKind::AlreadyExists,
        "too many files share this name",
    ))
}

fn collision_name(file_name: &str, index: u32) -> String {
    if index == 0 {
        return file_name.to_owned();
    }

    let path = Path::new(file_name);
    let stem = path
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or(file_name);
    match path.extension().and_then(|extension| extension.to_str()) {
        Some(extension) if !extension.is_empty() => format!("{stem} ({index}).{extension}"),
        _ => format!("{stem} ({index})"),
    }
}

fn transfer_progress(length: u64, message: String) -> Result<ProgressBar> {
    let style = ProgressStyle::with_template(
        "{spinner:.green} {msg} [{bar:32.cyan/blue}] {bytes}/{total_bytes} {bytes_per_sec} {eta}",
    )?
    .progress_chars("=>-");
    Ok(ProgressBar::new(length)
        .with_style(style)
        .with_message(message))
}

#[cfg(test)]
mod tests {
    use std::{
        collections::HashSet,
        net::{Ipv4Addr, SocketAddrV4},
        path::PathBuf,
        sync::Arc,
        time::Duration,
    };

    use sha2::{Digest, Sha256};
    use tokio::{io::AsyncWriteExt, task::JoinSet, time::timeout};

    use crate::{discovery::Peer, security::Identity};

    use super::{
        collect_files, collision_name, create_destination, handle_connection, receive_body,
        send_files, stream_file, validate_file_name, validate_manifest_path, validate_request,
        CHUNK_SIZE,
    };

    async fn receive_payload(payload: &[u8]) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let destination = directory.path().join("received.bin");
        let (mut writer, mut reader) = tokio::io::duplex(CHUNK_SIZE * 2);
        let payload = payload.to_vec();
        let size = payload.len() as u64;
        let sender = tokio::spawn(async move {
            let digest: [u8; 32] = Sha256::digest(&payload).into();
            writer.write_all(&payload).await?;
            writer.write_all(&digest).await?;
            writer.shutdown().await
        });
        let mut file = tokio::fs::File::create(&destination).await?;

        receive_body(
            &mut reader,
            &mut file,
            size,
            &indicatif::ProgressBar::hidden(),
        )
        .await?;
        sender.await??;
        drop(file);

        Ok(tokio::fs::read(destination).await?)
    }

    #[test]
    fn file_name_should_reject_parent_path() {
        assert!(validate_file_name("../secret.txt").is_err());
    }

    #[test]
    fn manifest_path_should_accept_nested_file() {
        assert!(validate_manifest_path("photos/2026/image.png").is_ok());
    }

    #[test]
    fn manifest_path_should_reject_backslash_separator() {
        assert!(validate_manifest_path("photos\\image.png").is_err());
    }

    #[tokio::test]
    async fn collect_files_should_include_directory_hierarchy(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let source = directory.path().join("photos");
        tokio::fs::create_dir_all(source.join("2026")).await?;
        tokio::fs::write(source.join("2026").join("image.png"), b"image").await?;

        let files = collect_files(&[source]).await?;

        assert_eq!(files[0].relative_path, "photos/2026/image.png");
        Ok(())
    }

    #[test]
    fn file_name_should_reject_windows_alternate_stream() {
        assert!(validate_file_name("notes.txt:hidden").is_err());
    }

    #[test]
    fn collision_name_should_keep_extension() {
        assert_eq!(collision_name("archive.tar", 2), "archive (2).tar");
    }

    #[test]
    fn validate_file_name_should_reject_reserved_windows_names() {
        assert!(validate_file_name("con.txt").is_err());
    }

    #[test]
    fn validate_request_should_accept_size_at_limit() {
        let request = crate::protocol::TransferRequest {
            version: crate::protocol::VERSION,
            files: vec![crate::protocol::ManifestEntry {
                path: "notes.txt".to_owned(),
                size: 42,
            }],
        };

        assert!(validate_request(&request, 42).is_ok());
    }

    #[test]
    fn validate_request_should_reject_size_over_limit() {
        let request = crate::protocol::TransferRequest {
            version: crate::protocol::VERSION,
            files: vec![crate::protocol::ManifestEntry {
                path: "notes.txt".to_owned(),
                size: 43,
            }],
        };

        assert!(validate_request(&request, 42).is_err());
    }

    #[tokio::test]
    async fn destination_should_not_overwrite_existing_file(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        tokio::fs::write(directory.path().join("notes.txt"), b"existing").await?;

        let (_file, destination) = create_destination(directory.path(), "notes.txt").await?;

        assert_eq!(destination, directory.path().join("notes (1).txt"));
        Ok(())
    }

    #[tokio::test]
    async fn create_destination_should_reserve_unique_names_concurrently(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let mut tasks = JoinSet::new();
        for _ in 0..8 {
            let output = directory.path().to_path_buf();
            tasks.spawn(async move {
                let (file, path) = create_destination(&output, "shared.txt").await?;
                drop(file);
                Ok::<PathBuf, std::io::Error>(path)
            });
        }

        let mut paths = HashSet::new();
        while let Some(path) = tasks.join_next().await {
            paths.insert(path??);
        }

        assert_eq!(paths.len(), 8);
        Ok(())
    }

    #[tokio::test]
    async fn receive_body_should_preserve_empty_file() -> Result<(), Box<dyn std::error::Error>> {
        assert_eq!(receive_payload(&[]).await?, Vec::<u8>::new());
        Ok(())
    }

    #[tokio::test]
    async fn receive_body_should_preserve_chunk_boundary_file(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let payload = vec![9_u8; CHUNK_SIZE];

        assert_eq!(receive_payload(&payload).await?, payload);
        Ok(())
    }

    #[tokio::test]
    async fn receive_body_should_preserve_multi_chunk_file(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let payload: Vec<u8> = (0..(CHUNK_SIZE * 2 + 1))
            .map(|index| (index % 251) as u8)
            .collect();

        assert_eq!(receive_payload(&payload).await?, payload);
        Ok(())
    }

    #[tokio::test]
    async fn receive_body_should_reject_invalid_digest() -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let destination = directory.path().join("received.bin");
        let (mut writer, mut reader) = tokio::io::duplex(1024);
        writer.write_all(b"data").await?;
        writer.write_all(&[0_u8; 32]).await?;
        writer.shutdown().await?;
        let mut file = tokio::fs::File::create(destination).await?;

        let error = receive_body(&mut reader, &mut file, 4, &indicatif::ProgressBar::hidden())
            .await
            .unwrap_err();

        assert!(error.to_string().contains("digest mismatch"));
        Ok(())
    }

    #[tokio::test]
    async fn stream_file_should_reject_source_smaller_than_declared_size(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let source = directory.path().join("source.bin");
        tokio::fs::write(&source, b"x").await?;
        let (mut writer, _reader) = tokio::io::duplex(1024);

        let error = stream_file(&source, 2, &mut writer, &indicatif::ProgressBar::hidden())
            .await
            .unwrap_err();

        assert!(error.to_string().contains("reached end"));
        Ok(())
    }

    #[tokio::test]
    async fn stream_file_should_reject_source_larger_than_declared_size(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let source = directory.path().join("source.bin");
        tokio::fs::write(&source, b"xy").await?;
        let (mut writer, _reader) = tokio::io::duplex(1024);

        let error = stream_file(&source, 1, &mut writer, &indicatif::ProgressBar::hidden())
            .await
            .unwrap_err();

        assert!(error.to_string().contains("grew beyond"));
        Ok(())
    }

    #[tokio::test]
    async fn quic_transfer_should_pin_identity_and_preserve_multi_chunk_file(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let source_directory = tempfile::tempdir()?;
        let output_directory = tempfile::tempdir()?;
        let source = source_directory.path().join("payload.bin");
        let payload: Vec<u8> = (0..(CHUNK_SIZE * 2 + 1))
            .map(|index| (index % 251) as u8)
            .collect();
        tokio::fs::write(&source, &payload).await?;

        let identity = Identity::generate()?;
        let fingerprint = identity.fingerprint;
        let endpoint = quinn::Endpoint::server(
            identity.server_config,
            SocketAddrV4::new(Ipv4Addr::LOCALHOST, 0).into(),
        )?;
        let peer = Peer {
            id: "loopback".to_owned(),
            name: "loopback".to_owned(),
            address: endpoint.local_addr()?,
            fingerprint,
        };
        let output = output_directory.path().to_path_buf();
        let server = tokio::spawn(async move {
            let incoming = endpoint
                .accept()
                .await
                .ok_or_else(|| anyhow::anyhow!("receiver endpoint closed"))?;
            handle_connection(
                incoming,
                &output,
                u64::MAX,
                true,
                &Arc::new(indicatif::MultiProgress::new()),
                &Arc::new(tokio::sync::Mutex::new(())),
            )
            .await
        });

        timeout(Duration::from_secs(10), send_files(&[source], &peer)).await??;
        timeout(Duration::from_secs(10), server).await???;

        assert_eq!(
            tokio::fs::read(output_directory.path().join("payload.bin")).await?,
            payload
        );
        Ok(())
    }
}
