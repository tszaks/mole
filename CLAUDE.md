# CLAUDE.md - Development Guide for Mole

This guide provides AI coding assistants with essential commands, patterns, and conventions for working in the Mole codebase.

**Quick reference**: Build/test commands • Safety rules • Architecture map • Code style

**For deeper context**: See `AGENTS.md` (architecture overview) and subdirectory guides: `lib/AGENTS.md`, `cmd/AGENTS.md`, `tests/AGENTS.md`

---

## Safety Checklist

Before any operation:

- Use `safe_*` helpers (never raw `rm -rf` or `find -delete`)
- Check protection: `is_protected()`, `is_whitelisted()`
- Test first: `MO_DRY_RUN=1 ./mole clean`
- Validate syntax: `bash -n <file>`
- Run tests: `./scripts/test.sh`

## NEVER Do These

- Run `rm -rf` or any raw deletion commands
- Delete files without checking protection lists
- Modify system-critical paths (e.g., `/System`, `/Library/Apple`)
- Remove installer flags `--prefix`/`--config` from `install.sh`
- **Commit code changes or run `git commit` unless the user explicitly asks you to commit**
- **Push to remote repositories with `git push` or create commits automatically**
- **Create new git branches unless the user explicitly asks for a new branch**
- **Add `Co-Authored-By` lines in commit messages** - never include AI attribution in commits
- **Reply to GitHub issues or PRs on behalf of the user** - only prepare responses for user review
- **Comment on GitHub issues or create pull requests without explicit user request**
- Run destructive operations without dry-run validation
- Use raw `git` commands when `gh` CLI is available
- **Change the ESC key timeout in `lib/core/ui.sh`** - The 1s timeout in `read_key()` is intentional, do NOT reduce it

## ALWAYS Do These

- Use `safe_*` helper functions for deletions (`safe_rm`, `safe_find_delete`)
- Respect whitelist files (e.g., `~/.config/mole/whitelist`)
- Check protection logic before cleanup operations
- Test with dry-run modes first
- Validate syntax before suggesting changes: `bash -n <file>`
- **Prioritize `gh` CLI for ALL GitHub operations** - Always use `gh` to fetch and manipulate GitHub data (issues, PRs, releases, comments, etc.) instead of raw git commands or web scraping
- **ONLY analyze and provide solutions** - When user asks about GitHub issues, read the content, investigate code, provide diagnostic information and fixes, but NEVER commit or comment without explicit request
- **Wait for explicit permission** - Before any git commit, git push, or GitHub interaction, wait for user to explicitly request it
- **Stay on the current branch by default** - Only create or switch branches when the user explicitly requests it
- **Group commits by requirement** - Use one logical commit per requirement and do not mix unrelated file changes in the same commit
- Review and update `SECURITY_AUDIT.md` when modifying `clean` or `optimize` logic

---

## Quick Reference

### Build Commands

```bash
# Build Go binaries for current platform
make build

# Build release binaries (cross-platform)
make release-amd64  # macOS Intel
make release-arm64   # macOS Apple Silicon

# Clean build artifacts
make clean
```

### Test Commands

```bash
# Run full test suite (recommended before commits)
./scripts/test.sh

# Run specific BATS test file
bats tests/clean.bats

# Run specific test case by name
bats tests/clean.bats -f "should respect whitelist"

# Run Go tests only
go test -v ./cmd/...

# Run Go tests for specific package
go test -v ./cmd/analyze

# Shell syntax check
bash -n lib/clean/user.sh
bash -n mole

# Lint shell scripts
shellcheck --rcfile .shellcheckrc lib/**/*.sh bin/**/*.sh
```

### Development Commands

```bash
# Test cleanup in dry-run mode
MO_DRY_RUN=1 ./mole clean

# Enable debug logging
MO_DEBUG=1 ./mole clean

# Disable operation logging
MO_NO_OPLOG=1 ./mole clean

# Test Go tool directly
go run ./cmd/analyze

# Test installation locally
./install.sh --prefix /usr/local/bin --config ~/.config/mole
```

