#!/usr/bin/env bats
# Triage command: read-only detection, findings-only grammar, safe-fix gating,
# and dispatch wiring.

setup_file() {
	PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export PROJECT_ROOT
}

@test "triage help documents fix and yes flags" {
	run "$PROJECT_ROOT/bin/triage.sh" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"--fix"* ]]
	[[ "$output" == *"--yes"* ]]
	[[ "$output" == *"read-only"* ]]
}

@test "triage rejects unknown options" {
	run "$PROJECT_ROOT/bin/triage.sh" --bogus
	[ "$status" -eq 1 ]
	[[ "$output" == *"Unknown option"* ]]
}

@test "triage default run is read-only" {
	run "$PROJECT_ROOT/bin/triage.sh"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Triage"* ]]
	[[ "$output" == *"System"* ]]
	[[ "$output" == *"DIAGNOSIS"* ]]
	# A run without --fix must never claim to have changed anything.
	[[ "$output" != *"restarted"* ]]
	[[ "$output" != *"processes killed"* ]]
	[[ "$output" != *"profile dirs removed"* ]]
}

@test "healthy checks stay silent, findings-only grammar" {
	# Detectors print nothing when clean; only DIAGNOSIS content is findings.
	run /bin/bash -c "
		source '$PROJECT_ROOT/lib/core/common.sh'
		source '$PROJECT_ROOT/lib/triage/detect.sh'
		# Force the memory detector down the healthy path: 0% of 0M swap.
		MOLE_TRIAGE_SWAP_WARN_PCT=100 MOLE_TRIAGE_SWAP_CRIT_PCT=100 \
			triage_detect_memory && echo 'finding' || echo 'silent'
	"
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == "silent" ]]
}

@test "detectors survive a host with no findings or no playwright dirs" {
	# Detector library must load and run standalone under set -euo pipefail.
	run /bin/bash -c "
		source '$PROJECT_ROOT/lib/core/common.sh'
		source '$PROJECT_ROOT/lib/triage/detect.sh'
		triage_detect_stale_cloud_domains || true
		echo \"count=\$TRIAGE_FINDING_COUNT\"
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"count="* ]]
}

@test "threshold helpers reject non-numeric overrides" {
	run /bin/bash -c "
		source '$PROJECT_ROOT/lib/core/common.sh'
		source '$PROJECT_ROOT/lib/triage/detect.sh'
		MOLE_TRIAGE_SWAP_WARN_PCT='bogus' triage_swap_warn_pct
		MOLE_TRIAGE_DAEMON_CPU_PCT='12.5' triage_daemon_cpu_pct
	"
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == "60" ]]
	[[ "${lines[1]}" == "50" ]]
}

@test "fix helpers skip silently when detectors found nothing" {
	run /bin/bash -c "
		source '$PROJECT_ROOT/lib/core/common.sh'
		source '$PROJECT_ROOT/lib/triage/detect.sh'
		source '$PROJECT_ROOT/lib/triage/fix.sh'
		triage_fix_runaway_daemons
		triage_fix_leaked_browsers
		triage_explain_icloud_spiral
		echo 'clean-exit'
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"clean-exit"* ]]
	[[ "$output" != *"killed"* ]]
	[[ "$output" != *"Daemon Restart"* ]]
}

@test "fix authority: granted auth applies without prompts, denied skips fixes" {
	run /bin/bash -c "
		source '$PROJECT_ROOT/lib/core/common.sh'
		source '$PROJECT_ROOT/lib/triage/fix.sh'
		ensure_sudo_session() { return 0; }
		triage_request_fix_authority && echo 'authority-granted'
		ensure_sudo_session() { return 1; }
		TRIAGE_ASSUME_YES=false triage_request_fix_authority || echo 'authority-denied'
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Admin access granted"* ]]
	[[ "$output" == *"authority-granted"* ]]
	[[ "$output" == *"fixes skipped"* ]]
	[[ "$output" == *"authority-denied"* ]]
}

@test "fix run without auth in test mode changes nothing and says so" {
	MOLE_TEST_NO_AUTH=1 run "$PROJECT_ROOT/bin/triage.sh" --fix < /dev/null
	[ "$status" -eq 0 ]
	[[ "$output" != *"restarted"* ]]
	[[ "$output" != *"processes killed"* ]]
	# Either the host is healthy or fixes were gated off; both end states
	# must state that nothing changed or that nothing was found.
	[[ "$output" == *"Nothing was changed"* || "$output" == *"No known slowdown causes found"* ]]
}

@test "icloud playbook renders only when the spiral was detected" {
	run /bin/bash -c "
		source '$PROJECT_ROOT/lib/core/common.sh'
		source '$PROJECT_ROOT/lib/triage/fix.sh'
		TRIAGE_ICLOUD_SPIRAL=true triage_explain_icloud_spiral
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"iCloud Migration"* ]]
	[[ "$output" == *"one at a time"* ]]
}

@test "mole dispatch routes triage" {
	run /bin/bash -c "grep -A 2 '\"triage\")' '$PROJECT_ROOT/mole'"
	[ "$status" -eq 0 ]
	[[ "$output" == *"bin/triage.sh"* ]]
}
