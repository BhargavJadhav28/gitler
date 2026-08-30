#!/bin/sh
set -eu

REPOSITORY='BhargavJadhav28/gitler'
RELEASES_API="https://api.github.com/repos/$REPOSITORY/releases"
LATEST_API="$RELEASES_API/latest"
INSTALL_STATE='.gitler-install-state'
PROGRAM='gitler'
FORMAT_VERSION='1'

REQUESTED_VERSION=''
INSTALL_DIR_ARG=''
FORCE=0
ALLOW_DOWNGRADE=0
MODIFY_PATH=0
REMOVE_PATH=0
UNINSTALL=0
DRY_RUN=0

TMP_DIR=''
STATE_TMP_FILE=''
STAGE_FILE=''
ROLLBACK_FILE=''
ROLLBACK_RESTORE_FAILED=0
PATH_PROFILE_TMP=''
PATH_SNAPSHOT_FILE=''
PATH_SNAPSHOT_PROFILE=''
PATH_SNAPSHOT_EXISTS=0
BINARY_SWAP_COMMITTED=0
STATE_COMMIT_DONE=0
HAD_OLD_BINARY=0
HASH_TOOL=''
INSTALL_DIR=''
BINARY_PATH=''
STATE_PATH=''
ASSET_SUFFIX=''
ASSET_NAME=''
RESOLVED_VERSION=''
RESOLVED_TAG=''
DOWNLOADED_HASH=''

CURRENT_VERSION=''
CURRENT_ASSET=''
CURRENT_HASH=''
CURRENT_OBSERVED_HASH=''
CURRENT_PATH_SHELL='none'
CURRENT_PATH_FILE=''
CURRENT_PATH_HASH=''
INSTALLATION_EXISTS=0
MANAGED_INSTALL=0

usage() {
    cat >&2 <<'EOF'
Usage: install.sh [OPTIONS]

Options:
  --version vX.Y.Z       Install exact stable release
  --install-dir DIR     Install into dedicated directory DIR
  --force               Replace a changed managed same-version binary
  --allow-downgrade     Permit installing an older managed version
  --modify-path         Add the dedicated directory to a known shell profile
  --remove-path         Remove only this installer's unchanged PATH block
  --uninstall           Remove only this installer's managed installation
  --dry-run             Show actions without network, writes, or execution
  -h, --help            Show this help
EOF
    exit 2
}

fail() {
    printf 'gitler installer: %s\n' "$1" >&2
    exit 1
}

cleanup() {
    status=$?
    trap - 0 HUP INT TERM
    if [ -n "$STATE_TMP_FILE" ] && [ -e "$STATE_TMP_FILE" ]; then
        rm -f "$STATE_TMP_FILE"
    fi
    if [ -n "$STAGE_FILE" ] && [ -e "$STAGE_FILE" ]; then
        rm -f "$STAGE_FILE"
    fi
    if [ "$BINARY_SWAP_COMMITTED" -eq 1 ] && [ "$STATE_COMMIT_DONE" -eq 0 ]; then
        if [ "$HAD_OLD_BINARY" -eq 1 ] && [ -n "$ROLLBACK_FILE" ] && [ -e "$ROLLBACK_FILE" ]; then
            if mv -f "$ROLLBACK_FILE" "$BINARY_PATH"; then
                ROLLBACK_FILE=''
            else
                ROLLBACK_RESTORE_FAILED=1
                printf 'gitler installer: interrupted update could not restore %s; rollback copy was retained at %s\n' "$BINARY_PATH" "$ROLLBACK_FILE" >&2
            fi
        elif [ "$HAD_OLD_BINARY" -eq 0 ] && [ -f "$BINARY_PATH" ] && [ ! -L "$BINARY_PATH" ]; then
            rm -f "$BINARY_PATH" ||
                printf 'gitler installer: interrupted first install could not remove %s\n' "$BINARY_PATH" >&2
        fi
    fi
    if [ "$ROLLBACK_RESTORE_FAILED" -eq 0 ] && [ -n "$ROLLBACK_FILE" ] && [ -e "$ROLLBACK_FILE" ]; then
        rm -f "$ROLLBACK_FILE" ||
            printf 'gitler installer: could not remove temporary rollback copy %s\n' "$ROLLBACK_FILE" >&2
    fi
    if [ -n "$PATH_SNAPSHOT_FILE" ] && [ -n "$PATH_SNAPSHOT_PROFILE" ]; then
        if [ "$PATH_SNAPSHOT_EXISTS" -eq 1 ]; then
            cp -p "$PATH_SNAPSHOT_FILE" "$PATH_SNAPSHOT_PROFILE" ||
                printf 'gitler installer: interrupted PATH update could not restore %s\n' "$PATH_SNAPSHOT_PROFILE" >&2
        else
            rm -f "$PATH_SNAPSHOT_PROFILE" ||
                printf 'gitler installer: interrupted PATH update could not remove %s\n' "$PATH_SNAPSHOT_PROFILE" >&2
        fi
    fi
    if [ -n "$PATH_PROFILE_TMP" ] && [ -e "$PATH_PROFILE_TMP" ]; then
        rm -f "$PATH_PROFILE_TMP"
    fi
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
    exit "$status"
}

trap cleanup 0
trap 'exit 130' HUP INT TERM

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_tools() {
    for tool in curl mktemp chmod mv mkdir cp rm rmdir dirname basename pwd uname awk sed grep head wc sort cmp cat find tail od tr; do
        command_exists "$tool" || fail "required tool '$tool' is missing; install it with your system package manager"
    done
    if command_exists shasum; then
        HASH_TOOL='shasum'
    elif command_exists sha256sum; then
        HASH_TOOL='sha256sum'
    else
        fail "required SHA-256 tool is missing; install 'shasum' (macOS) or 'sha256sum' (Linux)"
    fi
}

