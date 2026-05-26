# GoUpdateAutomate

A zero-dependency Bash script that automatically detects, downloads, verifies, and installs the latest stable version of [Go](https://go.dev/) — on Linux and macOS.

---

## Features

- 🔍 **Queries go.dev** for the latest stable release at runtime
- ⚖️ **Semantic version comparison** — skips install if already up to date
- 🔒 **SHA-256 checksum verification** before extracting
- 🖥️ **Auto-detects OS & architecture** (`linux`/`darwin`, `amd64`/`arm64`/`armv6l`/`386`)
- 🛠️ **Patches your shell profile** (`.bashrc`, `.zshrc`, etc.) with the correct `$PATH` entry
- 🎨 **Coloured output** with clear `INFO` / `OK` / `WARN` / `ERROR` levels
- ✅ **Non-interactive mode** for CI/CD pipelines (`--yes` flag)

---

## Requirements

| Tool | Purpose |
|------|---------|
| `bash` ≥ 4 | Shell runtime |
| `curl` **or** `wget` | Download + API calls |
| `sha256sum` | Checksum verification |
| `tar` | Extraction |
| `sudo` | Write access to install dir (default `/usr/local`) |

---

## Quick Start

```bash
# Clone
git clone https://github.com/0x653o/GoUpdateAutomate.git
cd GoUpdateAutomate

# Make executable
chmod +x update_go.sh

# Run (interactive — prompts before installing)
sudo ./update_go.sh

# Reload PATH and verify
source ~/.bashrc
go version
```

---

## Usage

```bash
# Interactive (prompts before installing)
sudo ./update_go.sh

# Non-interactive / CI-friendly
sudo ./update_go.sh --yes
sudo ./update_go.sh -y

# Custom install directory (default: /usr/local)
sudo GO_INSTALL_DIR=/opt ./update_go.sh --yes

# Override shell profile to patch
PROFILE_FILE=~/.zshrc sudo ./update_go.sh --yes
```

---

## How It Works

```
1. Detect OS + CPU architecture
2. Query https://go.dev/dl/?mode=json for the latest stable version
3. Compare against the currently installed version (via `go version`)
4. If an upgrade is available:
   a. Download the tarball from https://dl.google.com/go
   b. Verify SHA-256 checksum against go.dev's published hash
   c. Remove the old /usr/local/go directory
   d. Extract the new tarball to /usr/local
   e. Ensure /usr/local/go/bin is in your PATH
```

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GO_INSTALL_DIR` | `/usr/local` | Where Go is installed (`$GO_INSTALL_DIR/go`) |
| `PROFILE_FILE` | auto-detected | Shell profile to patch for `PATH` |

---

## Example Output

```
══════════════════════════════════════
   Go Version Manager — update_go.sh
══════════════════════════════════════

[INFO]  Platform: linux-amd64
[INFO]  Fetching latest Go version from go.dev …
[INFO]  Latest available: go1.26.3
[INFO]  Currently installed: go1.25.0
[INFO]  Upgrade available: go1.25.0 → go1.26.3

Proceed with installation of go1.26.3? [Y/n] y

[INFO]  Downloading https://dl.google.com/go/go1.26.3.linux-amd64.tar.gz …
[INFO]  Verifying checksum …
[OK]    Checksum verified ✓
[INFO]  Removing old Go from /usr/local/go …
[INFO]  Extracting to /usr/local …
[OK]    Extraction complete.
[OK]    Go go1.26.3 installed successfully!
        go version: go version go1.26.3 linux/amd64
```

---

## License

[MIT](LICENSE)
