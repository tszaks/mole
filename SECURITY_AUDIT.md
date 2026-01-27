# Mole Security Reference

Version 1.23.2 | 2026-01-26

## Recent Fixes

**Uninstall audit, Jan 2026:**

- `stop_launch_services()` now checks bundle_id is valid reverse-DNS before using it in find patterns. This stops glob injection.
- `find_app_files()` skips LaunchAgents named after common words like Music or Notes.
- Added comments explaining why `remove_file_list()` bypasses TOCTOU checks for symlinks.
- `brew_uninstall_cask()` treats exit code 124 as timeout failure, returns immediately.

Other changes:

- Symlink cleanup in `bin/clean.sh` goes through `safe_remove` now
- Orphaned helper cleanup in `lib/clean/apps.sh` switched to `safe_sudo_remove`
- ByHost pref cleanup checks bundle ID format first

## Path Validation

Every deletion goes through `lib/core/file_ops.sh`. The `validate_path_for_deletion()` function rejects empty paths, paths with `/../` in them, and anything containing control characters like newlines or null bytes.

**Blocked paths**, even with sudo:

```text
/                    # root
/System              # macOS system
/bin, /sbin, /usr    # binaries
/etc, /var           # config
/Library/Extensions  # kexts
/private             # system private
```

Some system caches are OK to delete:

- `/System/Library/Caches/com.apple.coresymbolicationd/data`
- `/private/tmp`, `/private/var/tmp`, `/private/var/log`, `/private/var/folders`
- `/private/var/db/diagnostics`, `/private/var/db/DiagnosticPipeline`, `/private/var/db/powerlog`, `/private/var/db/reportmemoryexception`

See `lib/core/file_ops.sh:60-78`.

When running with sudo, `safe_sudo_recursive_delete()` also checks for symlinks. Refuses to follow symlinks pointing to system files.

## Cleanup Rules

**Orphan detection** at `lib/clean/apps.sh:orphan_detection()`:

App data is only considered orphaned if the app itself is gone from all three locations: `/Applications`, `~/Applications`, `/System/Applications`. On top of that, the data must be untouched for at least 60 days. Adobe, Microsoft, and Google stuff is whitelisted regardless.

**Uninstall matching** at `lib/clean/apps.sh:uninstall_app()`:

App names need at least 3 characters. Otherwise "Go" would match "Google" and that's bad. Fuzzy matching is off. Receipt scans only look under `/Applications` and `/Library/Application Support`, not in shared places like `/Library/Frameworks`.

**Dev tools:**

Cache dirs like `~/.cargo/registry/cache` or `~/.gradle/caches` get cleaned. But `~/.cargo/bin`, `~/.mix/archives`, `~/.rustup` toolchains, `~/.stack/programs` stay untouched.

**LaunchAgent removal:**

Only removed when uninstalling the app that owns them. All `com.apple.*` items are skipped. Services get stopped via `launchctl` first. Generic names like Music, Notes, Photos are excluded from the search.

See `lib/core/app_protection.sh:find_app_files()`.

## Protected Categories

| Category | What's protected |
| -------- | ---------------- |
| System | Control Center, System Settings, TCC, `/Library/Updates`, Spotlight |
| VPN/Proxy | Shadowsocks, V2Ray, Tailscale, Clash |
| AI | Cursor, Claude, ChatGPT, Ollama, LM Studio |
| Time Machine | Checks if backup is running. If status unclear, skips cleanup. |
| Startup | `com.apple.*` LaunchAgents/Daemons always skipped |

See `lib/core/app_protection.sh:is_critical_system_component()`.

## Analyzer

`mo analyze` runs differently:

- Standard user permissions, no sudo
- Respects SIP
- Two keys to delete: press ⌫ first, then Enter. Hard to delete by accident.
- Files go to Trash via Finder API, not rm

Code at `cmd/analyze/*.go`.

## Timeouts

| Operation | Timeout | Why |
| --------- | ------- | --- |
| Network volume check | 5s | NFS/SMB/AFP can hang forever |
| App bundle search | 10s | mdfind sometimes stalls |
| SQLite vacuum | 20s | Skip if Mail/Safari/Messages is open |
| dyld cache rebuild | 180s | Skip if done in last 24h |

See `lib/core/base.sh:run_with_timeout()`.

## User Config

Put paths in `~/.config/mole/whitelist`, one per line:

```bash
# exact matches only
/Users/me/important-cache
~/Library/Application Support/MyApp
```

These paths are protected from all operations.

Run `mo clean --dry-run` or `mo optimize --dry-run` to preview what would happen without actually doing it.

## Testing

| Area | Coverage |
| ---- | -------- |
| File ops | 95% |
| Cleaning | 87% |
| Optimize | 82% |
| System | 90% |
| Security | 100% |

180+ test cases total, about 88% coverage.

```bash
bats tests/              # run all
bats tests/security.bats # security only
```

CI runs shellcheck and go vet on every push.

## Dependencies

System binaries used, all SIP protected:

| Binary | For |
| ------ | --- |
| `plutil` | plist validation |
| `tmutil` | Time Machine |
| `dscacheutil` | cache rebuild |
| `diskutil` | volume info |

Go libs in analyze-go:

| Lib | Version | License |
| --- | ------- | ------- |
| `bubbletea` | v0.23+ | MIT |
| `lipgloss` | v0.6+ | MIT |
| `gopsutil` | v3.22+ | BSD-3 |
| `xxhash` | v2.2+ | BSD-2 |

Versions are pinned. No CVEs. Binaries built via GitHub Actions.

## Limitations

| What | Impact | Workaround |
| ---- | ------ | ---------- |
| Needs sudo for system caches | Annoying first time | Docs explain why |
| 60-day wait for orphans | Some junk stays longer | Use `mo uninstall` manually |
| No undo | Gone is gone | Use dry-run first |
| English names only | Might miss localized apps | Falls back to bundle ID |

**Won't touch:**

- Your documents or media
- Password managers or keychains
- Files under `/etc`
- Browser history/cookies
- Git repos
