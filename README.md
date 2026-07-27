# gitler (In-progress)

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
- Multiple files and recursive directory transfers, with one QUIC stream per file

IPv4 carries file transfers in this first slice. mDNS still observes all interfaces. IPv6 transport, resumable transfers, trusted device identities, and GUI are planned extensions.

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

Send files and directories:

```sh
gitler send ./report.pdf ./photos
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

### Prerequisites

- [Rust](https://rustup.rs/) **1.88** or newer (see `rust-toolchain.toml`)
- `rustfmt` and `clippy` components (installed automatically by the toolchain file when using rustup)

```sh
rustup show
rustc --version
cargo --version
```

### Setup

```sh
git clone <repo-url>
cd gitler
cargo generate-lockfile   # only needed if Cargo.lock is missing
```

### Build

```sh
# Debug build
cargo build --locked

# With all features (same as CI-style checks)
cargo build --all-features --locked

# Optimized release build (thin LTO, stripped)
cargo build --release --locked
```

Binaries land at:

| Profile | Unix | Windows |
| ------- | ---- | ------- |
| Debug   | `target/debug/gitler` | `target/debug/gitler.exe` |
| Release | `target/release/gitler` | `target/release/gitler.exe` |

### Run locally

Use `cargo run` during development (rebuilds as needed):

```sh
# Help
cargo run -- --help
cargo run -- receive --help
cargo run -- send --help
cargo run -- peers --help

# Discover receivers (default 3s scan)
cargo run -- peers
cargo run -- peers --timeout 5

# Receive into ./Downloads (interactive approval)
cargo run -- receive --output ./Downloads

# Unattended receive (trusted LAN only)
cargo run -- receive --output ./Downloads --accept-all

# Receive one transfer then exit
cargo run -- receive --once --output ./Downloads

# Send files or directories (interactive peer pick if several exist)
cargo run -- send ./test.txt ./photos

# Send to a named receiver
cargo run -- send ./test.txt ./photos --to workstation

# Extra diagnostics (-v or -vv)
cargo run -- -vv peers
```

After a build, run the binary directly:

```sh
./target/debug/gitler peers          # Unix
.\target\debug\gitler.exe peers      # Windows
```

### Test

```sh
# Full test suite
cargo test --all-features --locked

# Single test by name filter
cargo test --all-features --locked <test_name>

# Show println! / test output
cargo test --all-features --locked -- --nocapture
```

### Format and lint

```sh
# Apply formatting
cargo fmt

# Check formatting only (CI style)
cargo fmt --check

# Clippy with warnings as errors
cargo clippy --all-targets --all-features --locked -- -D warnings
```

### Full validation script

`check.sh` runs format check, Clippy, tests, build, and `--help` in one pass:

```sh
# Unix / Git Bash / WSL
./check.sh

# Or
bash check.sh
```

Equivalent manual sequence:

```sh
cargo fmt --check
cargo clippy --all-targets --all-features --locked -- -D warnings
cargo test --all-features --locked
cargo build --all-features --locked
```

### Install from source

```sh
cargo install --path .
# then: gitler --help
```

### Clean

```sh
cargo clean
```
