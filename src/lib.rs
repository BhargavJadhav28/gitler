#![forbid(unsafe_code)]
//! Application entry point for zero-configuration local file drops.

mod cli;
mod discovery;
mod protocol;
mod security;
mod transfer;

use std::{
    io::{self, IsTerminal, Write},
    time::Duration,
};

use anyhow::{bail, Context, Result};
use clap::Parser;
use cli::{Cli, Command};
use discovery::{discover_peers, local_device_name, Peer};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

/// Parses process arguments and runs the selected command.
///
/// # Errors
///
/// Returns an error when discovery, networking, file I/O, or transfer validation fails.
pub async fn run() -> Result<()> {
    let cli = Cli::parse();
    init_tracing(cli.verbose)?;

    match cli.command {
        Command::Peers { timeout } => {
            let peers = discover_peers(Duration::from_secs(timeout)).await?;
            print_peers(&peers);
        }
        Command::Receive {
            output,
            name,
            once,
            max_size,
            accept_all,
            bind,
            port,
        } => {
            transfer::receive_files(
                output,
                name.unwrap_or_else(local_device_name),
                once,
                max_size,
                accept_all,
                bind,
                port,
            )
            .await?;
        }
        Command::Send { path, to, timeout } => {
            let peers = discover_peers(Duration::from_secs(timeout)).await?;
            let peer = select_peer(peers, to.as_deref())?;
            println!(
                "Sending {} to {} ({})",
                path.display(),
                peer.name,
                peer.id
            );
            transfer::send_file(&path, &peer).await?;
        }
    }

    Ok(())
}

fn init_tracing(verbosity: u8) -> Result<()> {
    let default_filter = match verbosity {
        0 => "gitler=warn",
        1 => "gitler=info",
        _ => "gitler=debug",
    };
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new(default_filter));
    tracing_subscriber::registry()
        .with(filter)
        .with(tracing_subscriber::fmt::layer().with_target(false))
        .try_init()
        .context("failed to initialize logging")?;
    Ok(())
}

fn select_peer(peers: Vec<Peer>, query: Option<&str>) -> Result<Peer> {
    if peers.is_empty() {
        bail!("no receivers found; run `gitler receive` on another device");
    }

    if let Some(query) = query {
        let query = query.to_lowercase();
        let mut matches = peers.into_iter().filter(|peer| {
            peer.name.to_lowercase().contains(&query)
                || peer.id.to_lowercase().starts_with(&query)
        });
        let first = matches
            .next()
            .with_context(|| format!("no receiver matches `{query}`"))?;
        if matches.next().is_some() {
            bail!("receiver selector `{query}` is ambiguous");
        }
        return Ok(first);
    }

    if peers.len() == 1 {
        return peers
            .into_iter()
            .next()
            .context("receiver list unexpectedly became empty");
    }

    if !io::stdin().is_terminal() {
        print_peers(&peers);
        bail!("several receivers found; select one with `--to NAME_OR_ID`");
    }

    println!("Receivers:");
    for (index, peer) in peers.iter().enumerate() {
        println!(
            "  {}) {} [{}] at {}",
            index + 1,
            peer.name,
            peer.id,
            peer.address
        );
    }
    print!("Select receiver: ");
    io::stdout().flush()?;

    let mut input = String::new();
    io::stdin().read_line(&mut input)?;
    let selected: usize = input.trim().parse().context("selection must be a number")?;
    if selected == 0 || selected > peers.len() {
        bail!("selection is outside available receiver range");
    }

    peers
        .into_iter()
        .nth(selected - 1)
        .context("selected receiver disappeared")
}

fn print_peers(peers: &[Peer]) {
    if peers.is_empty() {
        println!("No receivers found");
        return;
    }

    for peer in peers {
        println!("{}\t{}\t{}", peer.id, peer.name, peer.address);
    }
}