hash_file() {
    if [ "$HASH_TOOL" = 'shasum' ]; then
        shasum -a 256 "$1" | awk '{ print $1 }'
    else
        sha256sum "$1" | awk '{ print $1 }'
    fi
}

validate_version() {
    version=$1
    printf '%s\n' "$version" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' ||
        fail "version '$version' is not stable vMAJOR.MINOR.PATCH grammar"
}

compare_versions() {
    # Compare decimal components as strings so arbitrarily large valid versions
    # do not overflow shell arithmetic.
    LC_ALL=C awk -F. -v left="$1" -v right="$2" '
        function normalized(value) {
            sub(/^0+/, "", value)
            return value == "" ? "0" : value
        }
        BEGIN {
            split(left, a, ".")
            split(right, b, ".")
            for (i = 1; i <= 3; i++) {
                x = normalized(a[i])
                y = normalized(b[i])
                if (length(x) < length(y)) { print -1; exit }
                if (length(x) > length(y)) { print 1; exit }
                if (("x" x) < ("x" y)) { print -1; exit }
                if (("x" x) > ("x" y)) { print 1; exit }
            }
            print 0
        }
    '
}

shell_quote() {
    escaped=$(printf '%s' "$1" | sed "s/'/'\\\\''/g")
    printf "'%s'" "$escaped"
}

assert_no_symlink_components() {
    path=$1
    while :; do
        if [ -L "$path" ]; then
            fail "refusing symlinked path component '$path'"
        fi
        [ "$path" = '/' ] && break
        case "$path" in
            */*)
                parent=${path%/*}
                [ -n "$parent" ] || parent=/
                ;;
            *) break ;;
        esac
        [ "$parent" = "$path" ] && break
        path=$parent
    done
}

resolve_install_dir() {
    if [ -n "$INSTALL_DIR_ARG" ]; then
        case "$INSTALL_DIR_ARG" in
            *[![:print:]]*) fail '--install-dir cannot contain control characters' ;;
        esac
        case "$INSTALL_DIR_ARG" in
            /*) INSTALL_DIR=$INSTALL_DIR_ARG ;;
            *) INSTALL_DIR="$(pwd)/$INSTALL_DIR_ARG" ;;
        esac
    else
        [ -n "${HOME:-}" ] || fail 'HOME is not set; pass --install-dir explicitly'
        if [ -n "${XDG_DATA_HOME:-}" ]; then
            case "$XDG_DATA_HOME" in
                /*) : ;;
                *) fail 'XDG_DATA_HOME must be an absolute path' ;;
            esac
            INSTALL_DIR="$XDG_DATA_HOME/gitler/bin"
        else
            INSTALL_DIR="$HOME/.local/share/gitler/bin"
        fi
    fi
    [ -n "$INSTALL_DIR" ] || fail 'install directory cannot be empty'
    case "$INSTALL_DIR" in
        *[![:print:]]*) fail 'install directory cannot contain control characters' ;;
        */../*|*/..|*/./*|*/.) fail 'install directory cannot contain . or .. path components' ;;
    esac
    while [ "$INSTALL_DIR" != '/' ] && [ "${INSTALL_DIR%/}" != "$INSTALL_DIR" ]; do
        INSTALL_DIR=${INSTALL_DIR%/}
    done
    if [ "$MODIFY_PATH" -eq 1 ] || [ "$REMOVE_PATH" -eq 1 ]; then
        case "$INSTALL_DIR" in
            *:*) fail 'PATH management cannot use an install directory containing a colon' ;;
        esac
    fi
    assert_no_symlink_components "$INSTALL_DIR"
    BINARY_PATH="$INSTALL_DIR/$PROGRAM"
    STATE_PATH="$INSTALL_DIR/$INSTALL_STATE"
}

select_platform() {
    system=$(uname -s 2>/dev/null || true)
    machine=$(uname -m 2>/dev/null || true)
    case "$system" in
        Linux)
            case "$machine" in
                x86_64|amd64) ASSET_SUFFIX='linux-x86_64-gnu' ;;
                *) fail "unsupported Linux architecture '$machine'; only x86_64/amd64 is supported" ;;
            esac
            ;;
        Darwin)
            arm64_capable=0
            if command_exists sysctl; then
                arm64_capable=$(sysctl -in hw.optional.arm64 2>/dev/null || printf '0')
            fi
            if [ "$arm64_capable" = '1' ]; then
                ASSET_SUFFIX='macos-aarch64'
            else
                case "$machine" in
                    x86_64|amd64) ASSET_SUFFIX='macos-x86_64' ;;
                    arm64|aarch64) ASSET_SUFFIX='macos-aarch64' ;;
                    *) fail "unsupported macOS architecture '$machine'" ;;
                esac
            fi
            ;;
        *)
            fail "unsupported operating system '$system'; use install.ps1 on Windows"
            ;;
    esac
}

json_string_value() {
    key=$1
    file=$2
    tr ',{' '\n' < "$file" |
        sed -n "s/^[[:space:]]*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*$/\1/p" |
        head -n 1
}

json_boolean_value() {
    key=$1
    file=$2
    tr ',{' '\n' < "$file" |
        sed -n "s/^[[:space:]]*\"$key\"[[:space:]]*:[[:space:]]*\(true\|false\).*$/\1/p" |
        head -n 1
}

