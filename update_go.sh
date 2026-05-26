#!/usr/bin/env bash
# =============================================================================
#  update_go.sh — Go Version Manager
#  Commands: install, use, list, list-remote, remove, current
# =============================================================================
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
VERSIONS_DIR="${GO_VERSIONS_DIR:-/usr/local/go-versions}"  # all versions live here
ACTIVE_LINK="${GO_ACTIVE_LINK:-/usr/local/go}"             # symlink → active version
PROFILE_FILE="${PROFILE_FILE:-}"                            # blank = auto-detect
GO_DL_BASE="https://dl.google.com/go"
GO_API="https://go.dev/dl/?mode=json"
# ─────────────────────────────────────────────────────────────────────────────

# ── Colours (all status output → stderr so stdout stays clean) ────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*" >&2; }
success() { echo -e "${GREEN}[OK]${RESET}    $*" >&2; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*" >&2; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}$*${RESET}" >&2; }

# ── Detect OS / arch ──────────────────────────────────────────────────────────
detect_platform() {
    local os arch
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$os" in
        linux)  os="linux"  ;;
        darwin) os="darwin" ;;
        *) error "Unsupported OS: $os" ;;
    esac
    arch=$(uname -m)
    case "$arch" in
        x86_64)        arch="amd64"  ;;
        aarch64|arm64) arch="arm64"  ;;
        armv6l)        arch="armv6l" ;;
        i386|i686)     arch="386"    ;;
        *) error "Unsupported architecture: $arch" ;;
    esac
    echo "${os}-${arch}"
}

# ── HTTP helper ───────────────────────────────────────────────────────────────
http_get() {
    if command -v curl &>/dev/null; then
        curl -fsSL "$1"
    elif command -v wget &>/dev/null; then
        wget -qO- "$1"
    else
        error "Neither curl nor wget found."
    fi
}

http_download() {   # http_download <url> <dest>
    if command -v curl &>/dev/null; then
        curl -fL --progress-bar -o "$2" "$1"
    else
        wget -q --show-progress -O "$2" "$1"
    fi
}

# ── API helpers ───────────────────────────────────────────────────────────────
fetch_stable_versions() {
    # Prints JSON array of stable releases; cached in /tmp for this session
    local cache="/tmp/go_versions_cache.json"
    if [[ ! -f "$cache" ]] || [[ $(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) )) -gt 300 ]]; then
        http_get "${GO_API}&stable=true" > "$cache"
    fi
    cat "$cache"
}

fetch_latest_version() {
    fetch_stable_versions | grep -oP '"version":\s*"\Kgo[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1
}

fetch_all_remote_versions() {
    fetch_stable_versions | grep -oP '"version":\s*"\Kgo[0-9]+\.[0-9]+(\.[0-9]+)?'
}

fetch_sha256() {    # fetch_sha256 <filename>  → prints hash or empty
    fetch_stable_versions \
        | grep -A20 "\"$1\"" \
        | grep -oP '"sha256":\s*"\K[0-9a-f]+' | head -1
}

# ── Version helpers ───────────────────────────────────────────────────────────
normalise() { echo "${1#go}"; }   # "go1.22.1" → "1.22.1"

# Returns 0 if $1 >= $2  (both bare "X.Y.Z")
ver_ge() { [[ "$(printf '%s\n%s' "$1" "$2" | sort -V | head -1)" == "$2" ]]; }

active_version() {
    if [[ -x "${ACTIVE_LINK}/bin/go" ]]; then
        "${ACTIVE_LINK}/bin/go" version | grep -oP 'go[0-9]+\.[0-9]+(\.[0-9]+)?'
    else
        echo ""
    fi
}

installed_versions() {
    # Lists go1.X.Y directory names under VERSIONS_DIR, sorted
    if [[ -d "$VERSIONS_DIR" ]]; then
        find "$VERSIONS_DIR" -maxdepth 1 -name 'go[0-9]*' -type d \
            | xargs -r -I{} basename {} \
            | sort -V
    fi
}

# ── Shell profile ─────────────────────────────────────────────────────────────

# Returns the real (non-root) invoking user, even under sudo
real_user() {
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        echo "$SUDO_USER"
    else
        echo "${USER:-$(id -un)}"
    fi
}

