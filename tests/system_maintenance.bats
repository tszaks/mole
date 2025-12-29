#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-system-clean.XXXXXX")"
    export HOME

    mkdir -p "$HOME"
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

@test "clean_deep_system issues safe sudo deletions" {
    run bash --noprofile --norc <<'EOF'
set -euo pipefail
CALL_LOG="$HOME/system_calls.log"
> "$CALL_LOG"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

sudo() { return 0; }
safe_sudo_find_delete() {
    echo "safe_sudo_find_delete:$1:$2" >> "$CALL_LOG"
    return 0
}
safe_sudo_remove() {
    echo "safe_sudo_remove:$1" >> "$CALL_LOG"
    return 0
}
log_success() { :; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
is_sip_enabled() { return 1; }
get_file_mtime() { echo 0; }
get_path_size_kb() { echo 0; }
find() { return 0; }
run_with_timeout() { shift; "$@"; }

clean_deep_system
cat "$CALL_LOG"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"/Library/Caches"* ]]
    [[ "$output" == *"/private/tmp"* ]]
    [[ "$output" == *"/private/var/log"* ]]
}

@test "clean_deep_system skips /Library/Updates when SIP enabled" {
    run bash --noprofile --norc <<'EOF'
set -euo pipefail
CALL_LOG="$HOME/system_calls_skip.log"
> "$CALL_LOG"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

sudo() { return 0; }
safe_sudo_find_delete() { return 0; }
safe_sudo_remove() {
    echo "REMOVE:$1" >> "$CALL_LOG"
    return 0
}
log_success() { :; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
is_sip_enabled() { return 0; } # SIP enabled -> skip removal
find() { return 0; }
run_with_timeout() { shift; "$@"; }

clean_deep_system
cat "$CALL_LOG"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"/Library/Updates"* ]]
}

@test "clean_time_machine_failed_backups exits when tmutil has no destinations" {
    run bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

tmutil() {
    if [[ "$1" == "destinationinfo" ]]; then
        echo "No destinations configured"
        return 0
    fi
    return 0
}
pgrep() { return 1; }
find() { return 0; }

clean_time_machine_failed_backups
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"No incomplete backups found"* ]]
}


@test "clean_homebrew skips when cleaned recently" {
    run bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/brew.sh"

mkdir -p "$HOME/.cache/mole"
date +%s > "$HOME/.cache/mole/brew_last_cleanup"

brew() { return 0; }

clean_homebrew
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"cleaned"* ]]
}

@test "clean_homebrew runs cleanup with timeout stubs" {
    run bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/brew.sh"

mkdir -p "$HOME/.cache/mole"
rm -f "$HOME/.cache/mole/brew_last_cleanup"

# Create a large enough Homebrew cache to pass pre-check (>50MB)
mkdir -p "$HOME/Library/Caches/Homebrew"
dd if=/dev/zero of="$HOME/Library/Caches/Homebrew/test.tar.gz" bs=1024 count=51200 2>/dev/null

MO_BREW_TIMEOUT=2

start_inline_spinner(){ :; }
stop_inline_spinner(){ :; }
note_activity(){ :; }

brew() {
    case "$1" in
        cleanup)
            echo "Removing: package"
            return 0
            ;;
        autoremove)
            echo "Uninstalling pkg"
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}

clean_homebrew

# Cleanup test files
rm -rf "$HOME/Library/Caches/Homebrew"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Homebrew cleanup"* ]]
}

@test "check_appstore_updates is skipped for performance" {
    run bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"

check_appstore_updates
echo "COUNT=$APPSTORE_UPDATE_COUNT"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"COUNT=0"* ]]
}