contains_asset_name() {
    name=$1
    file=$2
    tr ',{' '\n' < "$file" |
        sed -n 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*$/\1/p' |
        grep -Fqx "$name"
}

validate_release_metadata() {
    release_file=$1
    release_description=$2
    expected_tag=${3:-}

    RESOLVED_TAG=$(json_string_value tag_name "$release_file")
    [ -n "$RESOLVED_TAG" ] || fail "$release_description has no tag_name"
    [ -z "$expected_tag" ] || [ "$RESOLVED_TAG" = "$expected_tag" ] ||
        fail "$release_description resolved tag '$RESOLVED_TAG', not requested tag '$expected_tag'"
    case "$RESOLVED_TAG" in
        v*) RESOLVED_VERSION=${RESOLVED_TAG#v} ;;
        *) fail "$release_description tag '$RESOLVED_TAG' is not a stable vMAJOR.MINOR.PATCH tag" ;;
    esac
    validate_version "$RESOLVED_VERSION"
    [ "$(json_boolean_value draft "$release_file")" = 'false' ] ||
        fail "$release_description is draft or has malformed draft metadata"
    [ "$(json_boolean_value prerelease "$release_file")" = 'false' ] ||
        fail "$release_description is prerelease or has malformed prerelease metadata"

    ASSET_NAME="gitler-v${RESOLVED_VERSION}-${ASSET_SUFFIX}"
    for name in "$ASSET_NAME" install.sh install.ps1 SHA256SUMS; do
        contains_asset_name "$name" "$release_file" ||
            fail "$release_description is missing expected asset '$name'"
    done
}

resolve_latest_release() {
    latest_file=$TMP_DIR/latest.json
    status_file=$TMP_DIR/latest.status
    if ! curl -qsSL --proto '=https' --proto-redir '=https' \
        --connect-timeout 20 --max-time 60 --retry 2 --retry-delay 1 \
        -H 'Accept: application/vnd.github+json' \
        -o "$latest_file" -w '%{http_code}' "$LATEST_API" > "$status_file"; then
        fail "latest release lookup failed; check HTTPS access, proxy settings, and DNS; rerun with --version vX.Y.Z"
    fi
    status=$(cat "$status_file")
    case "$status" in
        200) ;;
        403|429) fail "GitHub API rate limit reached; rerun with --version vX.Y.Z" ;;
        *) fail "GitHub latest release API returned HTTP $status; rerun with an explicit version after fixing access" ;;
    esac

    validate_release_metadata "$latest_file" 'latest release'
}

resolve_exact_release() {
    requested_tag=$1
    release_file=$TMP_DIR/release.json
    status_file=$TMP_DIR/release.status
    release_api="$RELEASES_API/tags/$requested_tag"
    if ! curl -qsSL --proto '=https' --proto-redir '=https' \
        --connect-timeout 20 --max-time 60 --retry 2 --retry-delay 1 \
        -H 'Accept: application/vnd.github+json' \
        -o "$release_file" -w '%{http_code}' "$release_api" > "$status_file"; then
        fail "release lookup for '$requested_tag' failed; check HTTPS access, proxy settings, and DNS"
    fi
    status=$(cat "$status_file")
    case "$status" in
        200) ;;
        403|429) fail "GitHub API rate limit reached while resolving '$requested_tag'; retry later" ;;
        404) fail "GitHub Release '$requested_tag' does not exist or is not publicly available" ;;
        *) fail "GitHub Release API for '$requested_tag' returned HTTP $status" ;;
    esac

    validate_release_metadata "$release_file" "release '$requested_tag'" "$requested_tag"
}

download_https() {
    url=$1
    destination=$2
    if ! curl -qfsSL --proto '=https' --proto-redir '=https' \
        --connect-timeout 20 --max-time 600 --retry 2 --retry-delay 1 \
        -o "$destination" "$url"; then
        fail "download failed: $url; check HTTPS access, proxy settings, and disk space"
    fi
}

validate_manifest() {
    manifest=$1
    version=$2
    [ -f "$manifest" ] || fail 'downloaded SHA256SUMS is not a regular file'
    last_byte=$(tail -c 1 "$manifest" | od -An -t x1 | tr -d '[:space:]')
    [ "$last_byte" = '0a' ] || fail 'SHA256SUMS must be LF-delimited and end with a newline'
    if ! LC_ALL=C awk '
        BEGIN { ok = 1; count = 0 }
        {
            count++
            if (NF != 2 || length($1) != 64 || $1 ~ /[^0-9a-f]/ || $0 != $1 "  " $2 || $2 ~ /[[:space:]]/) {
                ok = 0
            }
            if (seen[$2]++) { ok = 0 }
        }
        END { exit !(ok && count == 6) }
    ' "$manifest"; then
        fail 'SHA256SUMS has invalid format, line count, or duplicate names'
    fi

    expected_file=$TMP_DIR/expected-names
    actual_file=$TMP_DIR/actual-names
    {
        printf '%s\n' "gitler-v${version}-windows-x86_64.exe"
        printf '%s\n' "gitler-v${version}-macos-x86_64"
        printf '%s\n' "gitler-v${version}-macos-aarch64"
        printf '%s\n' "gitler-v${version}-linux-x86_64-gnu"
        printf '%s\n' install.ps1
        printf '%s\n' install.sh
    } | LC_ALL=C sort > "$expected_file"
    awk '{ print $2 }' "$manifest" | LC_ALL=C sort > "$actual_file"
    cmp -s "$expected_file" "$actual_file" || fail 'SHA256SUMS does not contain exactly the expected release subjects'

    selected_hash=$(awk -v target="$ASSET_NAME" '$2 == target { count++; value = $1 } END { if (count != 1) exit 1; print value }' "$manifest") ||
        fail "SHA256SUMS does not contain exactly one entry for $ASSET_NAME"
    DOWNLOADED_HASH=$selected_hash
}