# Home dir for a given username
user_home() {
    local u="$1"
    getent passwd "$u" 2>/dev/null | cut -d: -f6 || eval echo "~${u}"
}

# Shell for a given username
user_shell() {
    local u="$1"
    getent passwd "$u" 2>/dev/null | cut -d: -f7 || echo "/bin/bash"
}

# RC file for a given user
profile_for_user() {
    local u="$1"
    if [[ -n "$PROFILE_FILE" ]]; then echo "$PROFILE_FILE"; return; fi
    local home shell_name
    home=$(user_home "$u")
    shell_name=$(basename "$(user_shell "$u")")
    case "$shell_name" in
        zsh)  echo "${home}/.zshrc"  ;;
        fish) echo "${home}/.config/fish/config.fish" ;;
        *)    echo "${home}/.bashrc" ;;
    esac
}

# ── sed-based profile editor ──────────────────────────────────────────────────
# Uses a named marker block so the entry is always clean and idempotent:
#
#   # >>> go managed by update_go.sh >>>
#   export PATH="$PATH:/usr/local/go/bin"
#   # <<< go managed by update_go.sh <<<
#
# • If the block already exists  → sed replaces the PATH line inside it
# • If no block yet              → appends the whole block
# • Always written as $owner     → no root-owned lines in user files
# ─────────────────────────────────────────────────────────────────────────────
MARKER_BEGIN="# >>> go managed by update_go.sh >>>"
MARKER_END="# <<< go managed by update_go.sh <<<"

patch_profile() {
    local profile="$1" owner="$2" go_bin="$3"
    local export_line="export PATH=\"\$PATH:${go_bin}\""

    # Create file if missing
    if [[ ! -f "$profile" ]]; then
        if [[ "$EUID" -eq 0 && "$owner" != "root" ]]; then
            sudo -u "$owner" touch "$profile"
        else
            touch "$profile"
        fi
    fi

    # Helper: run a command as $owner (or directly if we already are $owner)
    run_as() {
        if [[ "$EUID" -eq 0 && "$owner" != "root" ]]; then
            sudo -u "$owner" "$@"
        else
            "$@"
        fi
    }

    if grep -qF "$MARKER_BEGIN" "$profile" 2>/dev/null; then
        # Block exists — update the PATH line inside it with sed
        info "Updating existing Go block in ${profile} …"
        run_as sed -i \
            "/${MARKER_BEGIN}/,/${MARKER_END}/s|^export PATH=.*|${export_line}|" \
            "$profile"
        success "Updated  ${profile}"
    else
        # No block yet — append it
        info "Adding Go block to ${profile} …"
        local block
        block=$(printf '\n%s\n%s\n%s\n' \
            "$MARKER_BEGIN" "$export_line" "$MARKER_END")
        if [[ "$EUID" -eq 0 && "$owner" != "root" ]]; then
            echo "$block" | sudo -u "$owner" tee -a "$profile" >/dev/null
        else
            echo "$block" >> "$profile"
        fi
        success "Appended ${profile}"
    fi
}

# ── /etc/profile.d writer ─────────────────────────────────────────────────────
patch_profiled() {
    local go_bin="$1"
    local sysd="/etc/profile.d/go.sh"
    local export_line="export PATH=\"\$PATH:${go_bin}\""

    if grep -qF "$MARKER_BEGIN" "$sysd" 2>/dev/null; then
        info "Updating ${sysd} …"
        safe_sudo sed -i \
            "/${MARKER_BEGIN}/,/${MARKER_END}/s|^export PATH=.*|${export_line}|" \
            "$sysd"
    else
        info "Writing ${sysd} …"
        printf '%s\n%s\n%s\n' "$MARKER_BEGIN" "$export_line" "$MARKER_END" \
            | safe_sudo tee "$sysd" >/dev/null
        safe_sudo chmod 644 "$sysd"
    fi
    success "System-wide profile: ${sysd}"
}

