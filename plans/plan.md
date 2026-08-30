# Native binary release plan

## Goal

Release `gitler` as prebuilt native binaries. Users install without Rust, Cargo,
a compiler, administrator access, or manual OS/CPU selection.

Unix convenience command:

```sh
curl -fsSL https://github.com/BhargavJadhav28/gitler/releases/latest/download/install.sh | sh
```

Windows PowerShell convenience command:

```powershell
irm https://github.com/BhargavJadhav28/gitler/releases/latest/download/install.ps1 | iex
```

The installer detects platform, downloads matching release binary, verifies it,
and installs only into user-owned location.

## V1 boundaries

Included:

- Public GitHub Releases containing direct executable files.
- GitHub Actions native builds for listed platforms.
- POSIX `sh` Unix installer and PowerShell Windows installer.
- SHA-256 checksums, GitHub artifact attestations, draft-first publishing, and
  documented verification.
- Transactional upgrade, optional PATH setup, narrow uninstall, and clear
  failures.

Deferred:

- Apple notarization and Windows Authenticode signing.
- Windows ARM64 and Linux ARM64 builds.
- MSI, PKG, Homebrew, Scoop, Winget, apt, and other package-manager releases.
- Self-update.

Without paid platform code-signing, Windows can show SmartScreen/Unknown
Publisher warnings and macOS can require Gatekeeper approval. Do not tell users
to disable security controls; code-signing is separate future work.

## Supported platform contract

Publish and support only tested targets.

| Platform | Rust target | Minimum support | Release asset |
| --- | --- | --- | --- |
| Windows x64 | `x86_64-pc-windows-msvc` | Windows 10/11 x64; static MSVC runtime | `gitler-vX.Y.Z-windows-x86_64.exe` |
| macOS Intel | `x86_64-apple-darwin` | macOS 11+ | `gitler-vX.Y.Z-macos-x86_64` |
| macOS Apple Silicon | `aarch64-apple-darwin` | macOS 11+ | `gitler-vX.Y.Z-macos-aarch64` |
| Linux x64 | `x86_64-unknown-linux-gnu` | glibc 2.35+ | `gitler-vX.Y.Z-linux-x86_64-gnu` |

Rules:

- Build Windows and both macOS targets on matching native GitHub-hosted runners.
- Build Linux inside pinned `ubuntu:22.04` container, establishing glibc 2.35
  baseline.
- Set `MACOSX_DEPLOYMENT_TARGET=11.0` for both macOS builds.
- Build Windows with static MSVC runtime only after dependency inspection proves
  no Visual C++ Redistributable is needed.
- Inspect final PE, Mach-O, and ELF architecture/runtime dependencies before
  publishing.
- Reject unsupported OS or CPU. Never silently install emulated binary.

## Release assets

Each stable `vMAJOR.MINOR.PATCH` GitHub Release contains exactly seven files:

```text
gitler-vX.Y.Z-windows-x86_64.exe
gitler-vX.Y.Z-macos-x86_64
gitler-vX.Y.Z-macos-aarch64
gitler-vX.Y.Z-linux-x86_64-gnu
install.sh
install.ps1
SHA256SUMS
```

Rules:

- Build every executable from exact annotated release tag with
  `cargo build --release --locked`.
- Copy installer scripts from same tagged source.
- Use direct executables, not archives. This avoids extraction, traversal,
  symlink, and executable-bit handling risks.
- `SHA256SUMS` lists exactly six files except itself, sorted by filename. Every
  line is `<lowercase-sha256><two spaces><filename>`, LF-delimited with trailing
  newline.
- File names, count, regular-file status, size limits, and SHA-256 hashes are
  validated before upload and after fresh draft download.
- Every exact executable path must pass `--version` and `--help` before
  packaging. `gitler --version` must equal tag version without leading `v`.

## Trust model

- HTTPS protects download transport.
- SHA-256 detects accidental corruption or mismatched files.
- GitHub artifact attestations provide build and repository provenance for users
  who verify them with GitHub CLI.
- A checksum downloaded from same release is not independent authentication of a
  compromised GitHub account or mutable release. Do not claim otherwise.
- `curl | sh` and `irm | iex` execute network-delivered code. They are convenient
  but weaker than downloading and inspecting script first.

Recommended inspect-first install:

```sh
curl --proto '=https' --proto-redir '=https' -fsSL \
  https://github.com/BhargavJadhav28/gitler/releases/latest/download/install.sh \
  -o ./install-gitler.sh
sed -n '1,260p' ./install-gitler.sh
sh ./install-gitler.sh
```

Users needing stronger provenance verify downloaded artifact before executing it:

