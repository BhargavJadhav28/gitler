use std::{net::Ipv4Addr, path::PathBuf};

use clap::{ArgAction, Parser, Subcommand};

const DEFAULT_MAX_SIZE: u64 = 10 * 1024 * 1024 * 1024;

#[derive(Debug, Parser)]
#[command(
    name = "gitler",
    version,
    about = "Fast local file drops over mDNS and QUIC"
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

        /// Accept valid transfers without an interactive confirmation.
        #[arg(long)]
        accept_all: bool,

        /// Local IPv4 address used by the QUIC listener.
        #[arg(long, default_value = "0.0.0.0")]
        bind: Ipv4Addr,

        /// QUIC UDP port. Zero asks the OS for an available port.
        #[arg(long, default_value_t = 0)]
        port: u16,
    },

    /// Send one file to a discovered receiver.
    Send {
        /// File to send.
        path: PathBuf,

        /// Receiver name or peer ID. Prompts when omitted and several peers exist.
        #[arg(short, long)]
        to: Option<String>,

        /// Number of seconds to scan for receivers.
        #[arg(long, default_value_t = 3)]
        timeout: u64,
    },
}
