# AGENTS.md - Mole Project Knowledge Base

## Project Identity

**Mole** is a hybrid macOS cleanup tool combining:

- **Bash 3.2** for system operations and orchestration (`lib/`, `bin/`)
- **Go 1.24+** for high-performance TUI components (`cmd/analyze`, `cmd/status`)
- **Safety-first philosophy**: User data loss is unacceptable

**Mission**: Deep clean and optimize macOS while maintaining strict safety boundaries.

---

## Architecture Overview

```text
mole/                      # Main CLI entrypoint (menu + routing)
├── mo                     # Lightweight wrapper, exec's mole
├── install.sh             # Standalone installer/updater
├── bin/                   # Command entry points (thin wrappers)
│   ├── clean.sh           # Deep cleanup orchestrator
│   ├── uninstall.sh       # App removal with leftover detection
│   ├── optimize.sh        # Cache rebuild + service refresh
│   ├── purge.sh           # Project artifact cleanup
│   ├── touchid.sh         # Touch ID sudo enabler
│   ├── analyze.sh         # Disk usage explorer wrapper
│   ├── status.sh          # System health dashboard wrapper
│   ├── installer.sh       # Core installation logic
│   └── completion.sh      # Shell completion support
├── lib/                   # Reusable shell logic (see lib/AGENTS.md)
│   ├── core/              # base.sh, log.sh, sudo.sh, ui.sh
│   ├── clean/             # Cleanup modules (user, apps, brew, system)
│   ├── optimize/          # Optimization modules
│   ├── check/             # Health check modules
│   ├── manage/            # Management utilities
│   ├── ui/                # UI components (balloons, spinners)
│   └── uninstall/         # Uninstallation logic
├── cmd/                   # Go applications (see cmd/AGENTS.md)
│   ├── analyze/           # Disk analysis tool (Bubble Tea TUI)
│   └── status/            # Real-time monitoring (Bubble Tea TUI)
├── scripts/               # Build and test automation
│   ├── build.sh           # Cross-platform Go builds
│   ├── test.sh            # Main test runner (shell + go + BATS)
│   └── check.sh           # Format + lint + optimization score
└── tests/                 # BATS integration tests (see tests/AGENTS.md)
```

### Entry Point Flow

1. **User invokes**: `mo clean` or `./mole clean`
2. **`mole` script**: Routes to `bin/clean.sh` via `exec`
3. **`bin/clean.sh`**: Sources `lib/clean/*.sh` modules
4. **Cleanup modules**: Call `safe_*` helpers from `lib/core/base.sh`
5. **Logging/UI**: Handled by `lib/core/log.sh` + `lib/core/ui.sh`

---

## Safety Philosophy (CRITICAL)

### NEVER Do These

- Run `rm -rf` or any raw deletion commands
- Delete files without checking protection lists (`is_protected()`, `is_whitelisted()`)
- Modify system-critical paths (`/System`, `/Library/Apple`, `/usr/bin`)
- Remove `--prefix`/`--config` flags from `install.sh`
- Commit or push to remote without explicit user request
- Add `Co-Authored-By` (AI attribution) in commit messages
- Change the 1s ESC key timeout in `lib/core/ui.sh`
- Touch `com.apple.*` LaunchAgents/Daemons
- Clean during active Time Machine backups

### ALWAYS Do These

- Use `safe_*` helpers (`safe_rm`, `safe_find_delete` from `lib/core/base.sh`)
- Validate paths before operations (`validate_path`, `is_protected`)
- Test with `MO_DRY_RUN=1` before destructive operations
- Run `./scripts/check.sh` before committing shell changes
- Use `gh` CLI for ALL GitHub operations (issues, PRs, releases)
- Respect whitelist files (`~/.config/mole/whitelist`)
- Review and update `SECURITY_AUDIT.md` when modifying cleanup logic

### Protection Mechanisms

| Function | Location | Purpose |
|----------|----------|---------|
| `is_protected()` | `lib/core/base.sh` | System path protection |
| `is_whitelisted()` | `lib/core/base.sh` | User whitelist check |
| `safe_rm()` | `lib/core/base.sh` | Validated deletion |
| `safe_find_delete()` | `lib/core/base.sh` | Protected find+delete |
| `validate_path()` | Various | Path safety checks |

