#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf 'Usage: %s VERSION DIRECTORY\n' "$0" >&2
    exit 2
}

fail() {
    printf 'release asset validation: %s\n' "$1" >&2
    exit 1
}

[ "$#" -eq 2 ] || usage
version=$1
asset_dir=$2

if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    fail "invalid release version: $version"
fi

expected=(
    "gitler-v${version}-windows-x86_64.exe"
    "gitler-v${version}-macos-x86_64"
    "gitler-v${version}-macos-aarch64"
    "gitler-v${version}-linux-x86_64-gnu"
    "install.sh"
    "install.ps1"
    "SHA256SUMS"
)
checksum_subjects=(
    "gitler-v${version}-windows-x86_64.exe"
    "gitler-v${version}-macos-x86_64"
    "gitler-v${version}-macos-aarch64"
    "gitler-v${version}-linux-x86_64-gnu"
    "install.sh"
    "install.ps1"
)

[[ -d "$asset_dir" && ! -L "$asset_dir" ]] || fail "asset directory is not a real directory: $asset_dir"

for name in "${expected[@]}"; do
    path=$asset_dir/$name
    [[ -f "$path" && ! -L "$path" ]] || fail "missing or non-regular asset: $name"
done

mapfile -t actual_paths < <(find "$asset_dir" -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort)
if [[ "${#actual_paths[@]}" -ne "${#expected[@]}" ]]; then
    fail "expected ${#expected[@]} assets, found ${#actual_paths[@]}"
fi
for path in "${actual_paths[@]}"; do
    name=${path##*/}
    found=0
    for expected_name in "${expected[@]}"; do
        if [[ "$name" == "$expected_name" ]]; then
            found=1
            break
        fi
    done
    (( found == 1 )) || fail "unexpected release asset: $name"
done

manifest=$asset_dir/SHA256SUMS
[[ -f "$manifest" && ! -L "$manifest" ]] || fail "missing checksum manifest"

# The manifest is intentionally strict: six lowercase hashes, two spaces, one
# filename, LF line endings, sorted by filename, and no duplicate subjects.
if LC_ALL=C grep -q $'\r' "$manifest"; then
    fail "checksum manifest contains CR characters"
fi
last_byte=$(tail -c 1 "$manifest" | od -An -t x1 | tr -d '[:space:]')
[[ "$last_byte" == 0a ]] || fail "checksum manifest must end with an LF newline"
if ! LC_ALL=C awk '
    BEGIN { ok = 1; count = 0 }
    {
        count++
        if (NF != 2 || length($1) != 64 || $1 ~ /[^0-9a-f]/ || $0 != $1 "  " $2 || $2 ~ /[[:space:]]/) {
            ok = 0
        }
        if (seen[$2]++) {
            ok = 0
        }
    }
    END { exit !(ok && count == 6) }
' "$manifest"; then
    fail "checksum manifest has invalid format, count, or duplicate names"
fi

mapfile -t manifest_names < <(awk '{ print $2 }' "$manifest")
mapfile -t sorted_manifest_names < <(printf '%s\n' "${manifest_names[@]}" | LC_ALL=C sort)
if [[ "${manifest_names[*]}" != "${sorted_manifest_names[*]}" ]]; then
    fail "checksum manifest is not sorted by filename"
fi

for name in "${checksum_subjects[@]}"; do
    count=0
    expected_hash=
    while IFS='  ' read -r hash manifest_name; do
        if [[ "$manifest_name" == "$name" ]]; then
            expected_hash=$hash
            ((count += 1))
        fi
    done < "$manifest"
    [[ "$count" -eq 1 ]] || fail "checksum manifest does not contain exactly one entry for $name"

    case "$name" in
        *.exe|gitler-*) max_bytes=$((100 * 1024 * 1024)) ;;
        install.sh|install.ps1) max_bytes=$((1024 * 1024)) ;;
    esac
    size=$(wc -c < "$asset_dir/$name")
    [[ "$size" -le "$max_bytes" ]] || fail "$name exceeds size limit"

    if command -v sha256sum >/dev/null 2>&1; then
        actual_hash=$(sha256sum "$asset_dir/$name" | awk '{ print $1 }')
    elif command -v shasum >/dev/null 2>&1; then
        actual_hash=$(shasum -a 256 "$asset_dir/$name" | awk '{ print $1 }')
    else
        fail "sha256sum or shasum is required"
    fi
    [[ "$actual_hash" == "$expected_hash" ]] || fail "checksum mismatch for $name"
done

printf 'Validated %s release assets in %s\n' "${#expected[@]}" "$asset_dir"
