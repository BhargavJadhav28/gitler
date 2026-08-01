# No-cost native binary release plan

## 1. Scope and non-negotiable boundaries

Ship `gitler` as native executables users can install without Rust, Cargo, a
compiler, administrator access, or paid certificates.

This plan deliberately does **not** include Apple notarization, Windows
Authenticode, MSI/PKG installers, package-manager submissions, or a self-updater
in the first release.

Two boundaries remain true without paid platform certificates:

- Windows may show SmartScreen or “Unknown publisher” warnings.
- macOS may require a user to approve an unsigned downloaded executable in
  Gatekeeper.

No installer design can eliminate those OS trust prompts without platform code
signing. Do not document instructions to disable SmartScreen, Gatekeeper,
antivirus, or system-wide security controls.

“Foolproof” means the release process fails closed on known invalid states and
installers do not damage user files. It does not mean an unsigned binary can
bypass operating-system policy, or that a compromised user machine can be made
safe by an installer.

## 2. Launch preconditions

Complete these before implementation starts:

1. **Public distribution endpoint.** The source repository, or a separate
   distribution repository, must be public. Anonymous users must be able to
   fetch every documented GitHub Release URL over HTTPS. Private Release assets
   require authentication and cannot support public `curl`/PowerShell installs.
2. **No unexpected Actions bill.** Standard GitHub-hosted runners are free and
   unlimited for public repositories. Private repositories consume the account
   Actions/storage quota and can incur charges. Use standard runners only.
3. **Repository protection.** Enable MFA for maintainers; protect default branch
   with review and required CI; create a tag ruleset for `v*` that restricts
   creation, update, and deletion to designated release maintainers.
4. **Immutable releases.** Enable GitHub immutable releases if available for the
   repository. Releases are always created as drafts, fully populated, checked,
   then published. Never delete or replace a published asset to “fix” a build.
5. **Version policy.** Define stable release tags as exactly
   `vMAJOR.MINOR.PATCH`, where all components are non-negative decimal integers
   without leading zeroes except `0`. Initial public installers reject
   prerelease and build-metadata versions. Release candidates use a separate,
   explicitly documented prerelease flow.
6. **Toolchain policy.** Keep two distinct policies:
   - `package.rust-version` is the MSRV and is tested in CI.
   - `rust-toolchain.toml` pins the exact compiler used for release artifacts.

   Commit both choices before tagging. Do not treat an uncommitted local
   toolchain change as release policy. Remove `cargo generate-lockfile` from CI;
   all release and CI commands operate on the checked-in lockfile using
   `--locked`.
7. **Legal/support files.** Add `LICENSE-MIT`, `LICENSE-APACHE`, `SECURITY.md`,
   `CHANGELOG.md`, and repository/homepage metadata in `Cargo.toml`. The current
   Cargo license expression claims dual licensing, so license text must exist.

## 3. Supported platform contract

Publish only tested targets. Do not claim “all OSes.”

| Tier | Platform | Build target | Initial compatibility contract | Asset |
| --- | --- | --- | --- | --- |
| Stable | Windows x86_64 | `x86_64-pc-windows-msvc` | Supported Windows 10/11 x64 versions verified in clean-machine tests; no external Visual C++ runtime | `gitler-vX.Y.Z-windows-x86_64.exe` |
| Stable | macOS Intel | `x86_64-apple-darwin` | macOS 11.0+ Intel | `gitler-vX.Y.Z-macos-x86_64` |
| Stable | macOS Apple Silicon | `aarch64-apple-darwin` | macOS 11.0+ Apple Silicon | `gitler-vX.Y.Z-macos-aarch64` |
| Stable | Linux x86_64 | `x86_64-unknown-linux-gnu` | x86_64 glibc 2.35+ | `gitler-vX.Y.Z-linux-x86_64-gnu` |
| Deferred | Windows ARM64 | `aarch64-pc-windows-msvc` | No support or emulation promise | None |
| Deferred | Linux ARM64 | `aarch64-unknown-linux-*` | No support promise | None |

Rules:

