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

# Append PATH export to a profile file (owned by $owner) if not already present
patch_profile() {
    local profile="$1" owner="$2" go_bin="$3"
    grep -qF "$go_bin" "$profile" 2>/dev/null && return 0
    info "Patching ${profile} …"
    local line; line=$'\n'"# Go — added by update_go.sh"$'\n'"export PATH=\"\$PATH:${go_bin}\""
    # Write as the file owner to avoid root-owned lines in user files
    if [[ "$EUID" -eq 0 && "$owner" != "root" ]]; then
        echo "$line" | sudo -u "$owner" tee -a "$profile" >/dev/null
    else
        echo "$line" >> "$profile"
    fi
    success "Patched ${profile}"
}

ensure_path() {
    local go_bin="${ACTIVE_LINK}/bin"
    local real_usr
    real_usr=$(real_user)

    # 1) System-wide: /etc/profile.d/go.sh  (takes effect on next login for ALL users)
    local sysd="/etc/profile.d/go.sh"
    if ! grep -qF "$go_bin" "$sysd" 2>/dev/null; then
        info "Writing system-wide profile: ${sysd}"
        echo -e "# Go — added by update_go.sh\nexport PATH=\"\$PATH:${go_bin}\"" \
            | safe_sudo tee "$sysd" >/dev/null
        safe_sudo chmod 644 "$sysd"
        success "Written ${sysd}"
    fi

    # 2) Real invoking user's RC (e.g. /home/g0d/.bashrc)
    local user_profile
    user_profile=$(profile_for_user "$real_usr")
    patch_profile "$user_profile" "$real_usr" "$go_bin"

    # 3) Root's RC too, if we're actually running as root under sudo
    if [[ "$EUID" -eq 0 && "$real_usr" != "root" ]]; then
        local root_profile
        root_profile=$(profile_for_user "root")
        patch_profile "$root_profile" "root" "$go_bin"
    fi

    # Make go available in this session immediately
    export PATH="$PATH:${go_bin}"

    echo -e "\n${YELLOW}╔══════════════════════════════════════════════════════╗${RESET}" >&2
    echo -e "${YELLOW}║  Reload your shell to use 'go' in new terminals:     ║${RESET}" >&2
    echo -e "${YELLOW}║                                                       ║${RESET}" >&2
    echo -e "${YELLOW}║    source ${user_profile}$(printf '%*s' $((23 - ${#user_profile})) '')║${RESET}" >&2
    echo -e "${YELLOW}║                                                       ║${RESET}" >&2
    echo -e "${YELLOW}║  Or open a new terminal — it will load automatically. ║${RESET}" >&2
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════╝${RESET}" >&2
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
