# Mole Security Reference

Version 1.27.0 | 2026-02-21

## Recent Fixes

**Cleanup hardening audit, Feb 2026:**

- `clean_deep_system()` now uses `safe_sudo_find_delete()` and `safe_sudo_remove()` for temp/log/diagnostic/report paths in `lib/clean/system.sh`.
- Removed direct `find ... -delete` from security-sensitive cleanup paths. Deletions now go through validated safe wrappers.
- `process_container_cache()` in `lib/clean/user.sh` now removes entries item-by-item with `safe_remove()`, so every delete is validated.
- `clean_application_support_logs()` now also performs item-by-item `safe_remove()` cleanup instead of direct bulk deletion.
- Group Containers cleanup now builds an explicit candidate list first, then filters protected/whitelisted items before deletion.
- `bin/clean.sh` dry-run export temp files rely on tracked temp lifecycle (`create_temp_file()` + trap cleanup) to avoid orphan temp artifacts.
- Added/updated regression coverage in `tests/clean_system_maintenance.bats`, `tests/clean_core.bats`, and `tests/clean_user_core.bats` for the new safe-deletion flow.
- Added conservative support-cache cleanup in `lib/clean/user.sh`:
  - `~/Library/Application Support/CrashReporter` files older than 30 days
  - `~/Library/Application Support/com.apple.idleassetsd` files older than 30 days
  - `~/Library/Messages/StickerCache` and `~/Library/Messages/Caches/Previews/*` caches only
- Explicitly kept `~/Library/Messages/Attachments` and `~/Library/Metadata/CoreSpotlight` out of automatic cleanup to avoid user-data or indexing risk.
- Added low-risk cache coverage in `lib/clean/app_caches.sh`:
  - `~/Library/Logs/CoreSimulator/*`
  - Adobe media cache (`~/Library/Application Support/Adobe/Common/Media Cache Files/*`)
  - Steam app/depot/shader/log caches and Minecraft/Lunar Client log/cache directories
  - Legacy Microsoft Teams cache/log/temp directories under `~/Library/Application Support/Microsoft/Teams/*`
  - `~/.cacher/logs/*` and `~/.kite/logs/*`
- Added conservative third-party system log cleanup in `lib/clean/system.sh`:
  - `/Library/Logs/Adobe/*` and `/Library/Logs/CreativeCloud/*` older files only
  - `/Library/Logs/adobegc.log` only when older than log retention
- Explicitly did not add high-risk cleanup defaults for:
  - `/private/var/folders/*` broad deletion
  - `~/Library/Application Support/MobileSync/Backup/*`
  - Browser history/cookie databases (e.g., Arc History/Cookies/Web Data)
  - Destructive container/image pruning commands by default

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

System stuff stays untouched: Control Center, System Settings, TCC, Spotlight, `/Library/Updates`.

VPN and proxy tools are skipped: Shadowsocks, V2Ray, Tailscale, Clash.

AI tools are protected: Cursor, Claude, ChatGPT, Ollama, LM Studio.

Time Machine backups running? Won't clean. Status unclear? Also won't clean.

`com.apple.*` LaunchAgents/Daemons are never touched.

See `lib/core/app_protection.sh:is_critical_system_component()`.

## Analyzer

`mo analyze` runs differently:

- Standard user permissions, no sudo
- Respects SIP
- Two keys to delete: press ⌫ first, then Enter. Hard to delete by accident.
- Files go to Trash via Finder API, not rm

Code at `cmd/analyze/*.go`.

## Timeouts

Network volume checks timeout after 5s (NFS/SMB/AFP can hang forever). mdfind searches get 10s. SQLite vacuum gets 20s, skipped if Mail/Safari/Messages is open. dyld cache rebuild gets 180s, skipped if done in the last 24h.

See `lib/core/timeout.sh:run_with_timeout()`.

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

Security-sensitive cleanup paths are covered by BATS regression tests, including:

- `tests/clean_core.bats`
- `tests/clean_user_core.bats`
- `tests/clean_dev_caches.bats`
- `tests/clean_system_maintenance.bats`

Latest local verification for this release branch:

- `bats tests/clean_core.bats` passed (12/12)
- `bats tests/clean_user_core.bats` passed (13/13)
- `bats tests/clean_dev_caches.bats` passed (8/8)
- `bats tests/clean_system_maintenance.bats` passed (40/40)

Run tests:

```bash
bats tests/              # all
bats tests/security.bats # security only
```

CI runs shellcheck and go vet on every push.

## Dependencies

System binaries we use are all SIP protected: `plutil` (plist validation), `tmutil` (Time Machine), `dscacheutil` (cache rebuild), `diskutil` (volume info).

Go deps: bubbletea v0.23+, lipgloss v0.6+, gopsutil v3.22+, xxhash v2.2+. All MIT/BSD licensed. Versions are pinned, no CVEs. Binaries built via GitHub Actions.

## Limitations

System cache cleanup needs sudo, first time you'll get a password prompt. Orphan files wait 60 days before cleanup, use `mo uninstall` to delete manually if you're in a hurry. No undo, gone is gone, use dry-run first. Only recognizes English names, localized app names might be missed, but falls back to bundle ID.

Won't touch: documents, media files, password managers, keychains, configs under `/etc`, browser history/cookies, git repos.