- Build and test Windows/macOS binaries natively, not by cross-compiling.
- Build the GNU Linux artifact in a pinned `ubuntu:22.04` container image digest
  on a pinned Ubuntu host runner. This establishes glibc 2.35 as the supported
  baseline. Do not use `ubuntu-latest` as the compatibility-defining build
  environment.
- Set `MACOSX_DEPLOYMENT_TARGET=11.0` for both macOS builds. Verify the produced
  binary deployment target and test it on the oldest advertised macOS version.
- Build Windows with the static MSVC runtime only after confirming a clean
  Windows machine launches it without the Visual C++ Redistributable. If static
  CRT linking cannot be validated, do not publish until a documented dependency
  solution exists.
- Inspect release binaries before packaging:
  - Windows: expected PE architecture and no unexpected runtime dependency.
  - macOS: expected architecture and `otool -L` dependencies.
  - Linux: expected ELF architecture, dynamic loader, and no GLIBC symbol newer
    than 2.35.
- In every native build job, assert runner CPU architecture, Rust target, and
  output binary architecture. Runner labels can change; labels alone are not
  proof.

## 4. Release asset contract

Use direct executable assets, not archives. This removes archive extraction,
symlink, hard-link, traversal, and executable-bit edge cases from installers.

For `v0.1.0`, GitHub Release contains exactly:

```text
gitler-v0.1.0-windows-x86_64.exe
gitler-v0.1.0-macos-x86_64
gitler-v0.1.0-macos-aarch64
gitler-v0.1.0-linux-x86_64-gnu
install.sh
install.ps1
SHA256SUMS
```

Requirements:

- Each executable is built from the release tag using
  `cargo build --release --locked`.
- `install.sh` and `install.ps1` are sourced from that same tag and carry no
  mutable external dependency.
- `SHA256SUMS` contains exactly one entry for every listed executable and
  installer script, sorted by filename, LF-delimited, and formatted as:

  ```text
  <64 lowercase hexadecimal SHA-256 characters><two spaces><filename>
  ```

- The final publisher validates asset names, count, size limits, file hashes,
  and that no filename appears more than once.
- Build jobs smoke-test the exact executable path. Final jobs also download the
  release assets into a clean directory and smoke-test the downloaded binary;
  they never rely on a `PATH` lookup.
- The binary `--version` must parse as exactly the tag version without the `v`
  prefix. `gitler --version` is available through the existing Clap command
  configuration.

Direct-download documentation must tell Unix users to save the file, run
`chmod 755 <file>`, verify it, then place it in their preferred personal binary
directory. It must not tell users to remove quarantine attributes or weaken OS
security settings.

## 5. Integrity, provenance, and trust model

### Required, free controls

1. Generate and verify `SHA256SUMS` for accidental-corruption and
   wrong-file detection.
2. Generate GitHub artifact attestations for **every final release asset** using
   GitHub Actions OIDC. Grant only the attesting job:

   ```yaml
   attestations: write
   id-token: write
   ```

3. Attach build provenance to the source tag commit, repository, protected
   release workflow, and final asset digest. Block publication if attestation
   generation fails.
4. Document an independently verifiable path using the current GitHub CLI
   artifact-attestation verification command, constrained to the exact
   `BhargavJadhav28/gitler` repository and the release asset. Exercise that
   command during every release rehearsal.

Artifact attestation is free and is not a code-signing certificate. It provides
publisher/build provenance for users who choose to verify it.

### Explicit limits

- A checksum manifest downloaded from the same release as a binary detects
  corruption or mismatched files. It **does not** independently authenticate a
  compromised GitHub account, mutable Release asset, or bootstrap script.
- A one-line installer is a convenience path that trusts GitHub HTTPS and the
  public release publisher. It is not independently verified before execution.
- The download-first verification path is the recommended path for users who
  need stronger assurance. It verifies the artifact attestation first, then
  the matching checksum.

Do not claim cryptographic publisher authentication from SHA-256 alone.

## 6. Release workflow architecture

Add `.github/workflows/release.yml`. Use manual `workflow_dispatch` from the
protected default branch, not automatic tag-push publication. GitHub runs a
`workflow_dispatch` workflow from the default branch, keeping publishing logic
reviewed and preventing a tag from supplying arbitrary release workflow code.

