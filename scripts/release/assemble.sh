#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf 'Usage: %s VERSION BUILDER_DIRECTORY OUTPUT_DIRECTORY\n' "$0" >&2
    exit 2
}

fail() {
    printf 'release assembly: %s\n' "$1" >&2
    exit 1
}

[ "$#" -eq 3 ] || usage
version=$1
builder_dir=$2
output_dir=$3

if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    fail "invalid release version: $version"
fi
[[ -d "$builder_dir" && ! -L "$builder_dir" ]] || fail "builder directory is not a real directory"
if [[ -e "$output_dir" || -L "$output_dir" ]]; then
    fail "output directory already exists: $output_dir"
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
mkdir -p "$output_dir"

copy_builder_asset() {
    local name=$1
    local destination=$output_dir/$name
    mapfile -t matches < <(find "$builder_dir" -type f -name "$name" -print | LC_ALL=C sort)
    [[ "${#matches[@]}" -eq 1 ]] || fail "expected exactly one builder asset named $name"
    cp "${matches[0]}" "$destination"
    [[ -f "$destination" && ! -L "$destination" ]] || fail "failed to stage $name"
}

copy_builder_asset "gitler-v${version}-windows-x86_64.exe"
copy_builder_asset "gitler-v${version}-macos-x86_64"
copy_builder_asset "gitler-v${version}-macos-aarch64"
copy_builder_asset "gitler-v${version}-linux-x86_64-gnu"

for installer in install.sh install.ps1; do
    [[ -f "$repo_root/$installer" && ! -L "$repo_root/$installer" ]] || fail "missing installer source: $installer"
    cp "$repo_root/$installer" "$output_dir/$installer"
done
chmod 755 \
    "$output_dir/install.sh" \
    "$output_dir/gitler-v${version}-macos-x86_64" \
    "$output_dir/gitler-v${version}-macos-aarch64" \
    "$output_dir/gitler-v${version}-linux-x86_64-gnu"

checksum_files=(
    "gitler-v${version}-linux-x86_64-gnu"
    "gitler-v${version}-macos-aarch64"
    "gitler-v${version}-macos-x86_64"
    "gitler-v${version}-windows-x86_64.exe"
    install.ps1
    install.sh
)
(
    cd "$output_dir"
    for name in "${checksum_files[@]}"; do
        hash=$(sha256sum "$name" | awk '{ print $1 }')
        printf '%s  %s\n' "$hash" "$name"
    done
) | LC_ALL=C sort -k2,2 > "$output_dir/SHA256SUMS"

"$script_dir/verify-assets.sh" "$version" "$output_dir"