### Log Files

| File | Purpose |
|------|---------|
| `~/.config/mole/mole.log` | General log (INFO/SUCCESS/WARNING/ERROR) |
| `~/.config/mole/mole_debug_session.log` | Debug session log (MO_DEBUG=1) |
| `~/.config/mole/operations.log` | Operation log (all file deletions) |

**Operation Log Format**:

```text
[2024-01-26 10:30:15] [clean] REMOVED /Users/xxx/Library/Caches/com.old.app (15.2MB)
[2024-01-26 10:30:15] [clean] SKIPPED /Users/xxx/Library/Caches/com.protected.app (whitelist)
[2024-01-26 10:30:20] [uninstall] REMOVED /Applications/OldApp.app (150MB)
```

- **Actions**: `REMOVED` | `SKIPPED` | `FAILED` | `REBUILT`
- **Commands**: `clean` | `uninstall` | `optimize` | `purge`
- Disable with `MO_NO_OPLOG=1`
- Auto-rotates at 5MB

---

## Architecture Quick Map

```text
mole/                      # Main CLI entrypoint (menu + routing)
├── mo                     # CLI alias wrapper
├── install.sh             # Manual installer/updater (preserves --prefix/--config)
├── bin/                   # Command entry points (thin wrappers)
│   ├── clean.sh           # Deep cleanup orchestrator
│   ├── uninstall.sh       # App removal with leftover detection
│   ├── optimize.sh        # Cache rebuild + service refresh
│   ├── purge.sh           # Aggressive cleanup mode
│   ├── touchid.sh         # Touch ID sudo enabler
│   ├── analyze.sh         # Disk usage explorer wrapper
│   ├── status.sh          # System health dashboard wrapper
│   ├── installer.sh       # Core installation logic
│   └── completion.sh      # Shell completion support
├── lib/                   # Reusable shell logic
│   ├── core/              # base.sh, log.sh, sudo.sh, ui.sh
│   ├── clean/             # Cleanup modules (user, apps, brew, system...)
│   ├── optimize/          # Optimization modules
│   ├── check/             # Health check modules
│   ├── manage/            # Management utilities
│   ├── ui/                # UI components (balloons, spinners)
│   └── uninstall/         # Uninstallation logic
├── cmd/                   # Go applications
│   ├── analyze/           # Disk analysis tool
│   └── status/            # Real-time monitoring
├── scripts/               # Build and test automation
│   └── test.sh            # Main test runner (shell + go + BATS)
└── tests/                 # BATS integration tests
```

**Decision Tree**:

- User cleanup logic → `lib/clean/<module>.sh`
- Command entry → `bin/<command>.sh`
- Core utils → `lib/core/<util>.sh`
- Performance tool → `cmd/<tool>/*.go`
- Tests → `tests/<test>.bats`

### Language Stack

- **Shell (Bash 3.2)**: Core cleanup and system operations (`lib/`, `bin/`)
- **Go**: Performance-critical tools (`cmd/analyze/`, `cmd/status/`)
- **BATS**: Integration testing (`tests/`)

---

## Code Style Guidelines

### Shell Scripts

- **Indentation**: 4 spaces (configured in .editorconfig)
- **Variables**: `lowercase_with_underscores`
- **Functions**: `verb_noun` format (e.g., `clean_caches`, `get_size`)
- **Constants**: `UPPERCASE_WITH_UNDERSCORES`
- **Quoting**: Always quote variables: `"$var"` not `$var`
- **Tests**: Use `[[` instead of `[`
- **Command substitution**: Use `$(command)` not backticks
- **Error handling**: Use `set -euo pipefail` at top of files

### Shell Formatting (shfmt)

**CRITICAL**: Always run `./scripts/check.sh --format` before committing shell script changes.

The project uses `shfmt` with these flags: `shfmt -i 4 -ci -sr -w`

| Flag | Meaning | Example |
|------|---------|---------|
| `-i 4` | 4-space indentation | Standard |
| `-ci` | Indent case bodies | `case` items indented |
| `-sr` | Space after redirect | `2> /dev/null` ✅ |