### Release request

A designated maintainer:

1. Merges the reviewed release commit into the protected default branch.
2. Creates protected annotated tag `vMAJOR.MINOR.PATCH` at that reviewed commit.
3. Manually dispatches `release.yml` from the default branch with that tag as a
   string input.

Preflight validates, without shell interpolation of untrusted input:

- Exact stable-tag grammar.
- Tag exists and is annotated.
- Tag resolves to one commit.
- Resolved commit is an ancestor of the protected default branch.
- Tag version equals `package.version` exactly after removing only the leading
  `v`.
- No GitHub Release already exists for the tag.
- Target source has no uncommitted state because it is checked out by immutable
  commit SHA.

Use `concurrency` keyed by release tag with `cancel-in-progress: false`, so two
runs cannot publish or race the same version.

### Least-privilege jobs

Set workflow-level permissions to empty:

```yaml
permissions: {}
```

Use separate jobs:

| Job | What it does | Permissions |
| --- | --- | --- |
| Preflight | Validates tag, version, commit ancestry | `contents: read` |
| Native builders | Checkout tagged source; test; build one asset each | `contents: read`, plus attestation/OIDC only where artifact attestation runs |
| Assemble/verify | Collects files; validates exact asset contract; writes checksums | No source execution; minimum artifact access |
| Publish | Creates draft, uploads, re-downloads/verifies, attests final files, publishes after approval | `contents: write`, `attestations: write`, `id-token: write` |

The publish job uses a protected `production` Environment with required human
approval. It must not check out, compile, run Cargo, run installer scripts, or
execute downloaded binaries. It only handles validated files and GitHub Release
API operations.

All actions, including GitHub-owned actions, are pinned to full commit SHAs.
`actions/checkout` in build jobs uses `persist-credentials: false`. Do not use
build caches in privileged publish jobs. Do not grant write tokens to pull
request workflows or enable write tokens for fork pull requests.

### Native builders

Use explicit current GitHub-hosted standard runner labels at implementation time,
not `*-latest`. At time of implementation, verify they match this intent:

| Build | Runner intent |
| --- | --- |
| Windows x86_64 | Explicit x64 Windows standard runner |
| macOS Intel | Explicit Intel macOS standard runner |
| macOS Apple Silicon | Explicit ARM64 macOS standard runner |
| Linux x86_64 | Explicit Ubuntu standard runner hosting pinned Ubuntu 22.04 build container |

Each builder:

1. Checks out the preflight-resolved commit SHA, not a floating branch.
2. Installs the committed exact release Rust toolchain.
3. Runs:

   ```sh
   cargo fmt --check
   cargo clippy --all-targets --all-features --locked -- -D warnings
   cargo test --all-features --locked
   cargo build --release --locked
   ```

4. Runs the exact output path with `--version` and `--help`. If `--target` is
   used, test `target/<target>/release/...`, not `target/release/...`.
5. Performs target-specific architecture/runtime inspection.
6. Copies only the expected executable to a uniquely named staging file.
7. Uploads that file as a temporary workflow artifact with a short retention
   period and a unique artifact name.

Update normal CI too:

- Remove `cargo generate-lockfile`.
- Use `--locked` from checkout onward.
- Test the declared MSRV separately from the pinned release compiler.
- Pin all Actions to full commit SHAs.

### Draft-first publication

After all builders succeed:

1. Assemble exactly the seven expected release files in a new directory.
2. Generate `SHA256SUMS` from final bytes.
3. Validate all names/hashes and attest all final assets.
4. Create a **draft** GitHub Release.
5. Upload the full asset set once.
6. Re-download the uploaded draft assets through the GitHub API into a fresh
   directory; validate exact names, count, and checksums again.
7. Keep the release unpublished if any check fails. Never publish partial
   assets; delete/retain the failed draft only for maintainer investigation.
8. After protected-environment approval, publish the draft as a stable release
   and deliberately set it as `latest`.