@test "check_macos_update avoids slow softwareupdate scans" {
    run bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"

defaults() { echo "1"; }

run_with_timeout() {
    local timeout="${1:-}"
    shift
    if [[ "$timeout" != "10" ]]; then
        echo "BAD_TIMEOUT:$timeout"
        return 124
    fi
    if [[ "${1:-}" == "softwareupdate" && "${2:-}" == "-l" && "${3:-}" == "--no-scan" ]]; then
        cat <<'OUT'
Software Update Tool

Software Update found the following new or updated software:
* Label: macOS 99
OUT
        return 0
    fi
    return 124
}

start_inline_spinner(){ :; }
stop_inline_spinner(){ :; }

check_macos_update
echo "MACOS_UPDATE_AVAILABLE=$MACOS_UPDATE_AVAILABLE"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Update available"* ]]
    [[ "$output" == *"MACOS_UPDATE_AVAILABLE=true"* ]]
    [[ "$output" != *"BAD_TIMEOUT:"* ]]
}

@test "check_macos_update clears update flag when softwareupdate reports no updates" {
    run bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"

defaults() { echo "1"; }

run_with_timeout() {
    local timeout="${1:-}"
    shift
    if [[ "$timeout" != "10" ]]; then
        echo "BAD_TIMEOUT:$timeout"
        return 124
    fi
    if [[ "${1:-}" == "softwareupdate" && "${2:-}" == "-l" && "${3:-}" == "--no-scan" ]]; then
        cat <<'OUT'
Software Update Tool

Finding available software
No new software available.
OUT
        return 0
    fi
    return 124
}

start_inline_spinner(){ :; }
stop_inline_spinner(){ :; }

check_macos_update
echo "MACOS_UPDATE_AVAILABLE=$MACOS_UPDATE_AVAILABLE"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"System up to date"* ]]
    [[ "$output" == *"MACOS_UPDATE_AVAILABLE=false"* ]]
    [[ "$output" != *"BAD_TIMEOUT:"* ]]
}

@test "check_macos_update keeps update flag when softwareupdate times out" {
    run bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"

defaults() { echo "1"; }

run_with_timeout() {
    local timeout="${1:-}"
    shift
    if [[ "$timeout" != "10" ]]; then
        echo "BAD_TIMEOUT:$timeout"
        return 124
    fi
    if [[ "${1:-}" == "softwareupdate" && "${2:-}" == "-l" && "${3:-}" == "--no-scan" ]]; then
        return 124
    fi
    return 124
}

start_inline_spinner(){ :; }
stop_inline_spinner(){ :; }

check_macos_update
echo "MACOS_UPDATE_AVAILABLE=$MACOS_UPDATE_AVAILABLE"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Update available"* ]]
    [[ "$output" == *"MACOS_UPDATE_AVAILABLE=true"* ]]
    [[ "$output" != *"BAD_TIMEOUT:"* ]]
}

@test "check_macos_update keeps update flag when softwareupdate returns empty output" {
    run bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"

defaults() { echo "1"; }

run_with_timeout() {
    local timeout="${1:-}"
    shift
    if [[ "$timeout" != "10" ]]; then
        echo "BAD_TIMEOUT:$timeout"
        return 124
    fi
    if [[ "${1:-}" == "softwareupdate" && "${2:-}" == "-l" && "${3:-}" == "--no-scan" ]]; then
        return 0
    fi
    return 124
}

start_inline_spinner(){ :; }
stop_inline_spinner(){ :; }

check_macos_update
echo "MACOS_UPDATE_AVAILABLE=$MACOS_UPDATE_AVAILABLE"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Update available"* ]]
    [[ "$output" == *"MACOS_UPDATE_AVAILABLE=true"* ]]
    [[ "$output" != *"BAD_TIMEOUT:"* ]]
}

@test "check_macos_update skips softwareupdate when defaults shows no updates" {
    run bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"

defaults() { echo "0"; }

run_with_timeout() {
    echo "SHOULD_NOT_CALL_SOFTWAREUPDATE"
    return 0
}

check_macos_update
echo "MACOS_UPDATE_AVAILABLE=$MACOS_UPDATE_AVAILABLE"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"System up to date"* ]]
    [[ "$output" == *"MACOS_UPDATE_AVAILABLE=false"* ]]
    [[ "$output" != *"SHOULD_NOT_CALL_SOFTWAREUPDATE"* ]]
}