validate_state() {
    if [ ! -f "$STATE_PATH" ] || [ -L "$STATE_PATH" ]; then
        fail 'installer state file is missing or is not a regular file'
    fi
    if ! awk -F= '
        BEGIN {
            required["format_version"] = 1
            required["installed_version"] = 1
            required["asset_filename"] = 1
            required["binary_sha256"] = 1
            required["path_shell"] = 1
            required["path_file"] = 1
            required["path_block_sha256"] = 1
            ok = 1
        }
        {
            if (!required[$1] || seen[$1]++ || index($0, "=") == 0) { ok = 0 }
        }
        END {
            for (key in required) if (!seen[key]) ok = 0
            exit !ok
        }
    ' "$STATE_PATH"; then
        fail 'installer state file is malformed or contains unknown/duplicate fields'
    fi

    state_value() {
        key=$1
        awk -F= -v wanted="$key" '$1 == wanted { line = $0; sub(/^[^=]*=/, "", line); value = line; count++ } END { if (count != 1) exit 1; print value }' "$STATE_PATH"
    }

    format=$(state_value format_version) || fail 'installer state format is unreadable'
    [ "$format" = "$FORMAT_VERSION" ] || fail "unsupported installer state format '$format'"
    CURRENT_VERSION=$(state_value installed_version) || fail 'installed version is unreadable'
    validate_version "$CURRENT_VERSION"
    CURRENT_ASSET=$(state_value asset_filename) || fail 'installed asset name is unreadable'
    [ "$CURRENT_ASSET" = "gitler-v${CURRENT_VERSION}-${ASSET_SUFFIX}" ] ||
        fail 'installed asset name does not match the selected native platform'
    CURRENT_HASH=$(state_value binary_sha256) || fail 'installed binary hash is unreadable'
    printf '%s\n' "$CURRENT_HASH" | grep -Eq '^[0-9a-f]{64}$' || fail 'installed binary hash is malformed'
    CURRENT_PATH_SHELL=$(state_value path_shell) || fail 'PATH ownership state is unreadable'
    CURRENT_PATH_FILE=$(state_value path_file) || fail 'PATH profile state is unreadable'
    CURRENT_PATH_HASH=$(state_value path_block_sha256) || fail 'PATH block hash state is unreadable'
    case "$CURRENT_PATH_SHELL" in
        none)
            if [ -n "$CURRENT_PATH_FILE" ] || [ -n "$CURRENT_PATH_HASH" ]; then
                fail 'empty PATH ownership has non-empty metadata'
            fi
            ;;
        bash|zsh|fish)
            [ -n "$CURRENT_PATH_FILE" ] || fail 'PATH ownership has no profile path'
            case "$CURRENT_PATH_FILE" in
                /*) ;;
                *) fail 'PATH ownership profile path must be absolute' ;;
            esac
            printf '%s\n' "$CURRENT_PATH_HASH" | grep -Eq '^[0-9a-f]{64}$' || fail 'PATH block hash is malformed'
            ;;
        *) fail 'PATH ownership shell is unsupported' ;;
    esac
}

inspect_installation() {
    INSTALLATION_EXISTS=0
    MANAGED_INSTALL=0
    if [ -L "$INSTALL_DIR" ]; then
        fail 'install directory is a symlink; choose a real dedicated directory'
    fi
    if [ -e "$INSTALL_DIR" ]; then
        INSTALLATION_EXISTS=1
        [ -d "$INSTALL_DIR" ] || fail 'install directory path is not a directory'
        validate_state
        MANAGED_INSTALL=1
        if [ -L "$BINARY_PATH" ] || [ ! -f "$BINARY_PATH" ]; then
            fail 'managed install is missing its regular gitler executable'
        fi
        [ -L "$STATE_PATH" ] || [ -f "$STATE_PATH" ] || fail 'managed install state disappeared'
        CURRENT_OBSERVED_HASH=$(hash_file "$BINARY_PATH")
        if [ "$CURRENT_OBSERVED_HASH" != "$CURRENT_HASH" ] && [ "$FORCE" -eq 0 ]; then
            fail 'managed executable hash differs from installer state; use --force only after reviewing the file'
        fi
    fi
}

path_profile_for_shell() {
    case "$1" in
        bash) printf '%s\n' "$HOME/.bashrc" ;;
        zsh) printf '%s\n' "$HOME/.zshrc" ;;
        fish) printf '%s\n' "$HOME/.config/fish/conf.d/gitler.fish" ;;
        *) return 1 ;;
    esac
}

write_path_block() {
    shell=$1
    directory=$2
    output=$3
    quoted=$(shell_quote "$directory")
    {
        printf '%s\n' '# >>> gitler installer PATH (do not edit) >>>'
        case "$shell" in
            bash|zsh)
                printf '%s\n' "case \":\$PATH:\" in"
                printf '  *:%s:*) ;;\n' "$quoted"
                printf "  *) PATH=%s:\"\$PATH\"; export PATH ;;\n" "$quoted"
                printf '%s\n' 'esac'
                ;;
            fish)
                printf 'fish_add_path --path --move %s\n' "$quoted"
                ;;
        esac
        printf '%s\n' '# <<< gitler installer PATH <<<'
    } > "$output"
}

append_path_block() {
    shell=$1
    profile=$(path_profile_for_shell "$shell") || fail 'unknown shell; PATH profile editing supports Bash, Zsh, and Fish only'
    case "$profile" in
        *[![:print:]]*) fail 'shell profile path contains control characters' ;;
    esac
    assert_no_symlink_components "$profile"
    if [ -L "$profile" ]; then
        fail "refusing to edit symlinked shell profile '$profile'"
    fi
    if [ -e "$profile" ] && [ ! -f "$profile" ]; then
        fail "shell profile '$profile' is not a regular file"
    fi
    if [ "$shell" = fish ]; then
        mkdir -p "$HOME/.config/fish/conf.d"
    fi

    block=$TMP_DIR/path-block
    write_path_block "$shell" "$INSTALL_DIR" "$block"
    if [ -f "$profile" ] && grep -Fq '# >>> gitler installer PATH (do not edit) >>>' "$profile"; then
        fail "PATH block already exists in '$profile'; refusing to create a duplicate"
    fi
    profile_tmp="$profile.gitler.tmp.$$"
    if [ -e "$profile_tmp" ] || [ -L "$profile_tmp" ]; then
        fail "temporary shell profile path already exists '$profile_tmp'"
    fi
    PATH_PROFILE_TMP=$profile_tmp
    if [ -f "$profile" ]; then
        cp -p "$profile" "$profile_tmp" || fail "could not stage shell profile '$profile'"
    else
        : > "$profile_tmp" || fail "could not create shell profile '$profile'"
    fi
    cat "$block" >> "$profile_tmp" || fail "could not append PATH block for '$profile'"
    mv "$profile_tmp" "$profile" || fail "could not atomically update shell profile '$profile'"
    PATH_PROFILE_TMP=''

    CURRENT_PATH_SHELL=$shell
    CURRENT_PATH_FILE=$profile
    CURRENT_PATH_HASH=$(hash_file "$block")
}

remove_path_block() {
    [ "$CURRENT_PATH_SHELL" != none ] || return 0
    profile=$CURRENT_PATH_FILE
    expected_profile=$(path_profile_for_shell "$CURRENT_PATH_SHELL") || fail 'PATH ownership shell is unsupported'
    [ "$profile" = "$expected_profile" ] || fail 'PATH ownership points outside the supported user profile location'
    case "$profile" in
        *[![:print:]]*) fail 'shell profile path contains control characters' ;;
    esac
    assert_no_symlink_components "$profile"
    if [ ! -f "$profile" ] || [ -L "$profile" ]; then
        fail "owned PATH profile '$profile' is missing or is not a regular file"
    fi

    block=$TMP_DIR/path-block
    write_path_block "$CURRENT_PATH_SHELL" "$INSTALL_DIR" "$block"
    block_hash=$(hash_file "$block")
    [ "$block_hash" = "$CURRENT_PATH_HASH" ] || fail 'generated PATH block no longer matches installer state'

    found_block=$TMP_DIR/found-path-block
    filtered="$profile.gitler.filtered.$$"
    if [ -e "$filtered" ] || [ -L "$filtered" ]; then
        fail "temporary shell profile path already exists '$filtered'"
    fi
    : > "$found_block"
    PATH_PROFILE_TMP=$filtered
    : > "$filtered"
    if ! awk \
        -v start='# >>> gitler installer PATH (do not edit) >>>' \
        -v end='# <<< gitler installer PATH <<<' \
        -v block_file="$found_block" \
        -v output_file="$filtered" '
        BEGIN { inside = 0; count = 0 }
        {
            if (!inside && $0 == start) {
                inside = 1
                count++
                print $0 > block_file
                next
            }
            if (inside) {
                print $0 > block_file
                if ($0 == end) inside = 0
                next
            }
            print $0 > output_file
        }
        END {
            close(block_file)
            close(output_file)
            if (inside || count != 1) exit 1
        }
    ' "$profile"; then
        fail 'PATH marker block is missing, duplicated, or unterminated'
    fi
    [ "$(hash_file "$found_block")" = "$CURRENT_PATH_HASH" ] ||
        fail 'PATH marker block was edited; refusing to remove user-edited content'
    mv "$filtered" "$profile" || fail "could not atomically update shell profile '$profile'"
    PATH_PROFILE_TMP=''
    CURRENT_PATH_SHELL=none
    CURRENT_PATH_FILE=''
    CURRENT_PATH_HASH=''
}

snapshot_path_profile() {
    profile=$1
    PATH_SNAPSHOT_FILE="$TMP_DIR/path-profile.snapshot"
    PATH_SNAPSHOT_PROFILE=$profile
    PATH_SNAPSHOT_EXISTS=0
    if [ -e "$profile" ] || [ -L "$profile" ]; then
        [ -f "$profile" ] && [ ! -L "$profile" ] || fail "shell profile '$profile' is not a regular file"
        cp -p "$profile" "$PATH_SNAPSHOT_FILE" || fail "could not snapshot shell profile '$profile'"
        PATH_SNAPSHOT_EXISTS=1
    fi
}

restore_path_profile_snapshot() {
    [ -n "$PATH_SNAPSHOT_FILE" ] || return 0
    if [ "$PATH_SNAPSHOT_EXISTS" -eq 1 ]; then
        cp -p "$PATH_SNAPSHOT_FILE" "$PATH_SNAPSHOT_PROFILE" ||
            fail "could not restore shell profile '$PATH_SNAPSHOT_PROFILE'"
    else
        rm -f "$PATH_SNAPSHOT_PROFILE" || fail "could not remove incomplete shell profile '$PATH_SNAPSHOT_PROFILE'"
    fi
    PATH_SNAPSHOT_FILE=''
    PATH_SNAPSHOT_PROFILE=''
}

write_state_contents() {
    state_tmp=$1
    if ! {
        printf 'format_version=%s\n' "$FORMAT_VERSION"
        printf 'installed_version=%s\n' "$2"
        printf 'asset_filename=%s\n' "$3"
        printf 'binary_sha256=%s\n' "$4"
        printf 'path_shell=%s\n' "$5"
        printf 'path_file=%s\n' "$6"
        printf 'path_block_sha256=%s\n' "$7"
    } > "$state_tmp"; then
        return 1
    fi
    chmod 600 "$state_tmp"
}

write_state() {
    STATE_TMP_FILE="$INSTALL_DIR/.gitler-state.tmp.$$"
    if [ -e "$STATE_TMP_FILE" ] || [ -L "$STATE_TMP_FILE" ]; then
        STATE_TMP_FILE=''
        return 1
    fi
    if ! write_state_contents "$STATE_TMP_FILE" "$@"; then
        rm -f "$STATE_TMP_FILE"
        STATE_TMP_FILE=''
        return 1
    fi
    if ! mv -f "$STATE_TMP_FILE" "$STATE_PATH"; then
        rm -f "$STATE_TMP_FILE"
        STATE_TMP_FILE=''
        return 1
    fi
    STATE_TMP_FILE=''
    return 0
}

prepare_state() {
    STATE_TMP_FILE="$INSTALL_DIR/.gitler-state.tmp.$$"
    if [ -e "$STATE_TMP_FILE" ] || [ -L "$STATE_TMP_FILE" ]; then
        STATE_TMP_FILE=''
        fail 'another installation appears to be updating state'
    fi
    if ! write_state_contents "$STATE_TMP_FILE" "$@"; then
        rm -f "$STATE_TMP_FILE"
        STATE_TMP_FILE=''
        fail 'installer state staging failed'
    fi
}

commit_prepared_state() {
    if ! mv -f "$STATE_TMP_FILE" "$STATE_PATH"; then
        return 1
    fi
    STATE_TMP_FILE=''
    return 0
}

print_path_instructions() {
    quoted=$(shell_quote "$INSTALL_DIR")
    printf 'Installed %s %s at %s\n' "$PROGRAM" "$RESOLVED_VERSION" "$BINARY_PATH"
    if [ "$MODIFY_PATH" -eq 1 ]; then
        printf 'PATH block added to %s. Open a new terminal or source that profile.\n' "$CURRENT_PATH_FILE"
        return
    fi
    printf "Current terminal: export PATH=%s:\"\$PATH\"\n" "$quoted"
    case "${SHELL:-}" in
        */bash) shell_name=bash ;;
        */zsh) shell_name=zsh ;;
        */fish) shell_name=fish ;;
        *) shell_name=unknown ;;
    esac
    case "$shell_name" in
        bash) printf "Persistent Bash command: export PATH=%s:\"\$PATH\"  # add to ~/.bashrc\n" "$quoted" ;;
        zsh) printf "Persistent Zsh command: export PATH=%s:\"\$PATH\"  # add to ~/.zshrc\n" "$quoted" ;;
        fish) printf 'Persistent Fish command: fish_add_path --path --move %s\n' "$quoted" ;;
        *) printf 'Persistent PATH: add %s to your shell profile manually; unknown shell is not edited.\n' "$quoted" ;;
    esac
    printf 'Open a new terminal or source the relevant profile before using %s by name.\n' "$PROGRAM"
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --version)
                [ "$#" -ge 2 ] || fail '--version requires vX.Y.Z'
                REQUESTED_VERSION=$2
                shift 2
                ;;
            --install-dir)
                [ "$#" -ge 2 ] || fail '--install-dir requires a directory'
                INSTALL_DIR_ARG=$2
                shift 2
                ;;
            --force) FORCE=1; shift ;;
            --allow-downgrade) ALLOW_DOWNGRADE=1; shift ;;
            --modify-path) MODIFY_PATH=1; shift ;;
            --remove-path) REMOVE_PATH=1; shift ;;
            --uninstall) UNINSTALL=1; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            -h|--help) usage ;;
            *) fail "unknown option '$1'" ;;
        esac
    done
    [ "$MODIFY_PATH" -eq 0 ] || [ "$REMOVE_PATH" -eq 0 ] || fail '--modify-path and --remove-path cannot be combined'
    [ "$UNINSTALL" -eq 0 ] || [ "$FORCE" -eq 0 ] || fail '--force cannot be combined with --uninstall'
    [ "$UNINSTALL" -eq 0 ] || [ "$ALLOW_DOWNGRADE" -eq 0 ] || fail '--allow-downgrade cannot be combined with --uninstall'
    [ "$UNINSTALL" -eq 0 ] || [ -z "$REQUESTED_VERSION" ] || fail '--version cannot be combined with --uninstall'
    [ "$UNINSTALL" -eq 0 ] || [ "$MODIFY_PATH" -eq 0 ] || fail '--modify-path cannot be combined with --uninstall'
    [ "$UNINSTALL" -eq 0 ] || [ "$REMOVE_PATH" -eq 0 ] || :
    [ "$REMOVE_PATH" -eq 0 ] || [ -z "$REQUESTED_VERSION" ] || fail '--remove-path cannot be combined with --version'
}

