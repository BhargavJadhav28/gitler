use std::time::Duration;

use crate::discovery::Peer;

pub(crate) fn format_bytes(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KiB", "MiB", "GiB", "TiB"];

    if bytes < 1024 {
        return format!("{bytes} B");
    }

    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit < UNITS.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }
    format!("{value:.1} {}", UNITS[unit])
}

pub(crate) fn print_discovery_start(duration: Duration) {
    println!(
        "Searching local network for receivers ({}s)...",
        duration.as_secs()
    );
}

pub(crate) fn print_peers(peers: &[Peer]) {
    if peers.is_empty() {
        println!("No receivers found.");
        println!("\nCheck that a receiver is running with `gitler receive` on this network.");
        return;
    }

    println!(
        "Found {} receiver{}:\n",
        peers.len(),
        plural_suffix(peers.len())
    );
    println!("  {:<24} {:<14} ADDRESS", "NAME", "ID");
    for peer in peers {
        println!("  {:<24} {:<14} {}", peer.name, peer.id, peer.address);
    }
}

pub(crate) fn print_receiver_ready(
    name: &str,
    output: &std::path::Path,
    port: u16,
    once: bool,
    max_size: u64,
    accept_all: bool,
) {
    println!("gitler receiver ready");
    println!("  Device:   {name}");
    println!("  Save to:  {}", output.display());
    println!("  UDP port: {port}");
    println!("  Limit:    {} per file", format_bytes(max_size));
    println!(
        "  Approval: {}",
        if accept_all {
            "automatic — trusted networks only"
        } else {
            "required for every transfer"
        }
    );
    println!();
    if once {
        println!("Waiting for one transfer. Press Ctrl+C to cancel.");
    } else {
        println!("Waiting for transfers. Press Ctrl+C to stop.");
    }
}

pub(crate) fn plural_suffix(count: usize) -> &'static str {
    if count == 1 {
        ""
    } else {
        "s"
    }
}

#[cfg(test)]
mod tests {
    use super::format_bytes;

    #[test]
    fn format_bytes_should_use_binary_units() {
        assert_eq!(format_bytes(1_536), "1.5 KiB");
    }

    #[test]
    fn format_bytes_should_keep_small_values_in_bytes() {
        assert_eq!(format_bytes(42), "42 B");
    }
}
