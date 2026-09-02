#!/usr/bin/env bats
# Memory pressure, idle-VM, and runaway-process diagnosis.
# All three are read-only and must stay silent on a healthy machine.

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
}

# ---------- time parsing ----------

@test "time_to_seconds handles mm:ss, hh:mm:ss and dd-hh:mm:ss" {
    run /bin/bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/optimize/diagnostics.sh'
        opt_diag_time_to_seconds '01:30'
        opt_diag_time_to_seconds '02:00:00'
        opt_diag_time_to_seconds '16-08:00:00'
    "
    [ "$status" -eq 0 ]
    [ "${lines[0]}" -eq 90 ]
    [ "${lines[1]}" -eq 7200 ]
    [ "${lines[2]}" -eq 1411200 ]
}

@test "time_to_seconds returns 0 on garbage so it cannot fake a runaway" {
    run /bin/bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/optimize/diagnostics.sh'
        opt_diag_time_to_seconds 'not-a-time'
        opt_diag_time_to_seconds ''
        opt_diag_time_to_seconds '1:2:3:4'
    "
    [ "$status" -eq 0 ]
    [ "${lines[0]}" -eq 0 ]
    [ "${lines[1]}" -eq 0 ]
    [ "${lines[2]}" -eq 0 ]
}

# ---------- memory pressure ----------

@test "memory pressure stays silent when swap is healthy" {
    run /bin/bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/optimize/diagnostics.sh'
        sysctl() { echo 'total = 8192.00M  used = 100.00M  free = 8092.00M'; }
        memory_pressure() { echo 'System-wide memory free percentage: 80%'; }
        out=\$(opt_diag_memory_pressure)
        [ -z \"\$out\" ] && echo SILENT || echo \"LEAKED: \$out\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"SILENT"* ]] || { echo "$output"; return 1; }
}

@test "memory pressure fires on exhausted swap and names the holders" {
    run /bin/bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/optimize/diagnostics.sh'
        sysctl() { echo 'total = 16384.00M  used = 15500.00M  free = 884.00M'; }
        memory_pressure() { echo 'System-wide memory free percentage: 8%'; }
        ps() { printf '%s\n' '   RSS COMM' '8600000 com.apple.Virtualization.VirtualMachine' '2000000 /usr/local/bin/codex' '500 tiny'; }
        opt_diag_memory_pressure
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"Memory pressure"* ]] || return 1
    [[ "$output" == *"94%"* ]] || { echo "$output"; return 1; }
    # The largest process must appear — a header-vs-sort bug once dropped it.
    [[ "$output" == *"VirtualMachine"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"8.2 GB"* ]] || { echo "$output"; return 1; }
    # Basename only, and sub-1GB noise excluded.
    [[ "$output" != *"/usr/local/bin/codex"* ]] || return 1
    [[ "$output" != *"tiny"* ]] || return 1
    # The ps header must never render as a process.
    [[ "$output" != *"COMM"* ]] || { echo "$output"; return 1; }
}

# ---------- idle VM ----------

@test "idle VM reports reclaimable memory when no containers run" {
    run /bin/bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/optimize/diagnostics.sh'
        ps() { printf '%s\n' '   RSS COMMAND' '8600000 /System/Library/Frameworks/Virtualization.framework/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine'; }
        docker() { :; }
        run_with_timeout() { shift; printf ''; }
        opt_diag_idle_vm
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"8.2GB"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"no running containers"* ]] || { echo "$output"; return 1; }
}

@test "idle VM does NOT claim reclaimable when containers are running" {
    run /bin/bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/optimize/diagnostics.sh'
        ps() { printf '%s\n' '   RSS COMMAND' '8600000 Virtualization.framework/x/com.apple.Virtualization.VirtualMachine'; }
        docker() { :; }
        run_with_timeout() { shift; printf '%s\n' abc123 def456; }
        opt_diag_idle_vm
    "
    [ "$status" -eq 0 ]
    [[ "$output" != *"no running containers"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"2 containers running"* ]] || { echo "$output"; return 1; }
}

@test "idle VM silent when no VM is present" {
    run /bin/bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/optimize/diagnostics.sh'
        ps() { printf '%s\n' '   RSS COMMAND' '100 Finder'; }
        out=\$(opt_diag_idle_vm)
        [ -z \"\$out\" ] && echo SILENT || echo \"LEAKED: \$out\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"SILENT"* ]] || { echo "$output"; return 1; }
}

# ---------- runaway process ----------

@test "runaway fires on a long-lived process pinning a core" {
    # ControlCenter's real shape: 138h CPU across 16 days of uptime.
    run /bin/bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/optimize/diagnostics.sh'
        ps() { printf '%s\n' 'PID TIME ELAPSED COMM' '785 138:00:00 16-08:00:00 /System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter'; }
        opt_diag_runaway_process
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"ControlCenter"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"138h"* ]] || return 1
    [[ "$output" == *"kill -TERM 785"* ]] || return 1
}

@test "runaway ignores a brief spike and short-lived processes" {
    run /bin/bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/optimize/diagnostics.sh'
        # 100% of a core but only 5 minutes old -> below the 12h floor.
        ps() { printf '%s\n' 'PID TIME ELAPSED COMM' '999 05:00 05:00 somebuild'; }
        opt_diag_runaway_process || echo NO_FINDING
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"NO_FINDING"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"somebuild"* ]] || return 1
}

@test "runaway ignores kernel_task, which legitimately accumulates CPU" {
    run /bin/bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/optimize/diagnostics.sh'
        ps() { printf '%s\n' 'PID TIME ELAPSED COMM' '0 200:00:00 16-08:00:00 kernel_task'; }
        opt_diag_runaway_process || echo NO_FINDING
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"NO_FINDING"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"kernel_task"* ]] || return 1
}

@test "runaway ignores a long-lived but mostly idle process" {
    run /bin/bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/optimize/diagnostics.sh'
        # 1h CPU over 16 days = ~0%, the shape of a healthy daemon.
        ps() { printf '%s\n' 'PID TIME ELAPSED COMM' '500 01:00:00 16-08:00:00 quietd'; }
        opt_diag_runaway_process || echo NO_FINDING
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"NO_FINDING"* ]] || { echo "$output"; return 1; }
}

@test "thresholds reject non-numeric env overrides" {
    run /bin/bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/optimize/diagnostics.sh'
        opt_diag_int_env 'bogus' 50
        opt_diag_int_env '12.5' 50
        opt_diag_int_env '70' 50
    "
    [ "$status" -eq 0 ]
    [ "${lines[0]}" -eq 50 ]
    [ "${lines[1]}" -eq 50 ]
    [ "${lines[2]}" -eq 70 ]
}
