# Changelog

All notable changes to `gitler` are documented here.

## [Unreleased]

## [0.1.3] - 2026-08-30

- Automatically configure PATH on normal installs when the shell supports it.
- Added `--no-modify-path` and `-NoAddToPath` opt-outs with copy-paste fallback commands.

## [0.1.2] - 2026-08-30

- Fixed PowerShell installer execution through `irm | iex`.
- Hardened Unix release resolution, path safety, and PATH/state rollback.
- Validate PowerShell installer syntax and no-write behavior on PowerShell 5.1 and 7+ in CI.

## [0.1.1] - 2026-08-30

- Added the native binary release, installer, checksum, and provenance
  infrastructure described in the release plan.
- Added security reporting and dual-license distribution files.
- Validate exact-version Release metadata before downloading an installer binary.
- Exercise the PowerShell installer's no-write `-WhatIf` path in CI.