```sh
gh attestation verify ./gitler-vX.Y.Z-linux-x86_64-gnu \
  -R BhargavJadhav28/gitler
```

## Installer contract

### Common behavior

`install.sh` and `install.ps1` are release code. Keep them in repository, review
them with application changes, ship tagged copies, and test them independently.

Both installers:

1. Resolve target release exactly once. Default install queries GitHub latest
   stable-release API. Exact-version install uses only requested tag.
2. Require a non-draft, non-prerelease tag matching `vMAJOR.MINOR.PATCH` and
   require expected assets to exist.
3. Download binary and `SHA256SUMS` only through version-specific release URLs.
   Never mix `latest/download` asset requests after selection.
4. Strictly validate manifest and matching single SHA-256 entry before execution.
5. Run staged binary by absolute path; require correct `--version` and working
   `--help` before replacing installed version.
6. Preserve old managed binary if download, validation, staging, PATH update, or
   replacement fails.
7. Refuse unsafe paths, symlinks, non-regular executables, unmanaged existing
   directories, unsupported OS/CPU, malformed state, and version downgrade
   unless explicitly authorized.
8. Use no administrator permissions and never modify shared system directories.

### Unix: `install.sh`

Requirements:

- Strict POSIX `sh`; support stock macOS `/bin/sh` and common Linux `/bin/sh`.
- Require `curl`, `mktemp`, `chmod`, `mv`, and `shasum` or `sha256sum`; fail with
  useful remediation when missing.
- Detect Linux x64 and macOS Intel/Apple Silicon, including Rosetta detection.
- Default install directory:

  ```text
  ${XDG_DATA_HOME:-$HOME/.local/share}/gitler/bin
  ```

- Install only `gitler` plus small installer-owned state file in this dedicated
  directory.
- Atomic replacement: verify temporary download, stage on destination
  filesystem, then rename over managed executable.
- Default does not change PATH. Print current-shell and persistent-shell command.
- `--modify-path` explicitly adds one marked, idempotent block only for Bash,
  Zsh, or Fish. `--remove-path` removes only unchanged owned block.

Supported options:

```text
--version vX.Y.Z
--install-dir DIRECTORY
--force
--allow-downgrade
--modify-path
--remove-path
--uninstall
--dry-run
```

### Windows: `install.ps1`

Requirements:

- Support Windows PowerShell 5.1+ and PowerShell 7+ on Windows only.
- Determine actual OS architecture rather than PowerShell-process architecture.
  Support x64 only; reject ARM64.
- Default directory:

  ```text
  %LOCALAPPDATA%\Programs\gitler
  ```

- Use HTTPS, literal paths, terminating errors, strict manifest parsing,
  `Get-FileHash`, temporary staging, and transactional replacement with backup.
- Stop safely if existing executable is locked.
- `-AddToPath` explicitly updates only User `Path`, records ownership, updates
  process `PATH` after successful install, and broadcasts environment change when
  possible.
- `-RemovePath` removes only installer-owned dedicated directory.
- Implement `SupportsShouldProcess`; `-WhatIf` must not download, execute, or
  modify files, PATH, or state.

Supported parameters:

```text
-Version vX.Y.Z
-InstallDir DIRECTORY
-Force
-AllowDowngrade
-AddToPath
-RemovePath
-Uninstall
-WhatIf
```

### Update and uninstall rules

- Newer managed version: verify, then upgrade transactionally.
- Same managed version with same hash: no-op.
- Changed same-version binary: require `--force` or `-Force` after user review.
- Older version: reject unless `--allow-downgrade` or `-AllowDowngrade`.
- Uninstall removes only installer-owned executable, state, unchanged PATH entry,
  and then empty dedicated directories. Never recursively remove broad user or
  system directories.

## Release workflow

Use `.github/workflows/release.yml`, dispatched manually from protected default
branch. Do not publish directly on tag push.

### Repository setup before first release

1. Keep repository public so anonymous users can access Release assets.
2. Enable maintainer MFA.
3. Protect default branch with review and required CI.
4. Protect `v*` tags; allow only release maintainers to create, update, or delete
   them.
5. Create protected GitHub `production` Environment requiring release approval.
6. Enable immutable releases when available. Never replace published asset bytes;
   release a higher fixed version instead.
7. Keep `Cargo.lock`, MSRV in `Cargo.toml`, and exact release toolchain in
   `rust-toolchain.toml` committed and tested.

### Release process

1. Merge reviewed release commit to protected default branch.
2. Update `Cargo.toml` version and `CHANGELOG.md`.
3. Pass normal CI with checked-in lockfile.
4. Create protected annotated tag `vMAJOR.MINOR.PATCH` at reviewed commit.
5. Manually dispatch release workflow from default branch, passing tag.
6. Preflight verifies stable tag grammar, annotated tag, target commit, default
   branch ancestry, clean checked-out source, Cargo/tag version match, committed
   release toolchain, and absence of existing GitHub Release.
