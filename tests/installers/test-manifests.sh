#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
validator=$repo_root/scripts/release/verify-assets.sh
version=0.1.0
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/gitler-manifest-test.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT HUP INT TERM

make_valid_fixture() {
    local dir=$1
    mkdir -p "$dir"
    printf 'windows\n' > "$dir/gitler-v${version}-windows-x86_64.exe"
    printf 'intel\n' > "$dir/gitler-v${version}-macos-x86_64"
    printf 'apple\n' > "$dir/gitler-v${version}-macos-aarch64"
    printf 'linux\n' > "$dir/gitler-v${version}-linux-x86_64-gnu"
    printf '#!/bin/sh\n' > "$dir/install.sh"
    printf 'Write-Output install\n' > "$dir/install.ps1"
    chmod 755 "$dir/install.sh"
    (
        cd "$dir"
        for name in \
            "gitler-v${version}-linux-x86_64-gnu" \
            "gitler-v${version}-macos-aarch64" \
            "gitler-v${version}-macos-x86_64" \
            "gitler-v${version}-windows-x86_64.exe" \
            install.ps1 \
            install.sh; do
            hash=$(sha256sum "$name" | awk '{ print $1 }')
            printf '%s  %s\n' "$hash" "$name"
        done
    ) | LC_ALL=C sort -k2,2 > "$dir/SHA256SUMS"
}

expect_success() {
    "$validator" "$version" "$1" >/dev/null
}

expect_failure() {
    if "$validator" "$version" "$1" >/dev/null 2>&1; then
        printf 'expected validator failure: %s\n' "$2" >&2
        exit 1
    fi
}

sh -n "$repo_root/install.sh"

valid=$temp_dir/valid
make_valid_fixture "$valid"
expect_success "$valid"

missing=$temp_dir/missing
cp -R "$valid" "$missing"
sed -i '/install\.ps1$/d' "$missing/SHA256SUMS"
expect_failure "$missing" missing-entry

malformed=$temp_dir/malformed
cp -R "$valid" "$malformed"
sed -i '1s/^[0-9a-f]/z/' "$malformed/SHA256SUMS"
expect_failure "$malformed" malformed-hash

duplicate=$temp_dir/duplicate
cp -R "$valid" "$duplicate"
printf '%s\n' "$(sed -n '1p' "$duplicate/SHA256SUMS")" >> "$duplicate/SHA256SUMS"
expect_failure "$duplicate" duplicate-entry

wrong_name=$temp_dir/wrong-name
cp -R "$valid" "$wrong_name"
sed -i 's/windows-x86_64/wrong-name/' "$wrong_name/SHA256SUMS"
expect_failure "$wrong_name" wrong-name

wrong_hash=$temp_dir/wrong-hash
cp -R "$valid" "$wrong_hash"
printf 'changed\n' >> "$wrong_hash/install.sh"
expect_failure "$wrong_hash" wrong-hash

extra=$temp_dir/extra
cp -R "$valid" "$extra"
printf 'extra\n' > "$extra/unexpected.txt"
expect_failure "$extra" unexpected-asset

printf 'Installer manifest fixtures passed.\n'