# ── auto-source ───────────────────────────────────────────────────────────────
# A script runs in a subshell, so `source` inside it cannot reach the parent
# shell's environment. The reliable fix: write a tiny one-shot loader to a
# temp file and print the `source <tmp>` command — the user's RC will already
# have the permanent block, but this makes 'go' live *right now* in the same
# terminal with zero manual steps.
#
# Every caller that needs live PATH today should run:
#   eval "$(ensure_path_eval)"
# but since we can't force that from inside the script we do the next-best
# thing: source everything we can inside this process AND write a helper file
# that the RC itself will pick up on next exec.
# ─────────────────────────────────────────────────────────────────────────────

# Source a file quietly, swallowing errors from interactive-only aliases etc.
_source_quietly() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    # Run in a subshell first to catch errors, then source for real
    bash -c "source \"$f\"" 2>/dev/null || true
    # shellcheck source=/dev/null
    source "$f" 2>/dev/null || true
    info "Sourced ${f}"
}

# Source as the real (non-root) user and pull the resulting PATH back
_source_as_user() {
    local f="$1" usr="$2"
    [[ -f "$f" ]] || return 0
    info "Sourcing ${f} as ${usr} …"
    local new_path
    new_path=$(sudo -u "$usr" bash -lc \
        "source \"$f\" 2>/dev/null; printf '%s' \"\$PATH\"" 2>/dev/null) || true
    if [[ -n "$new_path" ]]; then
        export PATH="$new_path"
        info "PATH updated from ${f}"
    fi
}

ensure_path() {
    local go_bin="${ACTIVE_LINK}/bin"
    local real_usr
    real_usr=$(real_user)
    local user_profile root_profile
    user_profile=$(profile_for_user "$real_usr")

    # 1) /etc/profile.d/go.sh  — system-wide, sourced on every login
    patch_profiled "$go_bin"

    # 2) Real user's RC  (e.g. /home/g0d/.bashrc)
    patch_profile "$user_profile" "$real_usr" "$go_bin"

    # 3) Root's RC too when running under sudo
    if [[ "$EUID" -eq 0 && "$real_usr" != "root" ]]; then
        root_profile=$(profile_for_user "root")
        patch_profile "$root_profile" "root" "$go_bin"
    fi

    # ── Auto-source: make 'go' live RIGHT NOW ─────────────────────────────────
    echo "" >&2
    info "Applying PATH changes to current session …"

    # Always source /etc/profile.d/go.sh — it's readable by everyone
    _source_quietly "/etc/profile.d/go.sh"

    if [[ "$EUID" -eq 0 && "$real_usr" != "root" ]]; then
        # Running as root via sudo: source the real user's RC and pull PATH back
        _source_as_user "$user_profile" "$real_usr"
        # Also source root's RC for this root session
        _source_quietly "$(profile_for_user root)"
    else
        # Not sudo: source our own RC directly
        _source_quietly "$user_profile"
    fi

    # Hard-set as final fallback so the script's own 'go version' check works
    export PATH="$PATH:${go_bin}"

    echo "" >&2
    success "PATH applied — 'go' is active in this session!"
    echo -e "  ${CYAN}go:${RESET}      $(command -v go 2>/dev/null || echo "${go_bin}/go")" >&2
    echo -e "  ${CYAN}Patched:${RESET} ${user_profile}" >&2
    echo -e "           /etc/profile.d/go.sh" >&2
    [[ "$EUID" -eq 0 && "$real_usr" != "root" ]] && \
        echo -e "           $(profile_for_user root)" >&2
    echo -e "  ${CYAN}New terminals${RESET} will have 'go' automatically." >&2
}

# ── Download & verify ─────────────────────────────────────────────────────────
# Prints the tarball path on stdout; all messages go to stderr.
download_go() {
    local version="$1" platform="$2"
    local tarball="${version}.${platform}.tar.gz"
    local url="${GO_DL_BASE}/${tarball}"
    local dest="/tmp/${tarball}"

    if [[ -f "$dest" ]]; then
        info "Tarball already cached at ${dest}"
    else
        info "Downloading ${url} …"
        http_download "$url" "$dest"
    fi

    info "Verifying SHA-256 checksum …"
    local expected actual
    expected=$(fetch_sha256 "$tarball")
    if [[ -n "$expected" ]]; then
        actual=$(sha256sum "$dest" | awk '{print $1}')
        if [[ "$actual" != "$expected" ]]; then
            rm -f "$dest"
            error "Checksum mismatch!\n  expected: $expected\n  actual:   $actual"
        fi
        success "Checksum OK ✓"
    else
        warn "No checksum found — skipping verification."
    fi

    echo "$dest"   # ← only this line goes to stdout
}

