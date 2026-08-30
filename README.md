# gitler

Fast, private file drops between devices on the same local network.
`gitler` discovers receivers with mDNS and transfers files over encrypted QUIC.

## Install

The native release installers require no Rust, Cargo, compiler, administrator
access, or external runtime.

### Quick install

Unix:

```sh
curl -fsSL https://github.com/BhargavJadhav28/gitler/releases/latest/download/install.sh | sh
```

Windows PowerShell:

```powershell
irm https://github.com/BhargavJadhav28/gitler/releases/latest/download/install.ps1 | iex
```

Normal installs automatically configure PATH when possible:

- Unix adds a managed block to `.bashrc`, `.zshrc`, or the Fish config.
- Windows adds the per-user install directory to User PATH.
- If PATH cannot be changed, the installer prints copy-paste commands.
- Open a new terminal, or run the printed command, if `gitler` is not found.

The default install locations are:

- Unix: `${XDG_DATA_HOME:-$HOME/.local/share}/gitler/bin`
- Windows: `%LOCALAPPDATA%\Programs\gitler`

These commands execute code downloaded from the network. Use the inspect-first
method below when you want to review the installer before running it.

### Inspect first

Unix:

```sh
mkdir -p "$HOME/Downloads/gitler"
curl --proto '=https' --proto-redir '=https' -fsSL \
  https://github.com/BhargavJadhav28/gitler/releases/latest/download/install.sh \
  -o "$HOME/Downloads/gitler/install.sh"
cat "$HOME/Downloads/gitler/install.sh"
sh "$HOME/Downloads/gitler/install.sh"
```

Windows PowerShell:

```powershell
$installer = Join-Path $env:TEMP 'gitler-install.ps1'
Invoke-WebRequest `
  -Uri 'https://github.com/BhargavJadhav28/gitler/releases/latest/download/install.ps1' `
  -OutFile $installer
Get-Content -LiteralPath $installer
& $installer
```

### Install an exact version

Replace `vX.Y.Z` with a published stable tag. Exact installs avoid the GitHub
`latest` API lookup.

Unix:

```sh
version=vX.Y.Z
curl --proto '=https' --proto-redir '=https' -fsSL \
  "https://github.com/BhargavJadhav28/gitler/releases/download/$version/install.sh" \
  -o install.sh
sh install.sh --version "$version"
```

Windows PowerShell:

```powershell
$version = 'vX.Y.Z'
$installer = Join-Path $env:TEMP 'gitler-install.ps1'
Invoke-WebRequest `
  -Uri "https://github.com/BhargavJadhav28/gitler/releases/download/$version/install.ps1" `
  -OutFile $installer
& $installer -Version $version
```

### PATH options

Automatic PATH setup can be disabled when needed:

```sh
sh install.sh --no-modify-path
```

```powershell
& $installer -NoAddToPath
```

To explicitly require PATH setup, use `--modify-path` on Unix or
`-AddToPath` in PowerShell. The install directory is still printed so the
binary can be run directly if PATH setup is skipped.

## Use gitler

Run a receiver on one device:

```sh
gitler receive --output ./Downloads
```

Discover receivers from another device:

```sh
gitler peers
gitler peers --timeout 5
```

Send files or directories:

```sh
gitler send ./report.pdf
gitler send ./photos --to workstation
gitler send ./report.pdf ./photos --to workstation
```

A receiver asks for approval before accepting a transfer. To receive one
connection and then exit:

```sh
gitler receive --once --output ./Downloads
```

For unattended receiving, `--accept-all` skips approval. Use it only on a
trusted local network:

```sh
gitler receive --accept-all --output ./Downloads
```

Run `gitler --help`, `gitler receive --help`, or `gitler send --help` for all
options. Use `-v` or `-vv` for diagnostic logging.

## Troubleshooting

- **`gitler` is not recognized:** open a new terminal. If the installer printed
  a PATH command, run that command in the current terminal.
- **No receivers found:** ensure both devices are on the same local network,
  the receiver is running, and the firewall allows mDNS UDP `5353` and the
  receiver's displayed QUIC UDP port.
- **Latest lookup fails or is rate-limited:** install an exact version with
  `--version vX.Y.Z` or `-Version vX.Y.Z`.
- **Unsupported platform:** V1 supports Windows x86_64, macOS 11+ on Intel or
  Apple Silicon, and Linux x86_64 with glibc 2.35+. Windows ARM64 and Linux
  ARM64 are not currently supported.

## Uninstall

Use the installer you downloaded, or download it again, and remove the
installer-owned PATH entry explicitly:

Unix:

```sh
sh install.sh --uninstall --remove-path
```

Windows PowerShell:

```powershell
& $installer -Uninstall -RemovePath
```

Uninstall removes only managed gitler files and an unchanged PATH entry. It
preserves unrelated files in the install directory.

## Security

Transfers use TLS 1.3 through QUIC. Receiver identity is pinned to the
certificate fingerprint advertised through mDNS, and received files are
verified with SHA-256. mDNS itself is unauthenticated, so do not use gitler on
hostile networks for sensitive files. Review receiver prompts and use
`--accept-all` only on a trusted LAN.

Report vulnerabilities through [`SECURITY.md`](SECURITY.md).

## Development

Requirements: Rust 1.88 or newer. The repository toolchain and lockfile are
pinned for reproducible checks.

```sh
cargo fmt --check
cargo clippy --all-targets --all-features --locked -- -D warnings
cargo test --all-features --locked
cargo build --release --all-features --locked
```

See [`docs/architecture.md`](docs/architecture.md) for design details.

## License

Licensed under either of:

- [`MIT`](LICENSE-MIT)
- [`Apache-2.0`](LICENSE-APACHE)
