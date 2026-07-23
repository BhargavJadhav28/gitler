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
        read_message, write_message, TransferRequest, TransferResponse, DIGEST_LENGTH, VERSION,
    },
    security::{pinned_client_config, Identity},
};

const CHUNK_SIZE: usize = 128 * 1024;
const CONTROL_TIMEOUT: Duration = Duration::from_secs(15);
const CHUNK_TIMEOUT: Duration = Duration::from_secs(60);
const MAX_ACTIVE_TRANSFERS: usize = 8;

pub(crate) async fn send_file(path: &Path, peer: &Peer) -> Result<()> {
    let metadata = fs::metadata(path)
        .await
        .with_context(|| format!("failed to inspect {}", path.display()))?;
    if !metadata.is_file() {
        bail!("{} is not a regular file", path.display());
    }

    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty())
        .ok_or_else(|| anyhow!("file name must be valid UTF-8"))?
        .to_owned();
    let request = TransferRequest {
        version: VERSION,
        file_name: file_name.clone(),
        size: metadata.len(),
    };

    let mut endpoint = Endpoint::client(SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 0).into())?;
    endpoint.set_default_client_config(pinned_client_config(peer.fingerprint)?);
    let connection = endpoint
        .connect(peer.address, "gitler.local")?
        .await
        .with_context(|| format!("failed to connect to {} at {}", peer.name, peer.address))?;
    let (mut send, mut receive) = connection.open_bi().await?;

    write_message(&mut send, &request).await?;
    let response: TransferResponse = read_message(&mut receive).await?;
    if !response.accepted {
        bail!("receiver rejected transfer: {}", response.message);
    }

    let progress = transfer_progress(metadata.len(), format!("sending {file_name}"))?;
    let result = stream_file(path, metadata.len(), &mut send, &progress).await;
    if result.is_err() {
        progress.finish_and_clear();
    }
    result?;
    send.finish()?;

    let response: TransferResponse = read_message(&mut receive).await?;
    if !response.accepted {
        progress.finish_and_clear();
        bail!("receiver rejected file: {}", response.message);
    }

    progress.finish_with_message(format!("sent {file_name}"));
    connection.close(0_u32.into(), b"transfer complete");
    endpoint.wait_idle().await;
    Ok(())
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

    println!(
        "Receiving as {name} into {} on UDP port {}",
        output.display(),
        local_address.port()
    );

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
    let (mut send, mut receive) = timeout(CONTROL_TIMEOUT, connection.accept_bi())
        .await
        .context("sender did not open a transfer stream in time")??;
    let request: TransferRequest = timeout(CONTROL_TIMEOUT, read_message(&mut receive))
        .await
        .context("sender did not provide transfer metadata in time")??;

    if let Err(error) = validate_request(&request, max_size) {
        write_message(&mut send, &TransferResponse::rejected(error.to_string())).await?;
        send.finish()?;
        return Err(error);
    }

    if !accept_all && !request_approval(remote, request.clone(), approval_lock).await? {
        let error = anyhow!("transfer was not approved");
        write_message(&mut send, &TransferResponse::rejected(error.to_string())).await?;
        send.finish()?;
        return Err(error);
    }

    let (mut file, destination) = match create_destination(output, &request.file_name).await {
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

    write_message(
        &mut send,
        &TransferResponse::accepted(destination.display().to_string()),
    )
    .await?;
    let bar = progress.add(transfer_progress(
        request.size,
        format!("receiving {}", request.file_name),
    )?);

    let receive_result = receive_body(&mut receive, &mut file, request.size, &bar).await;
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
    println!("Received {}", destination.display());
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
    request: TransferRequest,
    approval_lock: &Arc<Mutex<()>>,
) -> Result<bool> {
    let _guard = approval_lock.lock().await;
    tokio::task::spawn_blocking(move || -> io::Result<bool> {
        if !io::stdin().is_terminal() {
            return Ok(false);
        }

        print!(
            "Accept {} bytes as `{}` from {}? [y/N] ",
            request.size, request.file_name, remote
        );
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
    validate_file_name(&request.file_name)?;
    if request.size > max_size {
        bail!("file exceeds receiver size limit");
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
        collision_name, create_destination, handle_connection, receive_body, send_file,
        stream_file, validate_file_name, validate_request, CHUNK_SIZE,
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
            file_name: "notes.txt".to_owned(),
            size: 42,
        };

        assert!(validate_request(&request, 42).is_ok());
    }

    #[test]
    fn validate_request_should_reject_size_over_limit() {
        let request = crate::protocol::TransferRequest {
            version: crate::protocol::VERSION,
            file_name: "notes.txt".to_owned(),
            size: 43,
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

        timeout(Duration::from_secs(10), send_file(&source, &peer)).await??;
        timeout(Duration::from_secs(10), server).await???;

        assert_eq!(
            tokio::fs::read(output_directory.path().join("payload.bin")).await?,
            payload
        );
        Ok(())
    }
}
