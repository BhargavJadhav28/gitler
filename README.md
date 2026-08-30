# gitler

Fast, zero-configuration file sharing on one local network. `gitler` discovers
receivers with mDNS and transfers files over encrypted QUIC.

## Install

Native release binaries need no Rust, Cargo, compiler, administrator access, or
paid code-signing certificate.

### Supported platforms

Use only assets matching your platform. Windows ARM64 and Linux ARM64 are not
currently supported.

| Platform | Target | Minimum compatibility | Asset |
| --- | --- | --- | --- |
| Windows x86_64 | MSVC | Windows 10/11 x64; no external Visual C++ runtime | `gitler-vX.Y.Z-windows-x86_64.exe` |
| macOS Intel | x86_64 | macOS 11.0+ | `gitler-vX.Y.Z-macos-x86_64` |
| macOS Apple Silicon | arm64 | macOS 11.0+ | `gitler-vX.Y.Z-macos-aarch64` |
| Linux x86_64 | glibc | glibc 2.35+ | `gitler-vX.Y.Z-linux-x86_64-gnu` |

### Recommended: download, inspect, install

Download the installer before running it so you can inspect its contents.
Examples use `v0.1.2`; replace it with the exact release you want.

Unix:

```sh
mkdir -p "$HOME/Downloads/gitler-installer"
curl --proto '=https' --proto-redir '=https' -fsSL \
  https://github.com/BhargavJadhav28/gitler/releases/latest/download/install.sh \
  -o "$HOME/Downloads/gitler-installer/install.sh"
sed -n '1,260p' "$HOME/Downloads/gitler-installer/install.sh"
sh "$HOME/Downloads/gitler-installer/install.sh"
```

For an exact version, download the script from its tag and pass the same tag to
it. This avoids the GitHub latest-release API lookup:

```sh
version=v0.1.2
mkdir -p "$HOME/Downloads/gitler-installer"
curl --proto '=https' --proto-redir '=https' -fsSL \
  "https://github.com/BhargavJadhav28/gitler/releases/download/$version/install.sh" \
  -o "$HOME/Downloads/gitler-installer/install.sh"
sh "$HOME/Downloads/gitler-installer/install.sh" --version "$version"
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

Exact-version PowerShell install:

```powershell
$version = 'v0.1.2'
$installer = Join-Path $env:TEMP 'gitler-install.ps1'
Invoke-WebRequest `
  -Uri "https://github.com/BhargavJadhav28/gitler/releases/download/$version/install.ps1" `
  -OutFile $installer
Get-Content -LiteralPath $installer
& $installer -Version $version
```

Default installs resolve `latest` once, validate the expected stable Release
assets, then download the checksum and selected binary from that exact tag.
Exact-version installs query only the requested tagged Release and reject a
missing, draft, prerelease, malformed, or incomplete Release before downloading
the binary. If latest lookup fails or is rate-limited, use explicit
`--version vX.Y.Z` or `-Version vX.Y.Z`.

These convenience forms execute code received directly from the network. Use
the download-first form above when you want to inspect the script first:

```sh
curl -fsSL https://github.com/BhargavJadhav28/gitler/releases/latest/download/install.sh | sh
```

```powershell
irm https://github.com/BhargavJadhav28/gitler/releases/latest/download/install.ps1 | iex
```

### Installer options and behavior

Unix options:

```text
--version vX.Y.Z       Install an exact stable release
--install-dir DIR     Use a dedicated install directory
--force               Replace a changed same-version managed binary
--allow-downgrade     Permit an older managed version
--modify-path         Add the directory to a supported shell profile
--remove-path         Remove the installer-owned PATH entry/block
--uninstall           Remove the managed installation
--dry-run             Show the action without network, writes, or execution
```

PowerShell uses `-Version`, `-InstallDir`, `-Force`, `-AllowDowngrade`,
`-AddToPath`, `-RemovePath`, `-Uninstall`, and `-WhatIf`.

- Unix default directory: `${XDG_DATA_HOME:-$HOME/.local/share}/gitler/bin`.
- Windows default directory: `%LOCALAPPDATA%\Programs\gitler`.
- PATH is unchanged by default. Unix prints commands for the current terminal
  and detected shell; PowerShell changes User PATH only with `-AddToPath` or
  `-RemovePath`.
- Updates verify SHA-256, `--version`, and `--help` before replacing a managed
  binary. Same-version changes need `--force`; downgrades need
  `--allow-downgrade`/`-AllowDowngrade`.
- Existing unrecognized directories are refused. Uninstall removes only managed
  files, empty dedicated directories, and an unchanged installer-owned PATH
  entry when explicitly requested.
- Downloads use HTTPS and standard proxy settings. Network, TLS, permission,
  locked-file, and disk-space failures stop without silently replacing the old
  managed binary.

### Direct binary download

Release assets are direct executables, not archives. Download the binary and
`SHA256SUMS` from the same tag, then compare one selected asset with its exact
manifest entry.

Linux example:

```sh
version=v0.1.2
asset="gitler-${version}-linux-x86_64-gnu"
base="https://github.com/BhargavJadhav28/gitler/releases/download/$version"
curl --proto '=https' --proto-redir '=https' -fL "$base/$asset" -o "$asset"
curl --proto '=https' --proto-redir '=https' -fL "$base/SHA256SUMS" -o SHA256SUMS
expected=$(awk -v file="$asset" '$2 == file { count++; hash=$1 } END { if (count != 1) exit 1; print hash }' SHA256SUMS)
actual=$(sha256sum "$asset" | awk '{ print $1 }')
test "$expected" = "$actual"
chmod 755 "$asset"
"$PWD/$asset" --version
"$PWD/$asset" --help
```

On macOS, use `shasum -a 256 "$asset" | awk '{ print $1 }'` instead of
`sha256sum`. On Windows, use `Get-FileHash -Algorithm SHA256` and compare it
to the exact two-space manifest entry before running the `.exe`.

Stable assets also receive GitHub artifact attestations. After authenticating
GitHub CLI, verify the exact downloaded file against this repository:

```sh
gh attestation verify ./gitler-v0.1.2-linux-x86_64-gnu \
  -R BhargavJadhav28/gitler
