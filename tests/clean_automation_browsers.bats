#!/usr/bin/env bats
# Leaked automation-browser cleanup: only automation-profile processes are
# touched, dry-run never kills, and in-use profiles are never deleted.

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-automation-browsers.XXXXXX")"
    export HOME
    mkdir -p "$HOME"
}

teardown_file() {
    if [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        rm -rf "$HOME"
    fi
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

# Stub binaries: ps emits one orphaned cliDaemon (ppid 1), one day-old Chrome
# on an automation profile, one FRESH Chrome on an automation profile (must
# survive), and one unrelated browser (must survive). getconf points the
# profile scan at the test temp root.
make_process_stubs() {
    mkdir -p "$HOME/bin" "$HOME/tmproot"
    cat > "$HOME/bin/ps" <<'SCRIPT'
#!/bin/bash
printf '%s\n' \
    '  901     1 02-01:00:00 /opt/homebrew/bin/node playwright-core/lib/entry/cliDaemon.js daemon' \
    '  902   901 01-20:00:00 /Applications/Chrome.app/x --user-data-dir=/tmp/playwright_chromiumdev_profile-old' \
    '  903   901    05:00 /Applications/Chrome.app/x --user-data-dir=/tmp/playwright_chromiumdev_profile-new' \
    '  904     1 03-01:00:00 /Applications/Safari.app/Contents/MacOS/Safari'
SCRIPT
    cat > "$HOME/bin/getconf" <<SCRIPT
#!/bin/bash
printf '%s/\n' "$HOME/tmproot"
SCRIPT
    cat > "$HOME/bin/pgrep" <<'SCRIPT'
#!/bin/bash
# Simulate: only the "live" profile has a process still referencing it.
for arg in "$@"; do
    [[ "$arg" == *"profile-live"* ]] && exit 0
done
exit 1
SCRIPT
    chmod +x "$HOME/bin/ps" "$HOME/bin/getconf" "$HOME/bin/pgrep"
}

run_cleanup() {
    local dry_run="$1"
    run env HOME="$HOME" PATH="$HOME/bin:/usr/bin:/bin" PROJECT_ROOT="$PROJECT_ROOT" \
        DRY="$dry_run" TRACE="$HOME/kill.trace" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN="$DRY"
kill() { printf 'KILL %s\n' "$*" >> "$TRACE"; return 0; }
sleep() { :; }
safe_clean() {
    local -a paths=("$@")
    local label="${paths[${#paths[@]} - 1]}"
    unset 'paths[${#paths[@]}-1]'
    local p
    for p in "${paths[@]}"; do
        printf 'SAFE_CLEAN %s (%s)\n' "$p" "$label"
    done
}
note_activity() { :; }
clean_dev_automation_browsers
EOF
}

@test "kills only orphaned daemons and day-old automation browsers" {
    make_process_stubs
    : > "$HOME/kill.trace"

    run_cleanup false
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"stopped 2 processes"* ]] || { echo "$output"; return 1; }
    grep -q 'KILL -TERM 901' "$HOME/kill.trace" || return 1
    grep -q 'KILL -TERM 902' "$HOME/kill.trace" || return 1
    # Fresh automation session and the unrelated browser are never signaled.
    ! grep -q ' 903' "$HOME/kill.trace" || return 1
    ! grep -q ' 904' "$HOME/kill.trace" || return 1
}

@test "dry run reports but never signals a process" {
    make_process_stubs
    : > "$HOME/kill.trace"

    run_cleanup true
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"would stop 2 processes"* ]] || { echo "$output"; return 1; }
    [ ! -s "$HOME/kill.trace" ] || { cat "$HOME/kill.trace"; return 1; }
}

@test "stale profiles are cleaned, in-use and fresh profiles survive" {
    make_process_stubs
    : > "$HOME/kill.trace"

    mkdir -p "$HOME/tmproot/playwright_chromiumdev_profile-stale" \
        "$HOME/tmproot/playwright_chromiumdev_profile-live" \
        "$HOME/tmproot/playwright_chromiumdev_profile-fresh"
    # Age the stale and live dirs well past the 2h threshold.
    touch -t 202601010000 "$HOME/tmproot/playwright_chromiumdev_profile-stale"
    touch -t 202601010000 "$HOME/tmproot/playwright_chromiumdev_profile-live"

    run_cleanup false
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"SAFE_CLEAN"*"profile-stale"* ]] || { echo "$output"; return 1; }
    # In-use profile (pgrep hit) and fresh profile (under 2h) stay.
    [[ "$output" != *"SAFE_CLEAN"*"profile-live"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"SAFE_CLEAN"*"profile-fresh"* ]] || { echo "$output"; return 1; }
}

@test "quiet no-op when nothing leaked" {
    mkdir -p "$HOME/bin" "$HOME/tmproot-empty"
    cat > "$HOME/bin/ps" <<'SCRIPT'
#!/bin/bash
printf '%s\n' '  904     1 03-01:00:00 /Applications/Safari.app/Contents/MacOS/Safari'
SCRIPT
    cat > "$HOME/bin/getconf" <<SCRIPT
#!/bin/bash
printf '%s/\n' "$HOME/tmproot-empty"
SCRIPT
    chmod +x "$HOME/bin/ps" "$HOME/bin/getconf"

    run_cleanup false
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" != *"stopped"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"SAFE_CLEAN"* ]] || { echo "$output"; return 1; }
}
