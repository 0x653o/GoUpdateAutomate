# GoUpdateAutomate

A zero-dependency Bash script that manages multiple Go versions — install, switch, remove, and auto-update with SHA-256 verification.

---

## Features

- 🔍 **Queries go.dev** for latest stable releases at runtime
- 🗂️ **Multi-version management** — install several versions side-by-side
- 🔀 **Instant version switching** via symlink
- ⚖️ **Semantic version comparison** — skips install if already up to date
- 🔒 **SHA-256 checksum verification** before extracting
- 🖥️ **Auto-detects OS & architecture** (`linux`/`darwin`, `amd64`/`arm64`/`armv6l`/`386`)
- 🛠️ **Patches your shell profile** with the correct `$PATH` entry
- 🎨 **Coloured output** with clear `INFO` / `OK` / `WARN` / `ERROR` levels

---

## Requirements

| Tool | Purpose |
|------|---------|
| `bash` ≥ 4 | Shell runtime |
| `curl` **or** `wget` | Download + API calls |
| `sha256sum` | Checksum verification |
| `tar` | Extraction |
| `sudo` | Write access to install dir |

---

## Quick Start

```bash
git clone git@github.com:0x653o/GoUpdateAutomate.git
cd GoUpdateAutomate
chmod +x update_go.sh

# Install latest stable Go
sudo ./update_go.sh install
```

After installation the script patches three places automatically:

| File | Scope |
|------|-------|
| `/etc/profile.d/go.sh` | All users — active on next login |
| `~/.bashrc` (or `~/.zshrc`) of the **invoking user** | Your shell sessions |
| `/root/.bashrc` | Root sessions (when run via sudo) |

**Reload your current terminal** to pick up the new PATH:

```bash
source ~/.bashrc   # or ~/.zshrc
go version
```

> **Tip:** New terminals will have `go` available automatically without sourcing.

---

## Commands

```
Usage: update_go.sh [command] [options]

  install [version]   Install a specific version (default: latest stable)
  update              Install latest stable & activate it
  use <version>       Switch the active Go version
  remove <version>    Uninstall a specific version
  list                Show locally installed versions
  list-remote [n]     Show latest N releases from go.dev (default: 10)
  current             Show the active version
```

### Examples

```bash
# Install latest stable
sudo ./update_go.sh install

# Install a specific version
sudo ./update_go.sh install 1.22.5

# See what's available remotely
./update_go.sh list-remote 5

# Switch active version
sudo ./update_go.sh use 1.22.5

# Show installed versions
./update_go.sh list

# Show active version
./update_go.sh current

# Update to latest
sudo ./update_go.sh update

# Remove a version
sudo ./update_go.sh remove 1.21.0
```

---

## How It Works

```
Versions directory:  /usr/local/go-versions/
  ├── go1.22.5/
  ├── go1.25.0/
  └── go1.26.3/

Active symlink:      /usr/local/go → /usr/local/go-versions/go1.26.3
```

Each version is installed in its own directory. `use` just re-points the symlink — switching is instant with no re-download.

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GO_VERSIONS_DIR` | `/usr/local/go-versions` | Directory holding all installed versions |
| `GO_ACTIVE_LINK` | `/usr/local/go` | Symlink pointing to the active version |
| `PROFILE_FILE` | auto-detected | Shell profile to patch for `PATH` |

---

## Example Output

```
══════════════════════════════════════
   GoUpdateAutomate — Go Version Mgr
══════════════════════════════════════

[INFO]  Platform: linux-amd64
[INFO]  Target version: go1.26.3
[INFO]  Downloading https://dl.google.com/go/go1.26.3.linux-amd64.tar.gz …
################################################# 100.0%
[INFO]  Verifying SHA-256 checksum …
[OK]    Checksum OK ✓
[INFO]  Installing go1.26.3 to /usr/local/go-versions/go1.26.3 …
[OK]    go1.26.3 installed → /usr/local/go-versions/go1.26.3
[INFO]  Switching active version to go1.26.3 …
[OK]    Active Go → go1.26.3
        go version go1.26.3 linux/amd64
```

---

## License

[MIT](LICENSE)
