#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
}

setup() {
    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-launch-services-home.XXXXXX")"
    TEST_ROOT="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-launch-services-case.XXXXXX")"
    export HOME TEST_ROOT
}

teardown() {
    case "${HOME:-}" in
        "${BATS_TEST_DIRNAME}/tmp-launch-services-home."*) rm -rf "$HOME" ;;
    esac
    case "${TEST_ROOT:-}" in
        "${BATS_TEST_DIRNAME}/tmp-launch-services-case."*) rm -rf "$TEST_ROOT" ;;
    esac
}

write_lsregister_stub() {
    local bin_path="$1"
    mkdir -p "$(dirname "$bin_path")"
    cat > "$bin_path" <<'SCRIPT'
#!/usr/bin/env bash
{
    printf 'argc=%s\n' "$#"
    for arg in "$@"; do
        printf 'arg=%s\n' "$arg"
    done
} >> "$LSREGISTER_LOG"

case "${1:-}" in
    -dump)
        cat "$LSREGISTER_DUMP"
        exit 0
        ;;
    -u)
        exit 0
        ;;
esac
exit 2
SCRIPT
    chmod +x "$bin_path"
}

@test "clean_stale_launch_services_registrations dry-run reports missing apps without unregistering" {
    local lsregister="$TEST_ROOT/bin/lsregister"
    local dump_file="$TEST_ROOT/lsregister.dump"
    local log_file="$TEST_ROOT/lsregister.log"
    local missing_app="$TEST_ROOT/Missing App.app"
    local unrelated_missing_app="$TEST_ROOT/Unrelated Missing.app"
    local existing_app="$TEST_ROOT/Existing.app"
    mkdir -p "$existing_app"
    write_lsregister_stub "$lsregister"

    cat > "$dump_file" <<DUMP
bundle id: 0
    path: $unrelated_missing_app
bundle id: 1
    path: $missing_app
    Bundle node not found on disk

bundle id: 2
    path: $existing_app
    Bundle node not found on disk

bundle id: 3
    path: $TEST_ROOT/Missing.txt
    Bundle node not found on disk
DUMP
    : > "$log_file"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" LSREGISTER_BIN="$lsregister" LSREGISTER_DUMP="$dump_file" LSREGISTER_LOG="$log_file" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/launch_services.sh"
get_lsregister_path() { printf '%s\n' "$LSREGISTER_BIN"; }
run_with_timeout() { shift; "$@"; }
note_activity() { printf 'activity\n'; }
DRY_RUN=true
clean_stale_launch_services_registrations
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"LaunchServices stale app registrations"* ]] || return 1
    [[ "$output" == *"would unregister 1"* ]] || return 1
    [[ "$output" == *"Missing App.app"* ]] || return 1
    grep -q 'arg=-dump' "$log_file"
    if grep -q 'arg=-u' "$log_file"; then
        return 1
    fi
}

@test "clean_stale_launch_services_registrations unregisters only targeted missing app records" {
    local lsregister="$TEST_ROOT/bin/lsregister"
    local dump_file="$TEST_ROOT/lsregister.dump"
    local log_file="$TEST_ROOT/lsregister.log"
    local missing_app="$TEST_ROOT/Missing App.app"
    local unrelated_missing_app="$TEST_ROOT/Unrelated Missing.app"
    local existing_app="$TEST_ROOT/Existing.app"
    mkdir -p "$existing_app"
    write_lsregister_stub "$lsregister"

    cat > "$dump_file" <<DUMP
bundle id: 0
    path: $unrelated_missing_app
bundle id: 1
    path: $missing_app
    Bundle node not found on disk

bundle id: 2
    path: $existing_app
    Bundle node not found on disk

bundle id: 3
    path: /System/Applications/Missing.app
    Bundle node not found on disk
DUMP
    : > "$log_file"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" LSREGISTER_BIN="$lsregister" LSREGISTER_DUMP="$dump_file" LSREGISTER_LOG="$log_file" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/launch_services.sh"
get_lsregister_path() { printf '%s\n' "$LSREGISTER_BIN"; }
run_with_timeout() { shift; "$@"; }
note_activity() { printf 'activity\n'; }
DRY_RUN=false
MOLE_DRY_RUN=0
clean_stale_launch_services_registrations
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"LaunchServices stale app registrations, 1 removed"* ]] || return 1
    grep -q 'arg=-dump' "$log_file"
    grep -q 'argc=2' "$log_file"
    grep -q 'arg=-u' "$log_file"
    grep -q "arg=$missing_app" "$log_file"
    if grep -q "arg=$existing_app" "$log_file"; then
        return 1
    fi
    if grep -q "arg=$unrelated_missing_app" "$log_file"; then
        return 1
    fi
    if grep -q 'arg=-r' "$log_file" || grep -q 'arg=-f' "$log_file"; then
        return 1
    fi
}

@test "launch_services_stale_app_path_is_safe rejects unsafe, live, and malformed paths" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TEST_ROOT="$TEST_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/launch_services.sh"