A published release is never changed in place. For a bad release, publish a
higher fixed version and issue a clear withdrawal/security notice.

## 7. Installer design

Installers are distribution code and need the same review, tests, and version
control as the Rust application.

### Bootstrap URLs

Offer both convenience and safer forms.

Convenience only, clearly labeled as remote-code execution:

```sh
curl -fsSL https://github.com/BhargavJadhav28/gitler/releases/latest/download/install.sh | sh
```

```powershell
irm https://github.com/BhargavJadhav28/gitler/releases/latest/download/install.ps1 | iex
```

Primary documented form downloads first, checks the HTTP download succeeded,
lets users inspect the script, then executes it. Do not make pipe execution the
only documented method. The scripts themselves must not use `curl | sh`.

The bootstrap scripts may be fetched through `latest/download`, but they must
resolve the target release exactly once before downloading any binary or
checksum:

1. For default install, query GitHub’s latest stable release API once.
2. Require a non-draft, non-prerelease stable tag matching plan grammar.
3. Require the exact expected asset names in that one release response.
4. Download every subsequent item through tag-specific immutable-style URLs:

   ```text
   /releases/download/vX.Y.Z/<asset>
   ```

5. For `--version vX.Y.Z`, skip latest lookup and use only that exact tag.
6. If latest lookup hits API rate limits or fails, stop with an actionable
   message to rerun with an explicit version; never fall back to mixed
   `latest/download` requests.

This prevents a newly published latest release from changing selection between
script, checksum, and executable downloads.

### `install.sh` contract

`install.sh` is strict POSIX `sh`; it must work with stock macOS `/bin/sh` and
common Linux `/bin/sh`. Do not use Bash arrays, process substitution, GNU-only
`sed`/`readlink`, or untested non-POSIX syntax.

Required tools: `curl`, `mktemp`, `chmod`, `mv`, and either `shasum` (macOS) or
`sha256sum` (Linux). Check each tool before downloading and fail with a precise
installation instruction if missing.

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

Rules:

- Default installation directory is
  `${XDG_DATA_HOME:-$HOME/.local/share}/gitler/bin`; `gitler` is the only
  installed executable. This dedicated directory avoids taking ownership of the
  shared `~/.local/bin` directory.
- `--install-dir` always means a directory, never a filename. Resolve and quote
  it safely; create missing parents only below the user-selected path.
- Map only supported native architectures:
  - Linux: `x86_64`/`amd64` to Linux x86_64.
  - macOS: detect Apple Silicon deliberately, including Rosetta; choose native
    Apple Silicon when possible and Intel only when truly required.
  - Reject unknown platforms/architectures. Do not silently choose an emulated
    or unsupported binary.
- Download executable to a private temporary file, verify it against exactly
  one strict `SHA256SUMS` entry, set mode `755`, and execute it by absolute
  temporary path for `--version`/`--help` verification.
- Validate the observed version equals resolved release version before touching
  an existing install.
- Stage the verified new file on the same filesystem as destination, then
  atomically rename it over the managed executable. Clean temporary files on
  normal exit, signals, and errors. Preserve old executable on failure.
- Reject a destination that is a symlink, directory, device, or other
  non-regular file. Never recursively delete a user directory.
- First install refuses an existing unrecognized installation directory. A
  small installer-owned state file records format version, installed version,
  asset filename, and whether installer added PATH.
- An ordinary newer managed version upgrades transactionally. Same-version
  installation is a no-op only if its hash matches; otherwise require `--force`.
  Lower version is rejected unless `--allow-downgrade` is explicitly present.
- `--force` may replace only an existing regular `gitler` file in an
  installer-managed directory; it never broadens deletion/replacement scope.
- `--dry-run` performs no download, write, profile change, or executable run.

#### Unix PATH behavior

A script piped into `sh` cannot modify its caller’s current shell environment.
It also cannot safely infer every user’s shell startup configuration.

Default behavior:

- Install binary and validate it by absolute path.
- Print exact command needed for the current terminal and exact persistent
  command for detected shell.
- State that a new terminal or sourcing the relevant profile is required.
- Do **not** edit profile files automatically.