**Correct Style**:

```bash
# Redirects: KEEP the space after > or 2>
command 2> /dev/null
echo "hello" > file.txt

# Case statements: body indented under pattern
case "$var" in
    pattern)
        action
        ;;
esac
```

**Wrong Style** (DO NOT USE):

```bash
# NO: missing space after redirect
command 2>/dev/null

# NO: case body not indented
case "$var" in
pattern)
action
;;
esac
```

### Go Code

- **Formatting**: Follow standard Go conventions (`gofmt`, `go vet`)
- **Package docs**: Add package-level documentation for exported functions
- **Error handling**: Never ignore errors, always handle them explicitly
- **Build tags**: Use `//go:build darwin` for macOS-specific code

### Comments

- **Language**: English only
- **Focus**: Explain "why" not "what" (code should be self-documenting)
- **Safety**: Document safety boundaries explicitly
- **Non-obvious logic**: Explain workarounds or complex patterns

---

## Key Helper Functions

### Safety Helpers (lib/core/base.sh)

- `safe_rm <path>`: Safe deletion with validation
- `safe_find_delete <base> <pattern> <days> <type>`: Protected find+delete
- `is_protected <path>`: Check if path is system-protected
- `is_whitelisted <name>`: Check user whitelist

### Logging (lib/core/log.sh)

- `log_info <msg>`: Informational messages
- `log_success <msg>`: Success notifications
- `log_warn <msg>`: Warnings
- `log_error <msg>`: Error messages
- `debug <msg>`: Debug output (requires MO_DEBUG=1)

### UI Helpers (lib/core/ui.sh)

- `confirm <prompt>`: Yes/no confirmation
- `show_progress <current> <total> <msg>`: Progress display

---

## Testing Strategy

### Test Types

1. **Syntax Validation**: `bash -n <file>` - catches basic errors
2. **Unit Tests**: BATS tests for individual functions
3. **Integration Tests**: Full command execution with BATS
4. **Dry-run Tests**: `MO_DRY_RUN=1` to validate without deletion
5. **Go Tests**: `go test -v ./cmd/...`

### Test Environment Variables

- `MO_DRY_RUN=1`: Preview changes without execution
- `MO_DEBUG=1`: Enable detailed debug logging
- `BATS_FORMATTER=pretty`: Use pretty output for BATS (default)
- `BATS_FORMATTER=tap`: Use TAP output for CI

---

## Common Development Tasks

### Adding New Cleanup Module

1. Create `lib/clean/new_module.sh`
2. Implement cleanup logic using `safe_*` helpers
3. Source it in `bin/clean.sh`
4. Add protection checks for critical paths
5. Write BATS test in `tests/clean.bats`
6. Test with `MO_DRY_RUN=1` first

### Modifying Go Tools

1. Navigate to `cmd/<tool>/`
2. Make changes to Go files
3. Test with `go run .` or `make build && ./bin/<tool>-go`
4. Run `go test -v` for unit tests
5. Check integration: `./mole <command>`

### Debugging Issues

1. Enable debug mode: `MO_DEBUG=1 ./mole clean`
2. Check logs for error messages
3. Verify sudo permissions: `sudo -n true` or `./mole touchid`
4. Test individual functions in isolation
5. Use `shellcheck` for shell script issues

---

## Linting and Quality

### Shell Script Linting

- **Tool**: shellcheck with custom `.shellcheckrc`
- **Disabled rules**: SC2155, SC2034, SC2059, SC1091, SC2038
- **Command**: `shellcheck --rcfile .shellcheckrc lib/**/*.sh bin/**/*.sh`

### Go Code Quality

- **Tools**: `go vet`, `go fmt`, `go test`
- **Command**: `go vet ./cmd/... && go test ./cmd/...`

### CI/CD Pipeline

- **Triggers**: Push/PR to main, dev branches
- **Platforms**: macOS 14, macOS 15
- **Tools**: bats-core, shellcheck, Go 1.24.6
- **Security checks**: Unsafe rm usage, app protection, secret scanning