fail=0
expect_reject() {
    if launch_services_stale_app_path_is_safe "$1"; then
        printf 'UNEXPECTED_ACCEPT: %q\n' "$1"
        fail=1
    fi
}
expect_accept() {
    if ! launch_services_stale_app_path_is_safe "$1"; then
        printf 'UNEXPECTED_REJECT: %q\n' "$1"
        fail=1
    fi
}

# Genuinely missing, absolute, .app bundle is the only case that may unregister.
expect_accept "$TEST_ROOT/Gone.app"

# A live bundle on disk must never be unregistered.
mkdir -p "$TEST_ROOT/Live.app"
expect_reject "$TEST_ROOT/Live.app"

# Format, protected-root, traversal, and injection rejections.
expect_reject ""
expect_reject "relative/Path.app"
expect_reject "$TEST_ROOT/NotAnApp"
expect_reject "/System/Applications/Gone.app"
expect_reject "/Library/Apple/Gone.app"
expect_reject "$TEST_ROOT/../Gone.app"
expect_reject "$(printf '/tmp/Bad\nName.app')"
expect_reject "$(printf '/tmp/Bad\rName.app')"

exit $fail
EOF

    [ "$status" -eq 0 ]
}

@test "clean_stale_launch_services_registrations ignores dump failures" {
    local lsregister="$TEST_ROOT/bin/lsregister"
    local log_file="$TEST_ROOT/lsregister.log"
    mkdir -p "$(dirname "$lsregister")"
    # Hard-failing dump: the shared stub always exits 0 after cat, which would
    # look like an empty-but-successful scan. Issue #1395 needs the empty
    # failure path to stay fail-soft and say disk cleanup is unaffected.
    cat > "$lsregister" <<'SCRIPT'
#!/usr/bin/env bash
{
    printf 'argc=%s\n' "$#"
    for arg in "$@"; do
        printf 'arg=%s\n' "$arg"
    done
} >> "$LSREGISTER_LOG"
case "${1:-}" in
    -dump) exit 1 ;;
    -u) exit 0 ;;
esac
exit 2
SCRIPT
    chmod +x "$lsregister"
    : > "$log_file"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" LSREGISTER_BIN="$lsregister" \
        LSREGISTER_LOG="$log_file" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/launch_services.sh"
get_lsregister_path() { printf '%s\n' "$LSREGISTER_BIN"; }
run_with_timeout() { shift; "$@"; }
note_activity() { printf 'activity\n'; }
DRY_RUN=false
clean_stale_launch_services_registrations
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"scan skipped (disk cleanup unaffected)"* ]] || return 1
    [[ "$output" != *"removed"* ]] || return 1
    grep -q 'arg=-dump' "$log_file"
}

@test "a fresh stale-scan cache is consumed without a second lsregister dump" {
    local lsregister="$TEST_ROOT/bin/lsregister"
    local log_file="$TEST_ROOT/lsregister.log"
    local missing_app="$TEST_ROOT/Missing App.app"
    write_lsregister_stub "$lsregister"
    mkdir -p "$HOME/.cache/mole"
    printf '%s\n' "$missing_app" > "$HOME/.cache/mole/ls_stale_candidates"
    : > "$log_file"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" LSREGISTER_BIN="$lsregister" \
        LSREGISTER_LOG="$log_file" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/launch_services.sh"
get_lsregister_path() { printf '%s\n' "$LSREGISTER_BIN"; }
run_with_timeout() { shift; "$@"; }
note_activity() { :; }
DRY_RUN=true
clean_stale_launch_services_registrations
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"Missing App.app"* ]] || return 1
    # The whole point of the cache: no second dump at section time.
    if grep -q 'arg=-dump' "$log_file"; then
        echo "second dump ran despite fresh cache"
        return 1
    fi
}

@test "no fresh cache and a finished prefetch skip the section quietly" {
    local lsregister="$TEST_ROOT/bin/lsregister"
    local log_file="$TEST_ROOT/lsregister.log"
    write_lsregister_stub "$lsregister"
    : > "$log_file"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" LSREGISTER_BIN="$lsregister" \
        LSREGISTER_LOG="$log_file" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/launch_services.sh"
get_lsregister_path() { printf '%s\n' "$LSREGISTER_BIN"; }
run_with_timeout() { shift; "$@"; }
note_activity() { :; }
debug_log() { printf 'DEBUG:%s\n' "$*"; }
DRY_RUN=true
MOLE_LS_PREFETCH_PID=99999
clean_stale_launch_services_registrations
echo "RC=$?"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"no fresh result yet, skipping this run"* ]] || return 1
    [[ "$output" == *"deferred to next clean"* ]] || return 1
    [[ "$output" == *"RC=0"* ]] || return 1
    if grep -q 'arg=-dump' "$log_file"; then
        echo "fell back to an inline dump"
        return 1
    fi
}