`--modify-path` is explicit opt-in. It may edit only known shell files with a
clearly delimited, idempotent `gitler` block:

- Bash: selected interactive startup file according to documented login/nonlogin
  choice.
- Zsh: selected interactive startup file according to documented choice.
- Fish: `~/.config/fish/conf.d/gitler.fish` using Fish syntax.
- Unknown shell/noninteractive session: refuse profile editing and print manual
  instructions.

Quote paths correctly, including spaces and shell-special characters. Never
append duplicate blocks. `--remove-path` removes only an unchanged installer
marker block, never a user-edited profile line.

### `install.ps1` contract

Support Windows PowerShell 5.1+ and PowerShell 7+ on Windows only. Check the
host and version first; use terminating errors, literal paths, HTTPS, and a
clear proxy/TLS failure message.

Supported parameters mirror Unix where meaningful:

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

Use advanced PowerShell function semantics (`SupportsShouldProcess`) so
`-WhatIf` genuinely makes no changes.

Rules:

- Default directory is `%LOCALAPPDATA%\Programs\gitler`.
- Determine actual OS architecture, not only the architecture of the running
  PowerShell process. Reject Windows ARM64 until it is explicitly supported;
  do not silently rely on x64 emulation.
- Resolve release once, download executable and manifest to unique temp files,
  validate strict manifest entry with `Get-FileHash`, run staged executable by
  literal absolute path, and verify its version.
- Replace an existing managed executable only after staging verification. Use
  a transactional file replacement with backup where Windows supports it;
  preserve old binary on failure. If executable is locked, leave old version
  intact and return a clear error.
- Read and modify only User-scope `Path`, never merged process `$env:Path` or
  Machine-scope `Path`. Normalize path entries for case-insensitive duplicate
  detection while preserving unrelated entries.
- `-AddToPath` is explicit opt-in. It records installer ownership in state,
  updates current process `PATH` only after successful install, updates User
  `Path`, and broadcasts environment change when practical. State terminal
  restart requirement.
- `-RemovePath` removes only the exact dedicated install directory if state
  records that this installer added it. Never remove a broad or shared path.

### Uninstall

`--uninstall` / `-Uninstall`:

1. Reads installer state from the selected dedicated install directory.
2. Refuses unrecognized directories unless explicit, narrow force behavior is
   approved and implemented.
3. Removes only managed executable, state file, empty dedicated directories,
   and an unchanged installer-owned PATH entry/block when requested.
4. Never deletes shared `~/.local/bin`, `%LOCALAPPDATA%\Programs`, a user
   profile, or unrelated files.

## 8. Documentation requirements

Update README so **Install** describes binaries first and source builds under
**Development**.

Include:

1. Supported OS/CPU/ABI table and current minimum versions.
2. Download-first and convenience installer commands, with remote-code warning.
3. Exact-version installation command and explanation of API-rate-limit fallback.
4. Direct executable download, Unix `chmod`, user-local placement, and PATH
   instructions.
5. Platform-correct checksum checks that compare one selected file to its exact
   manifest entry. Do not document `sha256sum -c SHA256SUMS` when only one asset
   was downloaded; do not show `Get-FileHash` without comparison.
6. Artifact-attestation verification instructions and its trust meaning.
7. Upgrade, downgrade, PATH, uninstall, proxy/error, and disk-location behavior.
8. Honest unsigned Windows/macOS warning behavior; no security-bypass advice.
9. Existing firewall requirements: inbound UDP 5353 for mDNS and receiver QUIC
   UDP port.
10. `SECURITY.md` reporting channel and release-advisory process.

## 9. Testing and release gates

### Automated gates

Before a draft is created:

- Tag, Cargo version, binary version, asset names, manifest, and release title
  agree.
- Checked-in lockfile remains unchanged and all locked validation passes.
- Every native output passes architecture/runtime inspection.
- Every staged executable passes absolute-path `--version` and `--help` checks.
- Release asset contract has exact expected names/count and no extras.
- Checksums are validated before and after GitHub upload.
- Artifact attestations generate successfully and verification succeeds.
- Release workflow has static validation/linting for YAML and shell/PowerShell
  scripts where available.