parse_args "$@"
resolve_install_dir

if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$UNINSTALL" -eq 1 ]; then
        printf 'Dry run: uninstall managed gitler from %s; no files or PATH entries change.\n' "$INSTALL_DIR"
    elif [ "$REMOVE_PATH" -eq 1 ]; then
        printf 'Dry run: remove only this installer PATH block for %s; no files or profiles change.\n' "$INSTALL_DIR"
    else
        if [ -n "$REQUESTED_VERSION" ]; then
            case "$REQUESTED_VERSION" in
                v*) dry_version=${REQUESTED_VERSION#v} ;;
                *) fail "version '$REQUESTED_VERSION' must start with v" ;;
            esac
            validate_version "$dry_version"
            printf 'Dry run: install gitler %s for the detected native platform into %s; no network, writes, or execution.\n' "$dry_version" "$INSTALL_DIR"
        else
            printf 'Dry run: resolve one latest stable release, then install the detected native platform into %s; no network, writes, or execution.\n' "$INSTALL_DIR"
        fi
    fi
    exit 0
fi

require_tools
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gitler-install.XXXXXX") || fail 'cannot create a private temporary directory'
select_platform
inspect_installation

if [ "$UNINSTALL" -eq 1 ]; then
    [ "$MANAGED_INSTALL" -eq 1 ] || fail 'uninstall refuses an unrecognized or absent installation directory'
    if [ "$CURRENT_PATH_SHELL" != none ] && [ "$REMOVE_PATH" -eq 0 ]; then
        fail 'installer added PATH; rerun uninstall with --remove-path to remove the unchanged block'
    fi
    if [ "$REMOVE_PATH" -eq 1 ]; then
        remove_path_block
    fi
    rm "$BINARY_PATH"
    rm "$STATE_PATH"
    rmdir "$INSTALL_DIR" 2>/dev/null || true
    case "$INSTALL_DIR" in
        */gitler/bin)
            rmdir "${INSTALL_DIR%/bin}" 2>/dev/null || true
            ;;
    esac
    printf 'Uninstalled managed gitler from %s\n' "$INSTALL_DIR"
    exit 0
