#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/gitler-install-test.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT HUP INT TERM

fixture_dir=$temp_dir/fixture
mock_bin=$temp_dir/mock-bin
install_dir="$temp_dir/install with spaces and 'quote'"
home_dir="$temp_dir/home"
mkdir -p "$fixture_dir" "$mock_bin" "$home_dir"

cat > "$mock_bin/uname" <<'EOF'
#!/bin/sh
case "${1:-}" in
    -m) printf '%s\n' x86_64 ;;
    *) printf '%s\n' Linux ;;
esac
EOF

cat > "$mock_bin/curl" <<'EOF'
#!/bin/sh
set -eu
output=''
url=''
write_status=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o|--connect-timeout|--max-time|--retry|--retry-delay)
            if [ "$#" -lt 2 ]; then exit 2; fi
            if [ "$1" = '-o' ]; then output=$2; fi
            shift 2
            ;;
        -w)
            if [ "$#" -lt 2 ]; then exit 2; fi
            write_status=1
            shift 2
            ;;
        --proto|--proto-redir)
            shift 2
            ;;
        -*) shift ;;
        *) url=$1; shift ;;
    esac
done
[ -n "$output" ] || exit 2
case "$url" in
    *releases/latest|*releases/tags/v0.1.0)
        cp "$FIXTURE_DIR/${MOCK_RELEASE_FILE:-release.json}" "$output"
        ;;
    *SHA256SUMS) cp "$FIXTURE_DIR/SHA256SUMS" "$output" ;;
    *gitler-v0.1.0-linux-x86_64-gnu) cp "$FIXTURE_DIR/gitler-v0.1.0-linux-x86_64-gnu" "$output" ;;
    *) exit 22 ;;
esac
if [ "$write_status" -eq 1 ]; then
    printf '200'
fi
EOF

cat > "$fixture_dir/gitler-v0.1.0-linux-x86_64-gnu" <<'EOF'
#!/bin/sh
case "${1:-}" in
    --version) printf '%s\n' 'gitler 0.1.0' ;;
    --help) printf '%s\n' 'fixture help' ;;
    *) exit 0 ;;
esac
EOF
chmod 755 "$fixture_dir/gitler-v0.1.0-linux-x86_64-gnu" "$mock_bin/uname" "$mock_bin/curl"
printf '#!/bin/sh\nprintf install\n' > "$fixture_dir/install.sh"
printf 'Write-Output install\n' > "$fixture_dir/install.ps1"

(
    cd "$fixture_dir"
    for name in \
        gitler-v0.1.0-linux-x86_64-gnu \
        gitler-v0.1.0-macos-aarch64 \
        gitler-v0.1.0-macos-x86_64 \
        gitler-v0.1.0-windows-x86_64.exe \
        install.ps1 \
        install.sh; do
        if [ ! -f "$name" ]; then
            printf 'fixture-only\n' > "$name"
        fi
        hash=$(sha256sum "$name" | awk '{ print $1 }')
        printf '%s  %s\n' "$hash" "$name"
    done
) | LC_ALL=C sort -k2,2 > "$fixture_dir/SHA256SUMS"

cat > "$fixture_dir/release.json" <<'EOF'
{"tag_name":"v0.1.0","draft":false,"prerelease":false,"assets":[{"name":"gitler-v0.1.0-windows-x86_64.exe"},{"name":"gitler-v0.1.0-macos-x86_64"},{"name":"gitler-v0.1.0-macos-aarch64"},{"name":"gitler-v0.1.0-linux-x86_64-gnu"},{"name":"install.sh"},{"name":"install.ps1"},{"name":"SHA256SUMS"}]}
EOF
sed 's/"draft":false/"draft":true/' "$fixture_dir/release.json" > "$fixture_dir/release-draft.json"

PATH="$mock_bin:$PATH" HOME="$home_dir" SHELL=/bin/bash FIXTURE_DIR="$fixture_dir" \
    "$repo_root/install.sh" --version v0.1.0 --modify-path --install-dir "$install_dir" >/dev/null

test -f "$install_dir/gitler"
test -f "$home_dir/.bashrc"
grep -Fq '# >>> gitler installer PATH (do not edit) >>>' "$home_dir/.bashrc"
bash -n "$home_dir/.bashrc"
test -f "$install_dir/.gitler-install-state"

PATH="$mock_bin:$PATH" FIXTURE_DIR="$fixture_dir" \
    "$repo_root/install.sh" --version v0.1.0 --install-dir "$install_dir" >/dev/null

printf '%s\n' '# changed managed file' >> "$install_dir/gitler"
if PATH="$mock_bin:$PATH" FIXTURE_DIR="$fixture_dir" \
    "$repo_root/install.sh" --version v0.1.0 --install-dir "$install_dir" >/dev/null 2>&1; then
    printf 'same-version modified install unexpectedly succeeded\n' >&2
    exit 1
fi

PATH="$mock_bin:$PATH" FIXTURE_DIR="$fixture_dir" \
    "$repo_root/install.sh" --version v0.1.0 --force --install-dir "$install_dir" >/dev/null

PATH="$mock_bin:$PATH" HOME="$home_dir" SHELL=/bin/bash FIXTURE_DIR="$fixture_dir" \
    "$repo_root/install.sh" --remove-path --install-dir "$install_dir" >/dev/null
if grep -Fq '# >>> gitler installer PATH (do not edit) >>>' "$home_dir/.bashrc"; then
    printf 'PATH marker was not removed\n' >&2
    exit 1
fi

PATH="$mock_bin:$PATH" FIXTURE_DIR="$fixture_dir" \
    "$repo_root/install.sh" --uninstall --install-dir "$install_dir" >/dev/null

[ ! -e "$install_dir" ]

draft_install_dir="$temp_dir/draft-install"
if PATH="$mock_bin:$PATH" FIXTURE_DIR="$fixture_dir" MOCK_RELEASE_FILE=release-draft.json \
    "$repo_root/install.sh" --version v0.1.0 --install-dir "$draft_install_dir" >/dev/null 2>&1; then
    printf 'explicit draft release unexpectedly installed\n' >&2
    exit 1
fi
[ ! -e "$draft_install_dir" ]

latest_install_dir="$temp_dir/latest-install"
PATH="$mock_bin:$PATH" HOME="$home_dir" SHELL=/bin/bash FIXTURE_DIR="$fixture_dir" \
    "$repo_root/install.sh" --install-dir "$latest_install_dir" >/dev/null
test -f "$latest_install_dir/gitler"
PATH="$mock_bin:$PATH" FIXTURE_DIR="$fixture_dir" \
    "$repo_root/install.sh" --uninstall --install-dir "$latest_install_dir" >/dev/null
[ ! -e "$latest_install_dir" ]

real_parent="$temp_dir/real-parent"
symlink_parent="$temp_dir/symlink-parent"
mkdir -p "$real_parent"
ln -s "$real_parent" "$symlink_parent"
if [ -L "$symlink_parent" ]; then
    symlink_install_dir="$symlink_parent/install"
    if PATH="$mock_bin:$PATH" FIXTURE_DIR="$fixture_dir" \
        "$repo_root/install.sh" --version v0.1.0 --install-dir "$symlink_install_dir" >/dev/null 2>&1; then
        printf 'symlinked parent install unexpectedly succeeded\n' >&2
        exit 1
    fi
    [ ! -e "$real_parent/install" ]
fi

printf 'POSIX installer lifecycle fixtures passed.\n'