7. Independent native builder jobs check out exact resolved commit, validate,
   build, smoke-test, inspect, and upload one temporary executable each.
8. Assembly job creates exact seven-file set, produces `SHA256SUMS`, and validates
   all file contract rules.
9. Draft job attests final assets, creates draft Release for the existing tag,
   uploads all assets once, downloads draft assets fresh through GitHub API,
   revalidates names and hashes, and smoke-tests downloaded Linux binary. When
   creating a Release for an existing tag, send `tag_name` only; omit
   `target_commitish` so GitHub does not require workflow-write authorization for
   a tagged commit that predates later workflow fixes.
10. After `production` approval, publish complete draft as latest stable release.
11. Never repair a published release in place. Publish a higher fixed release and
    clear advisory instead.

Security rules:

- Set workflow-level `permissions: {}`; grant each job only needed permissions.
- Publish job gets `contents: write`; attestation job gets only needed
  `attestations: write` and `id-token: write` permissions.
- Pin every GitHub Action to full commit SHA.
- Builders use `persist-credentials: false`.
- Privileged publish job does not check out, compile, or execute source or
  downloaded binary.
- Set concurrency by release tag and do not cancel in-progress release runs.

## Validation

### Automated

Normal CI and release builders run:

```sh
cargo fmt --check
cargo clippy --all-targets --all-features --locked -- -D warnings
cargo test --all-features --locked
cargo build --release --locked
```

Release checks also cover:

- Version, tag, binary output, asset names, manifest, and Release title match.
- Expected architecture, deployment/runtime baseline, and static Windows CRT.
- Exact output-path `--version` and `--help` smoke tests.
- Strict manifest malformed/duplicate/wrong-name/wrong-hash fixture cases.
- Installer failures for API error/rate limit, redirect, incomplete release,
  unsupported architecture, unsafe paths, altered binary, upgrade/downgrade,
  rollback, PATH duplication, uninstall, and dry-run/WhatIf side effects.
- Shell syntax/lint, PowerShell parser validation, and workflow YAML parsing.

### Manual release gates

Before first stable release, and after installer/build/network changes:

1. Use public prerelease to rehearse anonymous download path.
2. Test final candidate assets on clean Windows x64, macOS Intel, macOS Apple
   Silicon, and oldest supported Linux x64/glibc system.
3. Confirm no Rust, Cargo, existing `gitler`, or preconfigured PATH is present.
4. Test direct asset, inspect-first installer, convenience installer, upgrade,
   downgrade refusal, forced same-version replacement, uninstall, and new-shell
   PATH behavior.
5. Record expected unsigned Windows/macOS behavior without bypass instructions.
6. On real LAN devices, test `peers`, interactive `receive`, and send/receive
   with default firewall state. Document inbound UDP 5353 and receiver QUIC UDP
   port requirements.

## Documentation

README must explain:

- Supported OS/CPU/ABI table and minimum versions.
- Inspect-first and convenience install commands, including remote-code warning.
- Exact-version install, upgrade, downgrade, uninstall, and PATH behavior.
- Direct binary download and platform-correct checksum comparison.
- Artifact-attestation verification and exact trust meaning.
- unsigned Windows/macOS warning behavior without security-bypass advice.
- Firewall requirements, `SECURITY.md`, and source-build instructions under
  Development rather than primary Install section.

## Implementation order

1. Keep repository, tag, branch, and `production` protections operational.
2. Audit existing `install.sh` and `install.ps1` against installer contract; add
   missing focused tests rather than broad rewrites.
3. Audit `.github/workflows/release.yml` and `scripts/release/` against asset,
   permission, draft, attestation, and post-upload verification contract.
4. Keep CI validating Rust, installers, manifest fixtures, and workflow syntax.
5. Align README, changelog, and release instructions with actual installer
   behavior.
6. Rehearse an anonymous prerelease release end to end.
7. Perform clean-machine manual gates.
8. Publish first stable release only after every automated and manual gate passes.

## Definition of done

V1 is ready when users on each supported platform can download public release
assets, verify checksum and optional GitHub attestation, install correct binary
into user-owned directory without Rust/Cargo/admin rights, run `gitler --help`,
upgrade/uninstall without affecting unrelated files, and complete real local-LAN
transfer test. Release process must never publish partial assets or replace a
published asset in place.

Future binary targets, signing, notarization, package managers, and self-update
remain separate reviewed projects after this pipeline is stable.