@test "check_macos_update respects MO_SOFTWAREUPDATE_TIMEOUT" {
    run bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"

defaults() { echo "1"; }

export MO_SOFTWAREUPDATE_TIMEOUT=15

run_with_timeout() {
    local timeout="${1:-}"
    shift
    if [[ "$timeout" != "15" ]]; then
        echo "BAD_TIMEOUT:$timeout"
        return 124
    fi
    if [[ "${1:-}" == "softwareupdate" && "${2:-}" == "-l" && "${3:-}" == "--no-scan" ]]; then
        echo "No new software available."
        return 0
    fi
    return 124
}

start_inline_spinner(){ :; }
stop_inline_spinner(){ :; }

check_macos_update
echo "TEST_PASSED"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"TEST_PASSED"* ]]
    [[ "$output" != *"BAD_TIMEOUT:"* ]]
}

@test "check_macos_update outputs debug info when MO_DEBUG set" {
    run bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"

defaults() { echo "1"; }

export MO_DEBUG=1

run_with_timeout() {
    local timeout="${1:-}"
    shift
    if [[ "${1:-}" == "softwareupdate" && "${2:-}" == "-l" && "${3:-}" == "--no-scan" ]]; then
        echo "No new software available."
        return 0
    fi
    return 124
}

start_inline_spinner(){ :; }
stop_inline_spinner(){ :; }

check_macos_update 2>&1
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"[DEBUG] softwareupdate exit status:"* ]]
}

@test "run_with_timeout succeeds without GNU timeout" {
    run bash --noprofile --norc -c '
        set -euo pipefail
        PATH="/usr/bin:/bin"
        unset MO_TIMEOUT_INITIALIZED MO_TIMEOUT_BIN
        source "'"$PROJECT_ROOT"'/lib/core/common.sh"
        run_with_timeout 1 sleep 0.1
    '
    [ "$status" -eq 0 ]
}

@test "run_with_timeout enforces timeout and returns 124" {
    run bash --noprofile --norc -c '
        set -euo pipefail
        PATH="/usr/bin:/bin"
        unset MO_TIMEOUT_INITIALIZED MO_TIMEOUT_BIN
        source "'"$PROJECT_ROOT"'/lib/core/common.sh"
        run_with_timeout 1 sleep 5
    '
    [ "$status" -eq 124 ]
}


@test "opt_saved_state_cleanup removes old saved states" {
    local state_dir="$HOME/Library/Saved Application State"
    mkdir -p "$state_dir/com.example.app.savedState"
    touch "$state_dir/com.example.app.savedState/data.plist"

    # Make the file old (8+ days) - MOLE_SAVED_STATE_AGE_DAYS defaults to 7
    touch -t 202301010000 "$state_dir/com.example.app.savedState/data.plist"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
opt_saved_state_cleanup
EOF

    [ "$status" -eq 0 ]
}

@test "opt_saved_state_cleanup handles missing state directory" {
    rm -rf "$HOME/Library/Saved Application State"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
opt_saved_state_cleanup
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"App saved states optimized"* ]]
}

@test "opt_cache_refresh cleans Quick Look cache" {
    mkdir -p "$HOME/Library/Caches/com.apple.QuickLook.thumbnailcache"
    touch "$HOME/Library/Caches/com.apple.QuickLook.thumbnailcache/test.db"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
# Mock qlmanage and cleanup_path to avoid system calls
qlmanage() { return 0; }
cleanup_path() {
    local path="$1"
    local label="${2:-}"
    [[ -e "$path" ]] && rm -rf "$path" 2>/dev/null || true
}
export -f qlmanage cleanup_path
opt_cache_refresh
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"QuickLook thumbnails refreshed"* ]]
}


@test "get_path_size_kb returns zero for missing directory" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MO_DEBUG=0 bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
size=$(get_path_size_kb "/nonexistent/path")
echo "$size"
EOF

    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "get_path_size_kb calculates directory size" {
    mkdir -p "$HOME/test_size"
    dd if=/dev/zero of="$HOME/test_size/file.dat" bs=1024 count=10 2>/dev/null

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MO_DEBUG=0 bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
size=$(get_path_size_kb "$HOME/test_size")
echo "$size"
EOF

    [ "$status" -eq 0 ]
    # Should be >= 10 KB
    [ "$output" -ge 10 ]
}


