#!/usr/bin/env bash
# =============================================================================
#  update_go.sh — Auto-download & install the latest Go version
# =============================================================================
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
GO_INSTALL_DIR="${GO_INSTALL_DIR:-/usr/local}"
PROFILE_FILE="${PROFILE_FILE:-}"          # leave blank = auto-detect
GO_DL_BASE="https://dl.google.com/go"
GO_API="https://go.dev/dl/?mode=json"
# ─────────────────────────────────────────────────────────────────────────────

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

# ── Detect OS / arch ──────────────────────────────────────────────────────────
detect_platform() {
    local os arch
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$os" in
        linux)  os="linux" ;;
        darwin) os="darwin" ;;
        *) error "Unsupported OS: $os" ;;
    esac

    arch=$(uname -m)
    case "$arch" in
        x86_64)          arch="amd64" ;;
        aarch64|arm64)   arch="arm64" ;;
        armv6l)          arch="armv6l" ;;
        i386|i686)       arch="386" ;;
        *) error "Unsupported architecture: $arch" ;;
    esac

    echo "${os}-${arch}"
}

# ── Fetch latest Go version string ────────────────────────────────────────────
fetch_latest_version() {
    local latest
    if command -v curl &>/dev/null; then
        latest=$(curl -fsSL "$GO_API" | grep -oP '"version":\s*"\Kgo[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
    elif command -v wget &>/dev/null; then
        latest=$(wget -qO- "$GO_API" | grep -oP '"version":\s*"\Kgo[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
    else
        error "Neither curl nor wget found. Please install one of them."
    fi
    [[ -z "$latest" ]] && error "Could not fetch latest Go version from go.dev"
    echo "$latest"
}

# ── Get installed version (returns empty if not installed) ────────────────────
current_version() {
    if command -v go &>/dev/null; then
        go version | grep -oP 'go[0-9]+\.[0-9]+(\.[0-9]+)?'
    elif [[ -x "${GO_INSTALL_DIR}/go/bin/go" ]]; then
        "${GO_INSTALL_DIR}/go/bin/go" version | grep -oP 'go[0-9]+\.[0-9]+(\.[0-9]+)?'
    else
        echo ""
    fi
}

# ── Compare semver strings (strips leading "go") ──────────────────────────────
# Returns 0 if $1 >= $2 (already up to date)
is_up_to_date() {
    local cur="${1#go}" lat="${2#go}"
    # Use sort -V (version sort) — available in GNU coreutils
    local older
    older=$(printf '%s\n%s' "$cur" "$lat" | sort -V | head -1)
    [[ "$older" == "$lat" ]]   # latest <= current  →  up to date
}

# ── Auto-detect shell profile file ────────────────────────────────────────────
detect_profile() {
    if [[ -n "$PROFILE_FILE" ]]; then echo "$PROFILE_FILE"; return; fi
    local shell_name
    shell_name=$(basename "${SHELL:-bash}")
    case "$shell_name" in
        bash)  echo "${HOME}/.bashrc" ;;
        zsh)   echo "${HOME}/.zshrc" ;;
        fish)  echo "${HOME}/.config/fish/config.fish" ;;
        *)     echo "${HOME}/.profile" ;;
    esac
}

# ── Ensure PATH is set in profile ─────────────────────────────────────────────
ensure_path() {
    local profile go_bin="${GO_INSTALL_DIR}/go/bin"
    profile=$(detect_profile)

    if ! grep -qF "$go_bin" "$profile" 2>/dev/null; then
        info "Adding $go_bin to PATH in $profile"
        {
            echo ""
            echo "# Go — added by update_go.sh"
            echo "export PATH=\"\$PATH:${go_bin}\""
        } >> "$profile"
        success "PATH updated. Run:  source $profile"
    fi

    # Also export for this session
    export PATH="$PATH:${go_bin}"
}

# ── Download & verify tarball ─────────────────────────────────────────────────
download_go() {
    local version="$1" platform="$2"
    local tarball="${version}.${platform}.tar.gz"
    local url="${GO_DL_BASE}/${tarball}"
    local dest="/tmp/${tarball}"

    if [[ -f "$dest" ]]; then
        info "Tarball already in /tmp — skipping download."
    else
        info "Downloading ${url} …"
        if command -v curl &>/dev/null; then
            curl -fL --progress-bar -o "$dest" "$url"
        else
            wget -q --show-progress -O "$dest" "$url"
        fi
    fi

    # SHA256 checksum verification
    info "Verifying checksum …"
    local expected_sha
    if command -v curl &>/dev/null; then
        expected_sha=$(curl -fsSL "${GO_API}" \
            | grep -A20 "\"${tarball}\"" \
            | grep -oP '"sha256":\s*"\K[0-9a-f]+' | head -1)
    else
        expected_sha=$(wget -qO- "${GO_API}" \
            | grep -A20 "\"${tarball}\"" \
            | grep -oP '"sha256":\s*"\K[0-9a-f]+' | head -1)
    fi

    if [[ -n "$expected_sha" ]]; then
        local actual_sha
        actual_sha=$(sha256sum "$dest" | awk '{print $1}')
        if [[ "$actual_sha" != "$expected_sha" ]]; then
            rm -f "$dest"
            error "Checksum mismatch!\n  expected: $expected_sha\n  actual:   $actual_sha"
        fi
        success "Checksum verified ✓"
    else
        warn "Could not fetch expected checksum — skipping verification."
    fi

    echo "$dest"
}

# ── Install ───────────────────────────────────────────────────────────────────
install_go() {
    local tarball="$1"

    # Remove old installation
    if [[ -d "${GO_INSTALL_DIR}/go" ]]; then
        info "Removing old Go from ${GO_INSTALL_DIR}/go …"
        sudo rm -rf "${GO_INSTALL_DIR}/go"
    fi

    info "Extracting to ${GO_INSTALL_DIR} …"
    sudo tar -C "$GO_INSTALL_DIR" -xzf "$tarball"

    # Clean up
    rm -f "$tarball"
    success "Extraction complete."
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    echo -e "\n${BOLD}══════════════════════════════════════${RESET}"
    echo -e "${BOLD}   Go Version Manager — update_go.sh  ${RESET}"
    echo -e "${BOLD}══════════════════════════════════════${RESET}\n"

    local platform latest current tarball

    platform=$(detect_platform)
    info "Platform: ${platform}"

    info "Fetching latest Go version from go.dev …"
    latest=$(fetch_latest_version)
    info "Latest available: ${BOLD}${latest}${RESET}"

    current=$(current_version)
    if [[ -n "$current" ]]; then
        info "Currently installed: ${BOLD}${current}${RESET}"
        if is_up_to_date "$current" "$latest"; then
            success "Already up to date (${current}). Nothing to do."
            ensure_path
            exit 0
        fi
        info "Upgrade available: ${current} → ${latest}"
    else
        info "Go is not currently installed."
    fi

    # Prompt unless --yes / -y flag given
    if [[ "${1:-}" != "-y" && "${1:-}" != "--yes" ]]; then
        read -rp $'\nProceed with installation of '"${latest}"'? [Y/n] ' yn
        [[ "${yn,,}" =~ ^(n|no)$ ]] && { info "Aborted."; exit 0; }
    fi

    tarball=$(download_go "$latest" "$platform")
    install_go "$tarball"
    ensure_path

    echo ""
    success "Go ${latest} installed successfully!"
    echo -e "  ${CYAN}go version:${RESET} $("${GO_INSTALL_DIR}/go/bin/go" version)"
    echo ""
}

main "$@"