Installer test fixtures must cover:

- Missing, malformed, duplicate, wrong-name, and wrong-hash manifest entries.
- HTTP errors, redirect to non-HTTPS, interrupted download, API rate limiting,
  draft/prerelease/invalid tag, and missing release asset.
- Unsupported architecture; macOS Rosetta; 32-bit PowerShell on x64 Windows;
  Windows ARM64 rejection.
- Existing managed/up-to-date/modified/unmanaged installations; upgrade,
  downgrade, force, locked Windows executable, and rollback after failure.
- Custom paths, spaces, non-ASCII usernames, missing parent directories,
  unwritable directories, symlinks, and cleanup.
- POSIX shell on macOS/Linux; Bash, Zsh, Fish profile behavior; Windows
  PowerShell 5.1 and 7.
- PATH duplication prevention and new-shell behavior.
- `--dry-run`/`-WhatIf` side-effect absence and narrow uninstall behavior.

### Manual clean-machine gates

GitHub-hosted CI cannot reliably test LAN multicast, firewall prompts,
Gatekeeper, SmartScreen, or real user home-directory profiles.

For every first stable release and any change to network, packaging, installer,
runtime dependencies, or build environment:

1. Test final candidate assets on clean matching Windows x64, macOS Intel,
   macOS Apple Silicon, and oldest supported Linux x86_64/glibc machine.
2. Confirm no Rust/Cargo, existing `gitler`, or preconfigured installer path.
3. Exercise direct binary, download-first installer, upgrade, downgrade refusal,
   uninstall, and new-shell PATH behavior.
4. Record expected unsigned Windows/macOS behavior without bypass guidance.
5. On two real devices per OS family, test `peers`, interactive `receive`, and
   same-LAN send/receive with default firewall state and documented rules.

Use public prerelease candidates to rehearse the anonymous installer path.
For stable releases, build final assets, validate them in a draft with
authenticated workflow/API checks, then publish only after all gates pass.
The public `latest` endpoint can never expose an incomplete release because
only fully uploaded drafts become published stable releases.

## 10. Incident and maintenance process

Add `SECURITY.md` before first release. For a bad or vulnerable release:

1. Stop promoting it as latest where GitHub supports this without mutating
   assets.
2. Publish a higher fixed release; never replace historical asset bytes.
3. Publish GitHub Release notes and, for security issues, a GitHub Security
   Advisory stating affected versions, fixed version, and mitigation.
4. Update installer documentation to recommend exact safe version if needed.
5. Rotate/review repository credentials, rulesets, and workflow history after
   suspected release-account or workflow compromise.

Run scheduled dependency review and GitHub Actions update review. A lockfile
makes builds repeatable only if dependencies and release workflow are actively
maintained.

## 11. Implementation order

1. Resolve committed MSRV/release-toolchain policy; remove lockfile regeneration
   from CI; add licenses, security policy, changelog, repository metadata.
2. Make public distribution access and repository/tag/workflow protections
   operational; verify anonymous Release URL access with a test release.
3. Implement direct-binary packaging scripts and explicit ABI/deployment/CRT
   checks.
4. Implement and test `install.sh` and `install.ps1` in isolation with fixtures.
5. Add protected manual release workflow, draft-first publication, checksums,
   and free artifact attestations.
6. Update README and test public prerelease install flow on clean machines.
7. Run first stable release rehearsal, resolve every failed gate, then publish
   first stable tag.
8. Add code signing, package managers, ARM64 targets, and self-update only as
   separate reviewed projects after the no-cost pipeline is stable.

## 12. Definition of done

The first stable native-binary release is ready only when all gates above pass
and users on every listed stable target can download a public immutable release
asset, verify its checksum and free provenance attestation, install to a
user-owned dedicated directory without Rust, configure PATH through documented
or explicit opt-in behavior, run `gitler --help`, and complete a real local-LAN
transfer test.

The release must state plainly that no-cost unsigned Windows/macOS distribution
can require a user-facing OS trust decision. That is the remaining intentional
trade-off until code-signing certificates are funded.