---

## File Organization Patterns

### Shell Modules

- Entry scripts in `bin/` should be thin wrappers
- Reusable logic goes in `lib/`
- Core utilities in `lib/core/`
- Feature-specific modules in `lib/clean/`, `lib/ui/`, etc.

### Go Packages

- Each tool in its own `cmd/<tool>/` directory
- Main entry point in `main.go`
- Use standard Go project layout
- macOS-specific code guarded with build tags

---

## GitHub Operations

### Always Use gh CLI for GitHub Information

**Golden Rule**: Whenever you need to fetch or manipulate GitHub data (issues, PRs, commits, releases, comments, etc.), **ALWAYS use `gh` CLI first**. It's more reliable, authenticated, and provides structured output compared to web scraping or raw git commands.
When responding to GitHub issues or PRs, fetch the content with `gh` before analysis and avoid web scraping.

**Preferred Commands**:

```bash
# Issues
gh issue view 123              # View issue details
gh issue list                  # List issues
gh issue comment 123 "message"  # Comment on issue

# Pull Requests
gh pr view                     # View current PR
gh pr diff                     # Show diff
gh pr list                     # List PRs
gh pr checkout 123             # Checkout PR branch
gh pr merge                    # Merge current PR

# Repository operations
gh release create v1.0.0        # Create release
gh repo view                   # Repository info
gh api repos/owner/repo/issues # Raw API access
```

**NEVER use raw git commands for GitHub operations** when `gh` is available:

- `git log --oneline origin/main..HEAD` → `gh pr view`
- `git remote get-url origin` → `gh repo view`
- Manual GitHub API curl commands → `gh api`

### Suggesting Latest Version for Testing

When a bug fix is done but not yet released, you can suggest users to install the latest version, but **must distinguish between install methods**:

1. **For Script Users (`curl | bash`)**:
   Users can directly run `mo update --nightly` to pull the latest unreleased `main` branch.

2. **For Homebrew Users (`brew`)**:
   Homebrew users **cannot** use `mo update --nightly` (it will throw an error). Reinstalling via brew (`brew uninstall mole && brew install mole`) also will NOT fetch the unreleased fix, because Brew follows official tags.
   If they want to test immediately, suggest they `brew uninstall mole`, then reinstall using the official curl script.

## Error Handling Patterns

### Shell Scripts

- Use `set -euo pipefail` for strict error handling
- Check command exit codes: `if command; then ...`
- Provide meaningful error messages with `log_error`
- Use cleanup traps for temporary resources

### Go Code

- Never ignore errors: `if err != nil { return err }`
- Use structured error messages
- Handle context cancellation appropriately
- Log errors with context information

---

## Performance Considerations

### Shell Optimization

- Use built-in shell operations over external commands
- Prefer `find -delete` over `-exec rm`
- Minimize subprocess creation
- Use appropriate timeout mechanisms

### Go Optimization

- Use concurrency for I/O-bound operations
- Implement proper caching for expensive operations
- Profile memory usage in scanning operations
- Use efficient data structures for large datasets

---

## Security Best Practices

### Path Validation

- Always validate user-provided paths
- Check against protection lists before operations
- Use absolute paths to prevent directory traversal
- Implement proper sandboxing for destructive operations

### Permission Management

- Request sudo only when necessary
- Use `sudo -n true` to check sudo availability
- Implement proper Touch ID integration
- Respect user whitelist configurations

---

## Common Pitfalls to Avoid

1. **Over-engineering**: Keep solutions simple. Don't add abstractions for one-time operations.
2. **Premature optimization**: Focus on correctness first, performance second.
3. **Assuming paths exist**: Always check before operating on files/directories.
4. **Ignoring protection logic**: User data loss is unacceptable.
5. **Breaking updates**: Keep `--prefix`/`--config` flags in `install.sh`.
6. **Platform assumptions**: Code must work on all supported macOS versions (10.13+).
7. **Silent failures**: Always log errors and provide actionable messages.