---

## Code Style & Conventions

### Shell Scripts (Bash 3.2)

**Formatting**: Run `./scripts/check.sh --format` before committing.

```bash
# shfmt flags: -i 4 -ci -sr -w
# 4-space indent, case body indent, space after redirect

# CORRECT
command 2> /dev/null
echo "hello" > file.txt

case "$var" in
    pattern)
        action
        ;;
esac

# WRONG
command 2>/dev/null  # Missing space after >
```

**Naming Conventions**:

- Variables: `lowercase_with_underscores`
- Functions: `verb_noun` (e.g., `clean_caches`, `get_size`)
- Constants: `UPPERCASE_WITH_UNDERSCORES`

**Error Handling**:

```bash
set -euo pipefail  # Mandatory at top of files

# Always quote variables
"$var" not $var

# Use [[ instead of [
if [[ -f "$file" ]]; then
    ...
fi
```

**BSD/macOS Commands**: Use BSD-style flags, not GNU.

```bash
# CORRECT (BSD)
stat -f%z "$file"

# WRONG (GNU)
stat --format=%s "$file"
```

### Go Code

**Formatting**: Standard `gofmt` or `goimports -local github.com/tw93/Mole`

**Build Tags**: Use for macOS-specific code

```go
//go:build darwin
```

**Error Handling**: Never ignore errors

```go
if err != nil {
    return fmt.Errorf("operation failed: %w", err)
}
```

### Comments

- **Language**: English only
- **Focus**: Explain "why" not "what"
- **Safety**: Document protection boundaries explicitly

---

## Build & Test

### Build Commands

```bash
make build                # Current platform
make release-amd64        # macOS Intel
make release-arm64        # macOS Apple Silicon
make clean                # Remove artifacts
```

### Test Commands

```bash
./scripts/test.sh         # Full suite (recommended)
bats tests/clean.bats     # Specific BATS test
go test -v ./cmd/...      # Go tests only
bash -n lib/clean/*.sh    # Syntax check
shellcheck lib/**/*.sh    # Lint shell scripts
```

### CI/CD Pipeline

**Triggers**: Push/PR to `main`, `dev` branches

**Key Checks**:

- **Auto-formatting**: CI commits `shfmt` + `goimports` fixes back to branch
- **Safety audits**: Scans for raw `rm -rf`, validates protection lists
- **Secret scanning**: Blocks hardcoded credentials
- **Optimization score**: `scripts/check.sh` enforces performance standards

**Environment Requirements**:

- Go 1.24.6 (pinned)
- macOS 14/15 runners
- bats-core for shell integration tests
- Performance limits via `MOLE_PERF_*` env vars

---

## GitHub Workflow

### Always Use `gh` CLI

```bash
# Issues
gh issue view 123
gh issue list

# Pull Requests
gh pr view
gh pr diff
gh pr checkout 123

# NEVER use raw git for GitHub operations
# ❌ git log --oneline origin/main..HEAD
# ✅ gh pr view
```

### Branch Strategy

- **PRs target `dev`**, not `main`
- Release process: `dev` → `main` → tagged release → Homebrew update
- **Do not create new branches by default**. Stay on the current branch unless the user explicitly requests branch creation.

### Commit Grouping Strategy

- When the user asks for commits, **group commits by requirement**, not by command sequence.
- Keep each commit scoped to one logical change (feature/fix/docs/release), and avoid mixing unrelated files.
- If one request contains multiple requirements, submit them as separate commits in dependency order.
- Before committing, review staged files to ensure they belong to the same requirement.

### Suggesting Latest Version for Testing

When a bug fix is done but not yet released, you can suggest users to install the latest version, but **must distinguish between install methods**:

1. **For Script Users (`curl | bash`)**:
   Users can directly run `mo update --nightly` to pull the latest unreleased `main` branch.