fi

if [ "$REMOVE_PATH" -eq 1 ] && [ "$MANAGED_INSTALL" -eq 0 ]; then
    fail '--remove-path requires an existing installer-managed installation'
fi
if [ "$REMOVE_PATH" -eq 1 ] && [ "$MANAGED_INSTALL" -eq 1 ]; then
    old_path_shell=$CURRENT_PATH_SHELL
    old_path_file=$CURRENT_PATH_FILE
    old_path_hash=$CURRENT_PATH_HASH
    snapshot_path_profile "$CURRENT_PATH_FILE"
    remove_path_block
    if ! write_state "$CURRENT_VERSION" "$CURRENT_ASSET" "$CURRENT_HASH" "$CURRENT_PATH_SHELL" "$CURRENT_PATH_FILE" "$CURRENT_PATH_HASH"; then
        CURRENT_PATH_SHELL=$old_path_shell
        CURRENT_PATH_FILE=$old_path_file
        CURRENT_PATH_HASH=$old_path_hash
        restore_path_profile_snapshot
        fail 'installer state update failed; PATH block was restored'
    fi
    PATH_SNAPSHOT_FILE=''
    PATH_SNAPSHOT_PROFILE=''
    printf 'Removed unchanged installer PATH block.\n'
    exit 0
fi

