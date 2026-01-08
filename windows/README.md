# Mole for Windows

Windows support for [Mole](https://github.com/tw93/Mole) - A system maintenance toolkit.

## Requirements

- Windows 10/11
- PowerShell 5.1 or later (pre-installed on Windows 10/11)
- Optional: Go 1.24+ (for building TUI tools)

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
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| `MOLE_DRY_RUN=1` | Preview changes without making them |
| `MOLE_DEBUG=1` | Enable debug output |

## Directory Structure

```
windows/
├── mole.ps1          # Main CLI entry point
├── install.ps1       # Windows installer
├── go.mod            # Go module definition
├── go.sum            # Go dependencies
└── lib/
    └── core/
        ├── base.ps1      # Core definitions and utilities
        ├── common.ps1    # Common functions loader
        ├── file_ops.ps1  # Safe file operations
        ├── log.ps1       # Logging functions
        └── ui.ps1        # Interactive UI components
```

## Configuration

Mole stores its configuration in:
- Config: `~\.config\mole\`
- Cache: `~\.cache\mole\`
- Whitelist: `~\.config\mole\whitelist.txt`

## Development

### Phase 1: Core Infrastructure (Current)
- [x] `install.ps1` - Windows installer
- [x] `mole.ps1` - Main CLI entry point
- [x] `lib/core/*` - Core utility libraries

### Phase 2: Cleanup Features (Planned)
- [ ] `bin/clean.ps1` - Deep cleanup orchestrator
- [ ] `bin/uninstall.ps1` - App removal with leftover detection
- [ ] `bin/optimize.ps1` - Cache rebuild and service refresh
- [ ] `bin/purge.ps1` - Aggressive cleanup mode
- [ ] `lib/clean/*` - Cleanup modules

### Phase 3: TUI Tools (Planned)
- [ ] `cmd/analyze/` - Disk usage analyzer (Go)
- [ ] `cmd/status/` - Real-time system monitor (Go)
- [ ] `bin/analyze.ps1` - Analyzer wrapper
- [ ] `bin/status.ps1` - Status wrapper

### Phase 4: Testing & CI (Planned)
- [ ] `tests/` - Pester tests
- [ ] GitHub Actions workflows
- [ ] `scripts/build.ps1` - Build automation

## License

Same license as the main Mole project.
