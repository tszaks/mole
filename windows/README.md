# Mole for Windows

Windows support for [Mole](https://github.com/tw93/Mole) - A system maintenance toolkit.

## Requirements

- Windows 10/11
- PowerShell 5.1 or later (pre-installed on Windows 10/11)
- Go 1.24+ (for building TUI tools)

## Installation

### Quick Install

```powershell
# Clone the repository
git clone https://github.com/tw93/Mole.git
cd Mole/windows

# Run the installer
.\install.ps1 -AddToPath
```

### Manual Installation

```powershell
# Install to custom location
.\install.ps1 -InstallDir C:\Tools\Mole -AddToPath

# Create Start Menu shortcut
.\install.ps1 -AddToPath -CreateShortcut
```

### Uninstall

```powershell
.\install.ps1 -Uninstall
```

## Usage

```powershell
# Interactive menu
mole

# Show help
mole -ShowHelp

# Show version
mole -Version

# Commands
mole clean              # Deep system cleanup
mole clean -DryRun      # Preview cleanup without deleting
mole uninstall          # Interactive app uninstaller
mole optimize           # System optimization
mole purge              # Clean developer artifacts
mole analyze            # Disk space analyzer
mole status             # System health monitor
```

## Commands

| Command | Description |
|---------|-------------|
| `clean` | Deep cleanup of temp files, caches, and logs |
| `uninstall` | Interactive application uninstaller |
| `optimize` | System optimization and health checks |
| `purge` | Clean project build artifacts (node_modules, etc.) |
| `analyze` | Interactive disk space analyzer (TUI) |
| `status` | Real-time system health monitor (TUI) |

## Environment Variables

| Variable | Description |
|----------|-------------|
| `MOLE_DRY_RUN=1` | Preview changes without making them |
| `MOLE_DEBUG=1` | Enable debug output |
| `MO_ANALYZE_PATH` | Starting path for analyze tool |

## Directory Structure

```
windows/
├── mole.ps1          # Main CLI entry point
├── install.ps1       # Windows installer
├── Makefile          # Build automation for Go tools
├── go.mod            # Go module definition
├── go.sum            # Go dependencies
├── bin/
│   ├── clean.ps1     # Deep cleanup orchestrator
│   ├── uninstall.ps1 # Interactive app uninstaller
│   ├── optimize.ps1  # System optimization
│   ├── purge.ps1     # Project artifact cleanup
│   ├── analyze.ps1   # Disk analyzer wrapper
│   └── status.ps1    # Status monitor wrapper
├── cmd/
│   ├── analyze/      # Disk analyzer (Go TUI)
│   │   └── main.go
│   └── status/       # System status (Go TUI)
│       └── main.go
└── lib/
    ├── core/
    │   ├── base.ps1      # Core definitions and utilities
    │   ├── common.ps1    # Common functions loader
    │   ├── file_ops.ps1  # Safe file operations
    │   ├── log.ps1       # Logging functions
    │   └── ui.ps1        # Interactive UI components
    └── clean/
        ├── user.ps1      # User cleanup (temp, downloads, etc.)
        ├── caches.ps1    # Browser and app caches
        ├── dev.ps1       # Developer tool caches
        ├── apps.ps1      # Application leftovers
        └── system.ps1    # System cleanup (requires admin)
```

## Building TUI Tools

The analyze and status commands require Go to be installed:

```powershell
cd windows

# Build both tools
make build

# Or build individually
go build -o bin/analyze.exe ./cmd/analyze/
go build -o bin/status.exe ./cmd/status/

# The wrapper scripts will auto-build if Go is available
```

## Configuration

Mole stores its configuration in:
- Config: `~\.config\mole\`
- Cache: `~\.cache\mole\`
- Whitelist: `~\.config\mole\whitelist.txt`
- Purge paths: `~\.config\mole\purge_paths.txt`

## Development Phases

### Phase 1: Core Infrastructure ✅
- [x] `install.ps1` - Windows installer
- [x] `mole.ps1` - Main CLI entry point
- [x] `lib/core/*` - Core utility libraries

### Phase 2: Cleanup Features ✅
- [x] `bin/clean.ps1` - Deep cleanup orchestrator
- [x] `bin/uninstall.ps1` - App removal with leftover detection
- [x] `bin/optimize.ps1` - System optimization
- [x] `bin/purge.ps1` - Project artifact cleanup
- [x] `lib/clean/*` - Cleanup modules

### Phase 3: TUI Tools ✅
- [x] `cmd/analyze/` - Disk usage analyzer (Go)
- [x] `cmd/status/` - Real-time system monitor (Go)
- [x] `bin/analyze.ps1` - Analyzer wrapper
- [x] `bin/status.ps1` - Status wrapper

### Phase 4: Testing & CI (Planned)
- [ ] `tests/` - Pester tests
- [ ] GitHub Actions workflows
- [ ] `scripts/build.ps1` - Build automation

## License

Same license as the main Mole project.