if [ -n "$REQUESTED_VERSION" ]; then
    case "$REQUESTED_VERSION" in
        v*) RESOLVED_VERSION=${REQUESTED_VERSION#v} ;;
        *) fail "version '$REQUESTED_VERSION' must start with v" ;;
    esac
    validate_version "$RESOLVED_VERSION"
    resolve_exact_release "$REQUESTED_VERSION"
else
    resolve_latest_release
fi

manifest_url="https://github.com/$REPOSITORY/releases/download/$RESOLVED_TAG/SHA256SUMS"
binary_url="https://github.com/$REPOSITORY/releases/download/$RESOLVED_TAG/$ASSET_NAME"
manifest_file=$TMP_DIR/SHA256SUMS
binary_file=$TMP_DIR/$ASSET_NAME
download_https "$manifest_url" "$manifest_file"
download_https "$binary_url" "$binary_file"
validate_manifest "$manifest_file" "$RESOLVED_VERSION"
actual_hash=$(hash_file "$binary_file")
[ "$actual_hash" = "$DOWNLOADED_HASH" ] || fail "checksum mismatch for downloaded $ASSET_NAME"
chmod 755 "$binary_file"

version_output=$("$binary_file" --version 2>&1) || fail 'downloaded executable failed --version; no existing installation was changed'
[ "$version_output" = "$PROGRAM $RESOLVED_VERSION" ] ||
    fail "downloaded executable reported '$version_output', expected '$PROGRAM $RESOLVED_VERSION'"
"$binary_file" --help >/dev/null 2>&1 || fail 'downloaded executable failed --help; no existing installation was changed'

