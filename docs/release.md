# Release checklist

Use this checklist for every code or installer release. Replace `vX.Y.Z` with
the next unused stable version.

## 1. Make and validate the change

Keep the working tree focused. Do not modify an already-published release.

Run the local checks:

```sh
cargo fmt --check
cargo clippy --all-targets --all-features --locked -- -D warnings
cargo test --all-features --locked
cargo package --locked --allow-dirty

sh -n install.sh
bash tests/installers/test-install-sh.sh
bash tests/installers/test-manifests.sh
git diff --check
```

Windows installer syntax and `WhatIf` checks run in CI. Let CI complete before
publishing.

## 2. Prepare the version

1. Update `package.version` in `Cargo.toml` to the next version.
2. Update the matching root `gitler` package entry in `Cargo.lock`.
3. Add a concise entry to `CHANGELOG.md`.
4. Update documentation only when the user-facing behavior changed.
5. Review the complete diff and confirm the version is consistent.

For a documentation-only change, push the change without creating a binary
release unless the release assets or package version need updating.

## 3. Commit `main`

Make sure the tag version is on the protected default branch:

```sh
git status
git diff --check

git add Cargo.toml Cargo.lock CHANGELOG.md README.md install.sh install.ps1 \
  .github/workflows tests scripts docs

git commit -m "Prepare vX.Y.Z release"
git push origin main
```

Only stage files belonging to this release. Do not stage unrelated or untracked
files.

## 4. Create the annotated tag

Create and push the tag after `main` contains the release commit:

```sh
git tag -a vX.Y.Z -m "Release vX.Y.Z"
git push origin vX.Y.Z
```

Verify that it is annotated and visible on the remote:

```sh
git cat-file -t vX.Y.Z
git ls-remote --exit-code origin refs/tags/vX.Y.Z
```

The first command must print `tag`. Never reuse a published tag or version.

## 5. Run the GitHub release workflow

On GitHub:

1. Open **Actions → Release**.
2. Click **Run workflow**.
3. Select branch **`main`**.
4. Enter the exact tag `vX.Y.Z`.
5. Run the workflow.

Do **not** create the GitHub Release manually. The workflow validates the tag,
builds the four supported binaries, creates checksums and attestations, creates
a draft release, and verifies its seven assets:

- Windows x86_64 binary
- macOS Intel binary
- macOS Apple Silicon binary
- Linux x86_64 glibc binary
- `install.sh`
- `install.ps1`
- `SHA256SUMS`

After the draft verification succeeds, review the draft and approve the
`production` environment. The workflow then publishes the release as latest.

## 6. Verify after publication

Confirm the tag and latest release, then test on clean supported machines:

```sh
git ls-remote --exit-code origin refs/tags/vX.Y.Z
curl -fsSL https://github.com/BhargavJadhav28/gitler/releases/latest/download/install.sh | sh
```

```powershell
irm https://github.com/BhargavJadhav28/gitler/releases/latest/download/install.ps1 | iex
```

Check `gitler --version`, PATH setup, send/receive behavior, and uninstall on
at least one Windows, macOS, and Linux machine when possible.

If the workflow fails, inspect the failed job and fix the cause. Do not create a
second release or mutate published asset bytes; use a higher version for a
corrective release.