```

A checksum detects corruption or a wrong file; it does not independently
authenticate a mutable release or compromised publisher account. Attestation
adds build/publisher provenance. Neither is an Apple notarization or Windows
Authenticode signature.

Unsigned Windows builds may show SmartScreen/“Unknown publisher” warnings, and
macOS builds may need Gatekeeper approval. Do not disable operating-system
security controls.

## Usage

On the receiving device:

```sh
gitler receive --output ./Downloads
```

Approval is interactive by default. For a trusted, unattended LAN only:

```sh
gitler receive --output ./Downloads --accept-all
```

Discover receivers:

```sh
gitler peers
gitler peers --timeout 5
```

Send files or directories:

```sh
gitler send ./report.pdf ./photos
gitler send ./report.pdf --to workstation
```

Receive one connection, with a 2 GiB per-file limit:

```sh
gitler receive --once --output ./Downloads --max-size 2147483648
```

Run `gitler --help` for all options. Transfers use IPv4 in this release. Allow
inbound UDP `5353` for mDNS and the receiver's selected QUIC UDP port in the
platform firewall.

## Security model

QUIC encrypts transfers with TLS 1.3. The sender pins the receiver certificate
fingerprint advertised through mDNS, and the receiver checks every file's
SHA-256 digest before accepting it. Receiver approval is required unless
`--accept-all` is used.

mDNS is unauthenticated. An active attacker on the same LAN can spoof discovery
on first contact, so this is opportunistic local sharing, not verified identity.
Do not use it on hostile networks for sensitive files. Report vulnerabilities
through [`SECURITY.md`](SECURITY.md), not public issues.

## Development

### Prerequisites

- [Rust](https://rustup.rs/) 1.88 or newer (MSRV in `Cargo.toml`)
- `rustup`; `rust-toolchain.toml` pins the release compiler to Rust 1.97.1
- `rustfmt` and `clippy` components

The committed `Cargo.lock` controls dependency resolution. Keep it unchanged
for locked checks and release builds.

```sh
git clone https://github.com/BhargavJadhav28/gitler.git
cd gitler
cargo build --all-features --locked
```

### Build, test, and lint

```sh
cargo fmt --check
cargo clippy --all-targets --all-features --locked -- -D warnings
cargo test --all-features --locked
cargo build --release --all-features --locked
```

`check.sh` runs formatting, Clippy, tests, locked debug and release builds,
and a direct release-binary `--help` smoke test on Unix, Git Bash, or WSL:

```sh
bash check.sh
```

Install a local source build with:

```sh
cargo install --path . --locked
```

### Release process

Maintainers create an annotated `vMAJOR.MINOR.PATCH` tag on the protected
default branch, then dispatch `.github/workflows/release.yml` with that tag.
The workflow validates the tag and tagged package version, builds all supported
targets, checks architectures and runtime dependencies, assembles exact assets,
generates checksums and attestations, uploads a draft, downloads it again for
verification, and publishes only after `production` environment approval.

Published asset bytes are not replaced in place. Fix bad releases with a higher
version and advisory. First stable releases and packaging/build-environment
changes still need clean-machine checks on every supported platform.

## Design

See [`docs/architecture.md`](docs/architecture.md).