if [ "$MANAGED_INSTALL" -eq 1 ]; then
    comparison=$(compare_versions "$RESOLVED_VERSION" "$CURRENT_VERSION")
    [ "$comparison" -ge 0 ] || [ "$ALLOW_DOWNGRADE" -eq 1 ] ||
        fail "installed version $CURRENT_VERSION is newer; use --allow-downgrade explicitly"
    if [ "$comparison" -eq 0 ] && [ "$CURRENT_HASH" != "$actual_hash" ] && [ "$FORCE" -eq 0 ]; then
        fail 'same-version managed binary differs from the release; use --force to replace it'
    fi
    if [ "$comparison" -eq 0 ] && [ "$CURRENT_HASH" = "$actual_hash" ] && [ "$FORCE" -eq 0 ]; then
        RESOLVED_VERSION="$CURRENT_VERSION"
        if [ "$MODIFY_PATH" -eq 1 ] && [ "$CURRENT_PATH_SHELL" = none ]; then
            case "${SHELL:-}" in
                */bash) shell_name=bash ;;
                */zsh) shell_name=zsh ;;
                */fish) shell_name=fish ;;
                *) shell_name=unknown ;;
            esac
            [ "$shell_name" != unknown ] || fail 'unknown shell; PATH profile editing supports Bash, Zsh, and Fish only'
            path_profile=$(path_profile_for_shell "$shell_name") || fail 'could not resolve shell profile for PATH management'
            snapshot_path_profile "$path_profile"
            append_path_block "$shell_name"
            if ! write_state "$CURRENT_VERSION" "$CURRENT_ASSET" "$CURRENT_HASH" "$CURRENT_PATH_SHELL" "$CURRENT_PATH_FILE" "$CURRENT_PATH_HASH"; then
                CURRENT_PATH_SHELL='none'
                CURRENT_PATH_FILE=''
                CURRENT_PATH_HASH=''
                restore_path_profile_snapshot
                fail 'installer state update failed; PATH block was restored'
            fi
            PATH_SNAPSHOT_FILE=''
            PATH_SNAPSHOT_PROFILE=''
        fi
        print_path_instructions
        printf 'Existing managed binary already matches this release; no replacement needed.\n'
        exit 0
    fi
else
    [ "$FORCE" -eq 0 ] || fail '--force is only valid for an existing installer-managed directory'
fi

if [ "$INSTALLATION_EXISTS" -eq 0 ]; then
    mkdir -p "$INSTALL_DIR"
fi
if [ -L "$INSTALL_DIR" ] || [ ! -d "$INSTALL_DIR" ]; then
    fail 'install directory is not a real directory'
fi
if [ -e "$BINARY_PATH" ] && { [ -L "$BINARY_PATH" ] || [ ! -f "$BINARY_PATH" ]; }; then
    fail 'destination gitler is not a regular file'
fi

STAGE_FILE=$INSTALL_DIR/.gitler-stage.$$
ROLLBACK_FILE=$INSTALL_DIR/.gitler-rollback.$$
if [ -e "$STAGE_FILE" ] || [ -L "$STAGE_FILE" ] || [ -e "$ROLLBACK_FILE" ] || [ -L "$ROLLBACK_FILE" ]; then
    fail 'another installation appears to be in progress'
fi
cp "$binary_file" "$STAGE_FILE"
chmod 755 "$STAGE_FILE"
stage_version=$("$STAGE_FILE" --version 2>&1) || fail 'staged executable failed --version'
[ "$stage_version" = "$PROGRAM $RESOLVED_VERSION" ] || fail 'staged executable version mismatch'
"$STAGE_FILE" --help >/dev/null 2>&1 || fail 'staged executable failed --help'

had_old=0
if [ -f "$BINARY_PATH" ] && [ ! -L "$BINARY_PATH" ]; then
    cp -p "$BINARY_PATH" "$ROLLBACK_FILE"
    had_old=1
fi
HAD_OLD_BINARY=$had_old

old_path_shell=$CURRENT_PATH_SHELL
old_path_file=$CURRENT_PATH_FILE
old_path_hash=$CURRENT_PATH_HASH
prepare_state "$RESOLVED_VERSION" "$ASSET_NAME" "$actual_hash" "$old_path_shell" "$old_path_file" "$old_path_hash"
if ! mv -f "$STAGE_FILE" "$BINARY_PATH"; then
    if [ "$had_old" -eq 1 ]; then
        mv -f "$ROLLBACK_FILE" "$BINARY_PATH" || true
    fi
    fail 'atomic executable replacement failed; existing executable was preserved'
fi
BINARY_SWAP_COMMITTED=1
if ! commit_prepared_state; then
    if [ "$had_old" -eq 1 ]; then
        mv -f "$ROLLBACK_FILE" "$BINARY_PATH" || true
    else
        rm -f "$BINARY_PATH"
    fi
    BINARY_SWAP_COMMITTED=0
    fail 'installer state update failed; existing executable was preserved'
fi
STATE_COMMIT_DONE=1
if [ "$had_old" -eq 1 ]; then
    rm -f "$ROLLBACK_FILE"
fi
ROLLBACK_FILE=''

CURRENT_VERSION=$RESOLVED_VERSION
CURRENT_ASSET=$ASSET_NAME
CURRENT_HASH=$actual_hash
if [ "$MODIFY_PATH" -eq 1 ] && [ "$CURRENT_PATH_SHELL" = none ]; then
    case "${SHELL:-}" in
        */bash) shell_name=bash ;;
        */zsh) shell_name=zsh ;;
        */fish) shell_name=fish ;;
        *) shell_name=unknown ;;
    esac
    [ "$shell_name" != unknown ] || fail 'unknown shell; PATH profile editing supports Bash, Zsh, and Fish only'
    path_profile=$(path_profile_for_shell "$shell_name") || fail 'could not resolve shell profile for PATH management'
    snapshot_path_profile "$path_profile"
    append_path_block "$shell_name"
    if ! write_state "$CURRENT_VERSION" "$CURRENT_ASSET" "$CURRENT_HASH" "$CURRENT_PATH_SHELL" "$CURRENT_PATH_FILE" "$CURRENT_PATH_HASH"; then
        restore_path_profile_snapshot
        fail 'installer state update failed; PATH block was restored'
    fi
    PATH_SNAPSHOT_FILE=''
    PATH_SNAPSHOT_PROFILE=''
fi

print_path_instructions