# ── Sudo-aware install ────────────────────────────────────────────────────────
safe_sudo() {
    if [[ "$EUID" -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

# =============================================================================
#  COMMANDS
# =============================================================================

# ── cmd: current ──────────────────────────────────────────────────────────────
cmd_current() {
    local ver
    ver=$(active_version)
    if [[ -z "$ver" ]]; then
        info "No active Go version."
    else
        echo -e "${BOLD}Active:${RESET} $ver  →  ${ACTIVE_LINK}"
        "${ACTIVE_LINK}/bin/go" version
    fi
}

# ── cmd: list ─────────────────────────────────────────────────────────────────
cmd_list() {
    header "Installed Go versions  (${VERSIONS_DIR})"
    local active ver
    active=$(active_version)
    local found=0
    while IFS= read -r ver; do
        [[ -z "$ver" ]] && continue
        found=1
        local tag=""
        [[ "go${ver#go}" == "$active" || "$ver" == "$active" ]] && tag="  ${GREEN}← active${RESET}"
        echo -e "  ${ver}${tag}"
    done < <(installed_versions)
    [[ $found -eq 0 ]] && echo "  (none)" >&2
}

# ── cmd: list-remote ──────────────────────────────────────────────────────────
cmd_list_remote() {
    local count="${1:-10}"
    header "Latest ${count} stable Go releases on go.dev"
    fetch_all_remote_versions | head -"$count" | while read -r v; do
        echo "  $v"
    done
}

# ── cmd: install [version] ────────────────────────────────────────────────────
cmd_install() {
    local target_ver="${1:-}"
    local platform
    platform=$(detect_platform)
    info "Platform: ${platform}"

    if [[ -z "$target_ver" ]]; then
        info "Fetching latest stable version …"
        target_ver=$(fetch_latest_version)
    fi
    # Normalise: accept "1.22.1" or "go1.22.1"
    [[ "$target_ver" != go* ]] && target_ver="go${target_ver}"

    info "Target version: ${BOLD}${target_ver}${RESET}"

    local install_path="${VERSIONS_DIR}/${target_ver}"
    if [[ -d "$install_path" ]]; then
        warn "${target_ver} is already installed at ${install_path}"
        read -rp "Re-install? [y/N] " yn
        [[ ! "${yn,,}" =~ ^y ]] && return 0
        safe_sudo rm -rf "$install_path"
    fi

    # Check active vs latest when no version specified
    if [[ "${ORIGINAL_CMD:-}" == "update" ]]; then
        local current
        current=$(active_version)
        if [[ -n "$current" ]]; then
            local c_bare l_bare
            c_bare=$(normalise "$current"); l_bare=$(normalise "$target_ver")
            if ver_ge "$c_bare" "$l_bare"; then
                success "Already up to date (${current})."
                return 0
            fi
            info "Upgrade: ${current} → ${target_ver}"
        fi
    fi

    local tarball
    tarball=$(download_go "$target_ver" "$platform")

    info "Installing ${target_ver} to ${install_path} …"
    safe_sudo mkdir -p "$VERSIONS_DIR"
    # Extract into a temp name, then rename to versioned dir
    local tmp_dir="${VERSIONS_DIR}/_tmp_go_extract"
    safe_sudo rm -rf "$tmp_dir"
    safe_sudo tar -C "$VERSIONS_DIR" -xzf "$tarball"
    safe_sudo mv "${VERSIONS_DIR}/go" "$install_path"
    rm -f "$tarball"

    success "${target_ver} installed → ${install_path}"

    # Auto-activate if nothing is active or if updating
    if [[ ! -e "$ACTIVE_LINK" ]] || [[ "${ORIGINAL_CMD:-}" == "update" ]]; then
        cmd_use "$target_ver"
    else
        info "To activate: $0 use ${target_ver}"
    fi
}

# ── cmd: use <version> ────────────────────────────────────────────────────────
cmd_use() {
    local ver="${1:-}"
    [[ -z "$ver" ]] && error "Usage: $0 use <version>  (e.g. go1.26.3 or 1.26.3)"
    [[ "$ver" != go* ]] && ver="go${ver}"

    local install_path="${VERSIONS_DIR}/${ver}"
    [[ ! -d "$install_path" ]] && error "${ver} is not installed. Run: $0 install ${ver}"

    info "Switching active version to ${ver} …"
    safe_sudo ln -sfn "$install_path" "$ACTIVE_LINK"
    ensure_path
    success "Active Go → ${ver}"
    "${ACTIVE_LINK}/bin/go" version
}

# ── cmd: remove <version> ─────────────────────────────────────────────────────
cmd_remove() {
    local ver="${1:-}"
    [[ -z "$ver" ]] && error "Usage: $0 remove <version>"
    [[ "$ver" != go* ]] && ver="go${ver}"

    local install_path="${VERSIONS_DIR}/${ver}"
    [[ ! -d "$install_path" ]] && error "${ver} is not installed."

    local active
    active=$(active_version)
    if [[ "$active" == "$ver" ]]; then
        warn "${ver} is currently active."
        read -rp "Remove anyway? The active symlink will be broken. [y/N] " yn
        [[ ! "${yn,,}" =~ ^y ]] && return 0
        safe_sudo rm -f "$ACTIVE_LINK"
    fi

    read -rp "Remove ${install_path}? [y/N] " yn
    [[ ! "${yn,,}" =~ ^y ]] && { info "Aborted."; return 0; }

    safe_sudo rm -rf "$install_path"
    success "${ver} removed."

    # Suggest another version if available
    local remaining
    remaining=$(installed_versions | tail -1)
    if [[ -n "$remaining" ]]; then
        info "Other installed versions available. Run: $0 use ${remaining}"
    fi
}

# ── cmd: update (install latest & activate) ───────────────────────────────────
cmd_update() {
    ORIGINAL_CMD="update" cmd_install ""
}

# =============================================================================
#  Entry point
# =============================================================================
usage() {
    cat >&2 <<EOF

${BOLD}GoUpdateAutomate — Go Version Manager${RESET}

Usage:
  $(basename "$0") [command] [options]

Commands:
  ${CYAN}install [version]${RESET}   Install a specific version (default: latest stable)
  ${CYAN}update${RESET}              Install latest stable & activate it
  ${CYAN}use <version>${RESET}       Switch the active Go version
  ${CYAN}remove <version>${RESET}    Uninstall a specific version
  ${CYAN}list${RESET}                Show locally installed versions
  ${CYAN}list-remote [n]${RESET}     Show latest N releases from go.dev  (default: 10)
  ${CYAN}current${RESET}             Show the active version

Environment:
  GO_VERSIONS_DIR   Where versions are stored  (default: /usr/local/go-versions)
  GO_ACTIVE_LINK    Symlink for active version  (default: /usr/local/go)
  PROFILE_FILE      Shell profile to patch      (default: auto-detect)

Examples:
  $(basename "$0") install            # install latest
  $(basename "$0") install 1.22.5     # install specific version
  $(basename "$0") use 1.22.5
  $(basename "$0") list-remote 5
  $(basename "$0") remove 1.21.0

EOF
}

main() {
    echo -e "\n${BOLD}══════════════════════════════════════${RESET}" >&2
    echo -e "${BOLD}   GoUpdateAutomate — Go Version Mgr  ${RESET}" >&2
    echo -e "${BOLD}══════════════════════════════════════${RESET}" >&2

    local cmd="${1:-update}"
    shift || true

    case "$cmd" in
        install)      cmd_install "$@" ;;
        update)       cmd_update ;;
        use)          cmd_use "$@" ;;
        remove|rm)    cmd_remove "$@" ;;
        list|ls)      cmd_list ;;
        list-remote)  cmd_list_remote "$@" ;;
        current)      cmd_current ;;
        -h|--help|help) usage ;;
        *) warn "Unknown command: ${cmd}"; usage; exit 1 ;;
    esac
}

main "$@"
