#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
    export MO_DEBUG=0
}

# Concurrent timeout helpers share one process group, so a helper that starts
# while a sibling holds the terminal must not treat the sibling's child as the
# terminal's original owner: restoring the terminal to that dead process group
# suspended the next prompt read with SIGTTIN (issues #1222, #1218).
@test "run_with_timeout: concurrent perl helpers keep the terminal with the script (#1222)" {
	if [[ "$(uname -s)" != "Darwin" || ! -x /usr/bin/expect || ! -x /usr/bin/perl ]]; then
		skip "macOS expect/perl required"
	fi

	run /usr/bin/expect "$PROJECT_ROOT/tests/timeout_tty_concurrent.exp" "$PROJECT_ROOT"

	[ "$status" -eq 0 ]
	[[ "$output" == *"READ:typed-value"* ]]
}

# Background scan workers never read the terminal. Leaving the tty on their
# stdin let their timeout helpers take the terminal away from the foreground
# prompt, which is what suspended `mo uninstall <app>` before it removed
# anything (issue #1222).
@test "uninstall: background metadata workers detach stdin from the terminal (#1222)" {
	run grep -nE '^[[:space:]]*\) < /dev/null &' "$PROJECT_ROOT/bin/uninstall.sh"
	[ "$status" -eq 0 ]

	run grep -nE 'process_app_metadata .* < /dev/null &' "$PROJECT_ROOT/bin/uninstall.sh"
	[ "$status" -eq 0 ]

	run grep -nE '^[[:space:]]*\) > /dev/null 2>&1 < /dev/null &' "$PROJECT_ROOT/bin/uninstall.sh"
	[ "$status" -eq 0 ]
}

# Purge scans and size calculations run behind a tty-writing spinner. They must
# not let run_with_timeout's Perl fallback hand the controlling terminal to a
# background child, which suspends the foreground command with SIGTTOU (#1205).
@test "purge: background timeout workers detach stdin from the terminal (#1205)" {
	run grep -nF "scan_purge_targets \"\$path\" \"\$scan_output\" < /dev/null &" "$PROJECT_ROOT/lib/clean/project.sh"
	[ "$status" -eq 0 ] || return 1

	run grep -nF "(get_dir_size_kb \"\$_sz_item\" > \"\$_stmp\" 2> /dev/null) < /dev/null &" "$PROJECT_ROOT/lib/clean/project.sh"
	[ "$status" -eq 0 ] || return 1
}