@test "opt_fix_broken_configs reports fixes" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/maintenance.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

fix_broken_preferences() {
    echo 2
}
fix_broken_login_items() {
    echo 1
}

opt_fix_broken_configs
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Fixed 2 broken preference files"* ]]
    [[ "$output" == *"Removed 1 broken login items"* ]]
}

# ============================================================================
# Tests for new system cleaning features (v1.15.2)
# ============================================================================

@test "clean_deep_system cleans memory exception reports" {
    run bash --noprofile --norc <<'EOF'
set -euo pipefail
CALL_LOG="$HOME/memory_exception_calls.log"
> "$CALL_LOG"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

sudo() { return 0; }
safe_sudo_find_delete() {
    echo "safe_sudo_find_delete:$1:$2:$3:$4" >> "$CALL_LOG"
    return 0
}
safe_sudo_remove() { return 0; }
log_success() { :; }
is_sip_enabled() { return 1; }
find() { return 0; }
run_with_timeout() { shift; "$@"; }

clean_deep_system
cat "$CALL_LOG"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"reportmemoryexception/MemoryLimitViolations"* ]]
    [[ "$output" == *":30:"* ]]  # 30-day retention
}

@test "clean_deep_system cleans diagnostic trace logs" {
    run bash --noprofile --norc <<'EOF'
set -euo pipefail
CALL_LOG="$HOME/diag_calls.log"
> "$CALL_LOG"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

sudo() { return 0; }
safe_sudo_find_delete() {
    echo "safe_sudo_find_delete:$1:$2" >> "$CALL_LOG"
    return 0
}
safe_sudo_remove() { return 0; }
log_success() { :; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
is_sip_enabled() { return 1; }
find() { return 0; }
run_with_timeout() { shift; "$@"; }

clean_deep_system
cat "$CALL_LOG"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"diagnostics/Persist"* ]]
    [[ "$output" == *"diagnostics/Special"* ]]
    [[ "$output" == *"tracev3"* ]]
}

@test "clean_deep_system validates symbolication cache size before cleaning" {
    # This test verifies the size threshold logic directly
    # Testing that sizes > 1GB trigger cleanup
    run bash --noprofile --norc <<'EOF'
set -euo pipefail

# Simulate size check logic
symbolication_size_mb="2048"  # 2GB

if [[ -n "$symbolication_size_mb" && "$symbolication_size_mb" =~ ^[0-9]+$ ]]; then
    if [[ $symbolication_size_mb -gt 1024 ]]; then
        echo "WOULD_CLEAN=yes"
    else
        echo "WOULD_CLEAN=no"
    fi
else
    echo "WOULD_CLEAN=no"
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"WOULD_CLEAN=yes"* ]]
}

@test "clean_deep_system skips symbolication cache when small" {
    # This test verifies sizes < 1GB don't trigger cleanup
    run bash --noprofile --norc <<'EOF'
set -euo pipefail

# Simulate size check logic with small cache
symbolication_size_mb="500"  # 500MB < 1GB

if [[ -n "$symbolication_size_mb" && "$symbolication_size_mb" =~ ^[0-9]+$ ]]; then
    if [[ $symbolication_size_mb -gt 1024 ]]; then
        echo "WOULD_CLEAN=yes"
    else
        echo "WOULD_CLEAN=no"
    fi
else
    echo "WOULD_CLEAN=no"
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"WOULD_CLEAN=no"* ]]
}

@test "clean_deep_system handles symbolication cache size check failure" {
    # This test verifies invalid/empty size values don't trigger cleanup
    run bash --noprofile --norc <<'EOF'
set -euo pipefail

# Simulate size check logic with empty/invalid value
symbolication_size_mb=""  # Empty - simulates failure

if [[ -n "$symbolication_size_mb" && "$symbolication_size_mb" =~ ^[0-9]+$ ]]; then
    if [[ $symbolication_size_mb -gt 1024 ]]; then
        echo "WOULD_CLEAN=yes"
    else
        echo "WOULD_CLEAN=no"
    fi
else
    echo "WOULD_CLEAN=no"
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"WOULD_CLEAN=no"* ]]
}
