<<<<<<< HEAD
# gitler

Fast, zero-configuration local file drops over mDNS and QUIC. Think terminal AirDrop for devices sharing one LAN.

## Why CLI first?

CLI gives fastest path to a reliable protocol, works over SSH and on headless devices, and keeps packaging small. Discovery, security, protocol, and transfer code live outside CLI parsing, so an `egui` or Tauri front end can reuse them later.

## Current MVP

- Automatic receiver discovery through DNS-SD/mDNS
- Encrypted QUIC transport using Quinn and TLS 1.3
- Ephemeral self-signed receiver identities pinned to advertised SHA-256 fingerprints
- Streaming transfers with bounded memory use
- End-to-end SHA-256 integrity verification
- Live send and receive progress
- Collision-safe destination naming; existing files are never overwritten
- Interactive receiver approval by default
- 10 GiB default per-file limit, configurable with `--max-size`

IPv4 carries file transfers in this first slice. mDNS still observes all interfaces. IPv6 transport, multiple-file batches, trusted device identities, and GUI are planned extensions.

## Install

Rust 1.88 or newer is required.

```sh
cargo install --path .
```

Windows Firewall, macOS Firewall, or Linux firewall rules must allow inbound UDP for mDNS (`5353`) and the receiver's selected QUIC port.

## Usage

On receiving device:

```sh
gitler receive --output ./Downloads
```

Each valid request asks for approval. For a trusted, unattended LAN receiver:

```sh
gitler receive --output ./Downloads --accept-all
```

Discover receivers:

```sh
gitler peers
```

Send file:

```sh
gitler send ./report.pdf
```

Choose receiver non-interactively:

```sh
gitler send ./report.pdf --to workstation
```

Receive one connection and exit, with 2 GiB limit:

```sh
gitler receive --once --max-size 2147483648
```

Use `gitler --help` for all options.

## Security model

QUIC encrypts every transfer with TLS 1.3. Sender pins certificate fingerprint from receiver's mDNS advertisement, preventing silent certificate substitution after discovery data is received. Receiver asks for approval unless `--accept-all` is set. File digest is verified before transfer is accepted as complete.

mDNS itself is unauthenticated. Active attacker on same LAN can spoof discovery records during first contact. Current model provides encrypted opportunistic local sharing, not verified human identity. Do not use on hostile networks for sensitive files. Planned hardening: persistent device keys with trust-on-first-use plus optional short authentication string confirmation.

## Design

See [`docs/architecture.md`](docs/architecture.md).

## Development

```sh
cargo generate-lockfile
cargo fmt --check
cargo clippy --all-targets --all-features --locked -- -D warnings
cargo test --all-features --locked
```
=======
# gitler
>>>>>>> origin/main