---

## Communication Style

- Address the user as "汤帅" (Tang Shuai) in every response
- Be concise and technical
- Explain safety implications upfront
- Show before/after for significant changes
- Provide file:line references for code locations
- Suggest testing steps for validation
- Avoid em dashes in responses

### Responding to Bug Reports (English)

When replying to users after fixing a bug, use this format:

```markdown
Thanks for your feedback! This issue has been fixed.

**Root cause**: [Brief explanation of what caused the bug]

You can install the latest version to test:

\`\`\`bash
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash -s latest
\`\`\`

I'll publish a new official release soon.
```

**Guidelines**:

- Start with "Thanks for your feedback!"
- Explain root cause concisely
- Provide the install command for testing
- Mention a new release is coming

---

## Resources

### Quick Access

- **Main script**: `mole` (menu + routing logic)
- **Protection lists**: Check `is_protected()` implementations in `lib/core/base.sh`
- **User config**: `~/.config/mole/`
- **Test directory**: `tests/`
- **Build scripts**: `scripts/`
- **Documentation**: `README.md`, `CONTRIBUTING.md`, `SECURITY_AUDIT.md`

### Knowledge Base (Deeper Context)

When you need detailed architecture understanding or module-specific patterns:

- **`AGENTS.md`**: Project architecture, entry points, safety philosophy, project-specific patterns
- **`lib/AGENTS.md`**: Shell module library - safety helpers, cleanup modules, UI components, BSD/macOS patterns
- **`cmd/AGENTS.md`**: Go TUI tools - Bubble Tea architecture, concurrency patterns, caching strategies
- **`tests/AGENTS.md`**: BATS testing guide - isolation patterns, safety verification, APFS edge cases

**Workflow**: Use CLAUDE.md for quick lookups → Consult AGENTS.md hierarchy for deep dives

---

## Common Scenarios for Claude Code CLI

### Scenario 1: Adding New Feature

```bash
# 1. Read relevant documentation first
# For cleanup feature: check AGENTS.md → lib/AGENTS.md
# For Go tool feature: check AGENTS.md → cmd/AGENTS.md

# 2. Locate the right module
# Decision tree in AGENTS.md line 297-305

# 3. Check existing patterns
grep -r "similar_function" lib/

# 4. Implement with safety checks
# Always use safe_* helpers (see lib/AGENTS.md lines 52-89)

# 5. Test before committing
MO_DRY_RUN=1 ./mole clean
./scripts/test.sh
```

### Scenario 2: Debugging Issues

```bash
# 1. Enable debug mode
MO_DEBUG=1 ./mole clean

# 2. Check operation log
tail -f ~/.config/mole/operations.log

# 3. Verify safety boundaries
# If deletion failed, check lib/core/base.sh:is_protected()

# 4. Test individual function
# Source the module and test in isolation
source lib/clean/apps.sh
is_launch_item_orphaned "/path/to/plist"
```

### Scenario 3: Understanding Code Flow

```bash
# 1. Start with entry point (AGENTS.md lines 48-54)
# User invokes: mo clean
#   ↓
# mole routes to: bin/clean.sh
#   ↓
# bin/clean.sh sources: lib/clean/*.sh
#   ↓
# Cleanup modules call: safe_* from lib/core/base.sh

# 2. Check module-specific docs
# For shell modules: lib/AGENTS.md
# For Go tools: cmd/AGENTS.md
# For tests: tests/AGENTS.md
```

### Scenario 4: Code Review / PR Analysis

```bash
# 1. Fetch PR with gh CLI
gh pr view 123
gh pr diff

# 2. Check safety compliance
# Scan for forbidden patterns (CLAUDE.md lines 19-32)
grep -n "rm -rf" changed_files.sh
grep -n "is_protected" changed_files.sh

# 3. Verify test coverage
bats tests/related_test.bats

# 4. Check formatting
./scripts/check.sh --format
```

---

**Remember**: When in doubt, err on the side of safety. It's better to clean less than to risk user data.
