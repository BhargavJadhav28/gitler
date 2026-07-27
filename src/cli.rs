use std::{net::Ipv4Addr, path::PathBuf};

use clap::{
    builder::styling::{AnsiColor, Effects, Styles},
    ArgAction, Parser, Subcommand,
};

const DEFAULT_MAX_SIZE: u64 = 10 * 1024 * 1024 * 1024;

#[derive(Debug, Parser)]
#[command(
    name = "gitler",
    version,
    about = "Fast, private file drops on your local network",
    after_help = "Examples:\n  gitler receive --output ./Downloads\n  gitler send ./report.pdf --to workstation\n  gitler peers\n\nTransfers use encrypted QUIC. Review receiver identity before sending sensitive files.",
    styles = Styles::styled()
        .header(AnsiColor::Cyan.on_default() | Effects::BOLD)
        .usage(AnsiColor::Cyan.on_default() | Effects::BOLD)
        .literal(AnsiColor::Green.on_default())
        .placeholder(AnsiColor::Yellow.on_default())
)]
pub(crate) struct Cli {
    /// Increase diagnostic logging. Repeat for debug output.
    #[arg(short, long, action = ArgAction::Count, global = true)]
    pub(crate) verbose: u8,

    #[command(subcommand)]
    pub(crate) command: Command,
}

#[derive(Debug, Subcommand)]
pub(crate) enum Command {
    /// Discover receivers on the local network.
    Peers {
        /// Number of seconds to scan.
        #[arg(short, long, default_value_t = 3)]
        timeout: u64,
    },

    /// Advertise this device and receive file drops.
    Receive {
        /// Directory where received files are created.
        #[arg(short, long, default_value = ".")]
        output: PathBuf,

        /// Friendly device name advertised to senders.
        #[arg(short, long)]
        name: Option<String>,

        /// Stop after one connection is handled.
        #[arg(long)]
        once: bool,

        /// Reject files larger than this many bytes.
        #[arg(long, default_value_t = DEFAULT_MAX_SIZE)]
        max_size: u64,

        /// Accept valid transfers without confirmation. Use only on a trusted network.
        #[arg(long)]
        accept_all: bool,

        /// Local IPv4 address used by the QUIC listener.
        #[arg(long, default_value = "0.0.0.0")]
        bind: Ipv4Addr,

        /// QUIC UDP port. Zero asks the OS for an available port.
        #[arg(long, default_value_t = 0)]
        port: u16,
    },

    /// Send files and directories to a discovered receiver.
    Send {
        /// Files or directories to send.
        #[arg(required = true, num_args = 1..)]
        paths: Vec<PathBuf>,

        /// Receiver name or peer ID. Prompts when omitted and several peers exist.
        #[arg(short, long)]
        to: Option<String>,

        /// Number of seconds to scan for receivers.
        #[arg(long, default_value_t = 3)]
        timeout: u64,
    },
}