@test "an expired stale-scan cache is not consumed" {
    local lsregister="$TEST_ROOT/bin/lsregister"
    local log_file="$TEST_ROOT/lsregister.log"
    local missing_app="$TEST_ROOT/Missing App.app"
    write_lsregister_stub "$lsregister"
    mkdir -p "$HOME/.cache/mole"
    printf '%s\n' "$missing_app" > "$HOME/.cache/mole/ls_stale_candidates"
    touch -t 202001010000 "$HOME/.cache/mole/ls_stale_candidates"
    : > "$log_file"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" LSREGISTER_BIN="$lsregister" \
        LSREGISTER_LOG="$log_file" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/launch_services.sh"
get_lsregister_path() { printf '%s\n' "$LSREGISTER_BIN"; }
run_with_timeout() { shift; "$@"; }
note_activity() { :; }
debug_log() { printf 'DEBUG:%s\n' "$*"; }
DRY_RUN=true
MOLE_LS_PREFETCH_PID=99999
clean_stale_launch_services_registrations
echo "RC=$?"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"no fresh result yet, skipping this run"* ]] || return 1
    [[ "$output" == *"deferred to next clean"* ]] || return 1
    [[ "$output" != *"Missing App.app"* ]] || return 1
}

@test "collect_stale fails soft and keeps partial candidates when the dump is killed" {
    # A large macOS 26 LaunchServices DB often exceeds the bound; killing
    # lsregister mid-dump must not throw away the paths already parsed.
    local lsregister="$TEST_ROOT/bin/lsregister"
    local dump_file="$TEST_ROOT/lsregister.dump"
    local log_file="$TEST_ROOT/lsregister.log"
    local missing_app="$TEST_ROOT/Partial Missing.app"
    mkdir -p "$(dirname "$lsregister")"
    cat > "$lsregister" <<'SCRIPT'
#!/usr/bin/env bash
{
    printf 'argc=%s\n' "$#"
    for arg in "$@"; do
        printf 'arg=%s\n' "$arg"
    done
} >> "$LSREGISTER_LOG"
case "${1:-}" in
    -dump)
        cat "$LSREGISTER_DUMP"
        # Non-zero exit simulates run_with_timeout killing a slow dump.
        exit 124
        ;;
esac
exit 2
SCRIPT
    chmod +x "$lsregister"
    cat > "$dump_file" <<DUMP
bundle id: 1
    path: $missing_app
    Bundle node not found on disk

DUMP
    : > "$log_file"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" LSREGISTER_BIN="$lsregister" \
        LSREGISTER_DUMP="$dump_file" LSREGISTER_LOG="$log_file" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/launch_services.sh"
get_lsregister_path() { printf '%s\n' "$LSREGISTER_BIN"; }
# Pass the stub through so its own non-zero dump status reaches the pipeline.
run_with_timeout() { shift; "$@"; }
note_activity() { :; }
DRY_RUN=true
clean_stale_launch_services_registrations
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"Partial Missing.app"* ]] || return 1
    [[ "$output" == *"would unregister"* ]] || return 1
    [[ "$output" != *"scan skipped"* ]] || return 1
}

@test "the dump parser survives invalid UTF-8 in a record line" {
    # Invalid UTF-8 under a UTF-8 locale previously aborted awk mid-stream
    # ("towc: multibyte conversion failure") and zeroed the whole scan.
    local dump_file="$TEST_ROOT/bad-utf8.dump"
    local missing_app="$TEST_ROOT/After Bad Bytes.app"
    {
        printf 'bundle id: 0\n'
        # 0xFF is never valid UTF-8; the marker and path stay ASCII.
        printf '\tpath: /tmp/bad'
        printf '\xff'
        printf 'name.app\n'
        printf '\tBundle node not found on disk\n\n'
        printf 'bundle id: 1\n'
        printf '\tpath: %s\n' "$missing_app"
        printf '\tBundle node not found on disk\n\n'
    } > "$dump_file"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" BIG_DUMP="$dump_file" \
        MISSING_APP="$missing_app" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/launch_services.sh"
paths=$(launch_services_emit_missing_record_paths < "$BIG_DUMP")
printf 'PATHS:\n%s\n' "$paths"
printf '%s\n' "$paths" | grep -Fqx "$MISSING_APP"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "the dump parser handles a quarter-million-line dump in seconds" {
    # The original per-line command substitution forked once per dump line
    # and turned a 2s lsregister dump into minutes of parsing, which is why
    # the scan timed out on every run of a real machine (250k lines there).
    # One awk pass must chew a comparable dump well inside the old 10s scan
    # bound; the generous ceiling below only guards against a regression
    # back to per-line forking, not against scheduler noise.
    local big_dump="$TEST_ROOT/big.dump"
    awk 'BEGIN {
        for (i = 0; i < 50000; i++) {
            printf "bundle id: %d\n", i
            printf "\tpath: /Applications/Missing%d.app (0x%x)\n", i, i
            if (i % 50 == 0) printf "\tBundle node not found on disk\n"
            printf "\n"
        }
    }' > "$big_dump"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" BIG_DUMP="$big_dump" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/launch_services.sh"
started=$SECONDS
count=$(launch_services_emit_missing_record_paths < "$BIG_DUMP" | wc -l | tr -d ' ')
printf 'COUNT=%s ELAPSED=%s\n' "$count" "$((SECONDS - started))"
[ "$((SECONDS - started))" -lt 30 ]
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"COUNT=1000 "* ]] || return 1
}