2. **For Homebrew Users (`brew`)**:
   Homebrew users **cannot** use `mo update --nightly` (it will throw an error). Reinstalling via brew (`brew uninstall mole && brew install mole`) also will NOT fetch the unreleased fix, because Brew follows official tags.
   If they want to test immediately, suggest they `brew uninstall mole`, then reinstall using the official curl script.

---

## Logging & Debugging

### Log Files

| File | Purpose | Control |
|------|---------|---------|
| `~/.config/mole/mole.log` | General log (INFO/SUCCESS/WARNING/ERROR) | Always |
| `~/.config/mole/mole_debug_session.log` | Debug session log | `MO_DEBUG=1` |
| `~/.config/mole/operations.log` | All file deletions | Disable: `MO_NO_OPLOG=1` |

### Environment Variables

- `MO_DRY_RUN=1`: Preview without execution
- `MO_DEBUG=1`: Verbose debug output
- `MO_NO_OPLOG=1`: Disable operation logging

### Operation Log Format

```text
[2024-01-26 10:30:15] [clean] REMOVED /Users/xxx/Library/Caches/com.old.app (15.2MB)
[2024-01-26 10:30:15] [clean] SKIPPED /Users/xxx/Library/Caches/com.protected.app (whitelist)
```

- **Actions**: `REMOVED` | `SKIPPED` | `FAILED` | `REBUILT`
- **Commands**: `clean` | `uninstall` | `optimize` | `purge`
- Auto-rotates at 5MB

---

## Project-Specific Patterns

### Installer Self-Containment

`install.sh` duplicates core UI/logging functions to remain standalone during bootstrap. This is intentional—it cannot depend on `lib/`.

### Atomic Update Flow

1. User runs `mo update`
2. Fetches latest `install.sh` from GitHub
3. Installer modifies `SCRIPT_DIR` in installed `mole` to point to `~/.config/mole`
4. Ensures CLI always uses latest synced modules

### Dual Entry Points

- **`mole`**: Main executable (menu + routing)
- **`mo`**: Lightweight alias (recommended for users)

Both are functionally identical (`mo` calls `exec mole`).

---

## Communication Style

- **Address user as "汤帅" (Tang Shuai)** in all responses
- **Be concise and technical**
- **Explain safety implications upfront**
- **Provide file:line references** for code locations
- **Suggest validation steps** (dry-run, syntax check)
- **Avoid em dashes** in responses

### Responding to Bug Reports (English)

When replying to users after fixing a bug:

```markdown
Thanks for your feedback! This issue has been fixed.

**Root cause**: [Brief explanation of the bug cause]

You can install the latest version to test:

\`\`\`bash
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash -s latest
\`\`\`

I'll publish a new official release soon.
```

**Key elements**:

- Start with "Thanks for your feedback!"
- Explain root cause concisely
- Provide the install command for testing
- Mention a new release is coming soon

---

## Quick Reference

### Decision Tree

| Task | Location | Pattern |
|------|----------|---------|
| Add cleanup logic | `lib/clean/<module>.sh` | Use `safe_*` helpers |
| Create command | `bin/<command>.sh` | Thin wrapper, source `lib/` |
| Add core utility | `lib/core/<util>.sh` | Reusable functions |
| Build performance tool | `cmd/<tool>/` | Go with build tags |
| Write tests | `tests/<test>.bats` | BATS + isolated `$HOME` |

### Common Pitfalls

1. **Over-engineering**: Keep it simple
2. **Assuming paths exist**: Always check first
3. **Ignoring protection logic**: Data loss is unacceptable
4. **Breaking installer flags**: Keep `--prefix`/`--config` in `install.sh`
5. **Silent failures**: Log errors with actionable messages

---

## Resources

- **Root documentation**: `README.md`, `CONTRIBUTING.md`, `SECURITY_AUDIT.md`
- **Code guidelines**: `CLAUDE.md` (AI assistant instructions)
- **Subdirectory guides**: `lib/AGENTS.md`, `cmd/AGENTS.md`, `tests/AGENTS.md`
- **Protection lists**: Check `is_protected()` implementations
- **User config**: `~/.config/mole/`

---

**Remember**: When in doubt, err on the side of safety. It's better to clean less than to risk user data.
