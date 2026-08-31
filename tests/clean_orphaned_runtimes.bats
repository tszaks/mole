#!/usr/bin/env bats
# Orphaned simulator runtime detection: report a runtime no device uses,
# stay silent on in-use runtimes, and never delete anything.

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
}

# $1 = runtime list output, $2 = device list output
run_check() {
    run env PROJECT_ROOT="$PROJECT_ROOT" RT_OUT="$1" DEV_OUT="$2" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
_MOLE_SIMCTL_RESOLUTION_STATUS=ready
_MOLE_SIMCTL_DEVELOPER_DIR=/fake
note_activity() { :; }
run_with_timeout() {
    shift
    case "$*" in
        *"runtime list"*) printf '%s\n' "$RT_OUT" ;;
        *"list devices"*) printf '%s\n' "$DEV_OUT" ;;
    esac
}
check_orphaned_simulator_runtimes
EOF
}

RUNTIMES='== Disk Images ==
-- iOS --
iOS 18.4 (22E238) - 70DF9A83-C8CF-458E-B463-356D557B8D2D (Ready)
    Mount Path: /Library/Developer/CoreSimulator/Volumes/iOS_22E238
    Size: 8.2G
iOS 26.5 (23F77) - 78F2282D-7AC8-4DA3-B482-9E21FFBD5841 (Ready)
    Size: 7.9G'

@test "reports a runtime with zero devices and names the owner command" {
    run_check "$RUNTIMES" '-- iOS 18.4 --
-- iOS 26.5 --
    iPhone 17 Pro (E4FC6A8A-563B-4027-B246-242D123EB40B) (Booted)'

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Orphaned simulator runtime"* ]] || return 1
    [[ "$output" == *"iOS 18.4"* ]] || return 1
    [[ "$output" == *"8.2G"* ]] || return 1
    [[ "$output" == *"runtime delete 70DF9A83-C8CF-458E-B463-356D557B8D2D"* ]] || return 1
    # The in-use runtime must never be named.
    [[ "$output" != *"iOS 26.5"* ]] || { echo "$output"; return 1; }
}

@test "silent when every runtime has at least one device" {
    run_check "$RUNTIMES" '-- iOS 18.4 --
    iPhone 16 Pro (C1237C27-E6A1-4553-9117-65FAE480A347) (Shutdown)
-- iOS 26.5 --
    iPhone 17 Pro (E4FC6A8A-563B-4027-B246-242D123EB40B) (Booted)'

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" != *"Orphaned"* ]] || { echo "$output"; return 1; }
}

@test "reports every orphan when more than one runtime is unused" {
    run_check "$RUNTIMES" '-- iOS 18.4 --
-- iOS 26.5 --'

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"iOS 18.4"* ]] || return 1
    [[ "$output" == *"iOS 26.5"* ]] || return 1
}

@test "a runtime with no reported size still reports as an orphan" {
    run_check 'iOS 18.4 (22E238) - 70DF9A83-C8CF-458E-B463-356D557B8D2D (Ready)' \
        '-- iOS 18.4 --'

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"iOS 18.4 · no devices"* ]] || { echo "$output"; return 1; }
}

@test "probe timeout propagates instead of reporting a false clean" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
_MOLE_SIMCTL_RESOLUTION_STATUS=ready
_MOLE_SIMCTL_DEVELOPER_DIR=/fake
note_activity() { :; }
run_with_timeout() { return 124; }
check_orphaned_simulator_runtimes
EOF
    [ "$status" -eq 124 ] || { echo "status=$status $output"; return 1; }
    [[ "$output" != *"Orphaned"* ]] || return 1
}

@test "no-op when simctl was never resolved" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
_MOLE_SIMCTL_RESOLUTION_STATUS=clt-only
run_with_timeout() { echo "PROBED"; }
check_orphaned_simulator_runtimes
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" != *"PROBED"* ]] || { echo "$output"; return 1; }
}
