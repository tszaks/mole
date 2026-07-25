//go:build darwin

package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// Deep scan surfaces root-owned system areas that the normal, unprivileged
// analyze overview cannot measure, most notably /private/var/folders, where
// daemons such as com.apple.idleassetsd can silently accumulate hundreds of
// gigabytes of aborted temporary downloads. macOS folds these bytes into the
// opaque "System Data" bucket and the Finder never shows them, so a plain `du`
// run as the user hits "permission denied" on the root-owned trees and reports
// almost nothing.
//
// Deep scan is strictly opt-in via the --deep flag (or MO_ANALYZE_DEEP=1)
// because it requires sudo to read directories owned by root. Authentication is
// primed once, up front, before the TUI starts, and every later read uses
// `sudo -n` so the interface never blocks on a password prompt. A keepalive
// goroutine refreshes the sudo timestamp for the life of the process, because a
// TUI session easily outlives sudo's default 5-minute window and an expired
// timestamp would silently turn elevated reads back into the misleading
// permission-denied measurements deep mode exists to fix. Under the test guards
// it degrades to unprivileged du and never touches sudo.

// deepScanEnabled reports whether the opt-in deep system scan is active.
func deepScanEnabled() bool {
	return os.Getenv("MO_ANALYZE_DEEP") == "1"
}

// deepScanAuthSuppressed reports whether the test guards forbid touching sudo.
// Mirrors has_sudo_session() in lib/core/sudo.sh, which honours both flags.
func deepScanAuthSuppressed() bool {
	return os.Getenv("MOLE_TEST_NO_AUTH") == "1" || os.Getenv("MOLE_TEST_MODE") == "1"
}

// deepScanUsesSudo reports whether du should be elevated with `sudo -n` to read
// root-owned trees. It stays false under the test guards so tests and CI never
// trigger a real authentication prompt.
func deepScanUsesSudo() bool {
	if !deepScanEnabled() {
		return false
	}
	return !deepScanAuthSuppressed()
}

// isDeepSystemPath reports whether target lives under /private, i.e. a
// root-owned system area that only deep mode is allowed to elevate reads for.
// User paths (Home, ~/Library, /Applications, ...) are never elevated, so a
// deep scan runs sudo strictly against the system trees it exists to reveal.
func isDeepSystemPath(target string) bool {
	if target == "" {
		return false
	}
	clean := filepath.Clean(target)
	return clean == "/private" || strings.HasPrefix(clean, "/private"+string(filepath.Separator))
}

// duCommandFor returns the executable name and leading arguments for a du
// invocation against target. In deep mode, reads of root-owned system paths are
// elevated with `sudo -n` (non-interactive; relies on credentials primed before
// the TUI starts and never blocks on a password prompt). Everything else runs
// du unprivileged, exactly as before.
func duCommandFor(target string) (name string, leadingArgs []string) {
	if deepScanUsesSudo() && isDeepSystemPath(target) {
		return "sudo", []string{"-n", "du"}
	}
	return "du", nil
}

// deepDuCommand builds a du *exec.Cmd for target, transparently prefixing
// `sudo -n` when deep mode should elevate the read. duArgs are the du arguments
// (flags and the target path) exactly as they would be passed to a plain du.
func deepDuCommand(ctx context.Context, target string, duArgs ...string) *exec.Cmd {
	name, leading := duCommandFor(target)
	full := make([]string, 0, len(leading)+len(duArgs))
	full = append(full, leading...)
	full = append(full, duArgs...)
	return exec.CommandContext(ctx, name, full...)
}

// deepSystemInsightPaths lists the root-owned system areas surfaced only when
// deep mode is active. These are the locations macOS folds into "System Data"
// and that the Finder never shows.
func deepSystemInsightPaths() []struct {
	name string
	path string
} {
	return []struct {
		name string
		path string
	}{
		{"System Temp (var/folders)", "/private/var/folders"},
		{"System VM / Swap", "/private/var/vm"},
	}
}

// deepScanRequiresElevation reports whether measuring path depends on an
// elevated read succeeding. Callers must surface a failure for these paths
// instead of falling back to an unprivileged walk: the fallback is exactly the
// permission-denied undercount that makes root-owned trees look empty, and
// reporting it as a real size is worse than reporting nothing.
func deepScanRequiresElevation(path string) bool {
	return deepScanUsesSudo() && isDeepSystemPath(path)
}

// disableDeepScan turns deep mode off for the rest of the process so the
// overview falls back to its normal, unprivileged entries.
func disableDeepScan(reason string) {
	fmt.Fprintln(os.Stderr, "Deep scan: "+reason+"; continuing without elevated system folders.")
	_ = os.Unsetenv("MO_ANALYZE_DEEP")
}

// primeSudoForDeepScan authenticates once, up front and outside the TUI's alt
// screen, so later `sudo -n du` calls succeed without ever blocking the
// interface on a password prompt. If authentication fails or is declined, deep
// mode is disabled and analyze continues with normal, unprivileged output. It
// is a no-op unless deep mode is enabled, and always a no-op under the test
// guards.
//
// allowPrompt is false for --json, the automation surface: a password prompt
// there would hang any script that captures the output, so JSON runs only get
// deep mode when a sudo timestamp is already cached.
func primeSudoForDeepScan(allowPrompt bool) {
	if !deepScanEnabled() {
		return
	}
	if deepScanAuthSuppressed() {
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	if !allowPrompt {
		if err := exec.CommandContext(ctx, "sudo", "-n", "-v").Run(); err != nil {
			disableDeepScan("--json cannot prompt for administrator access")
			return
		}
		startSudoKeepalive()
		return
	}

	fmt.Fprintln(os.Stderr, "Deep scan needs administrator access to measure root-owned system folders (e.g. /private/var/folders).")

	cmd := exec.CommandContext(ctx, "sudo", "-v")
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		disableDeepScan("administrator access unavailable")
		return
	}

	startSudoKeepalive()
}

// startSudoKeepalive refreshes the sudo timestamp in the background for the life
// of the process. Without it the timestamp expires (5 minutes by default) part
// way through a TUI session and every later `sudo -n du` starts failing, which
// would quietly reintroduce the undercount deep mode exists to fix. Mirrors
// _start_sudo_keepalive() in lib/core/sudo.sh, including its behaviour of
// giving up after three consecutive refresh failures.
func startSudoKeepalive() {
	go func() {
		// Let the sudo cache settle after authentication so the first refresh
		// does not immediately re-trigger Touch ID.
		time.Sleep(2 * time.Second)

		failures := 0
		for {
			if err := exec.Command("sudo", "-n", "-v").Run(); err != nil {
				failures++
				if failures >= 3 {
					return
				}
				time.Sleep(5 * time.Second)
				continue
			}
			failures = 0
			time.Sleep(30 * time.Second)
		}
	}()
}

// elevatedBreakdownRows caps how many children a deep-mode drill-down renders.
// Deep system trees fold hundreds of daemon temp dirs; the largest few carry
// the attribution value ("com.apple.idleassetsd holds the bytes"), and a fixed
// cap keeps the view a one-screen summary rather than a dashboard.
const elevatedBreakdownRows = 20

// elevatedBreakdownMsg carries the result of a one-level `sudo du -d 1` of a
// root-owned system path. It drives a view-only breakdown during deep-mode
// drill-down and is never written to any cache.
type elevatedBreakdownMsg struct {
	path      string
	entries   []dirEntry
	totalSize int64
	err       error
}

// elevatedBreakdownCmd measures the immediate children of a root-owned system
// path with the primed `sudo du` funnel (deepDuCommand), so trees the normal
// unprivileged scan cannot enter still show which subsystem holds the bytes. It
// is strictly read-only: du only reads, the argv never contains a deletion verb,
// and the result is rendered ephemerally, never cached, so a lapsed sudo
// credential can never leave a stale undercount behind.
func elevatedBreakdownCmd(path string) tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), duTimeout)
		defer cancel()

		// -k KB blocks, -P do not follow symlinks, -x stay on one filesystem,
		// -d 1 one level deep. Same elevation gate as every other deep read:
		// deepDuCommand only prefixes `sudo -n` for /private targets in deep mode.
		cmd := deepDuCommand(ctx, path, "-kPx", "-d", "1", path)
		out, err := cmd.Output()
		if err != nil {
			if ctx.Err() == context.DeadlineExceeded {
				return elevatedBreakdownMsg{path: path, err: fmt.Errorf("measurement timed out after %v", duTimeout)}
			}
			return elevatedBreakdownMsg{path: path, err: err}
		}

		entries, total := parseDuDepth1(string(out), path)
		return elevatedBreakdownMsg{path: path, entries: entries, totalSize: total}
	}
}

// parseDuDepth1 turns `du -k -d 1 <root>` output into child dirEntry rows,
// largest first, capped at elevatedBreakdownRows. The root's own aggregate line
// is dropped and returned separately as the total. It is a pure function (string
// in, rows out, no exec) so it can be unit-tested without sudo or a real du.
func parseDuDepth1(out, root string) ([]dirEntry, int64) {
	cleanRoot := filepath.Clean(root)
	var entries []dirEntry
	var total int64

	for line := range strings.SplitSeq(out, "\n") {
		line = strings.TrimRight(line, "\r")
		if strings.TrimSpace(line) == "" {
			continue
		}
		// du separates size and path with a tab, but fall back to whitespace
		// splitting for builds/locales that use spaces.
		var sizeField, pathField string
		if before, after, found := strings.Cut(line, "\t"); found {
			sizeField = strings.TrimSpace(before)
			pathField = strings.TrimSpace(after)
		} else {
			fields := strings.Fields(line)
			if len(fields) < 2 {
				continue
			}
			sizeField = fields[0]
			pathField = strings.Join(fields[1:], " ")
		}

		kb, err := strconv.ParseInt(sizeField, 10, 64)
		if err != nil {
			continue
		}
		clean := filepath.Clean(pathField)
		if clean == cleanRoot {
			total = kb * 1024
			continue
		}
		entries = append(entries, dirEntry{
			Name:  filepath.Base(clean),
			Path:  clean,
			Size:  kb * 1024,
			IsDir: true,
		})
	}

	sort.SliceStable(entries, func(i, j int) bool { return entries[i].Size > entries[j].Size })
	if len(entries) > elevatedBreakdownRows {
		entries = entries[:elevatedBreakdownRows]
	}
	if total == 0 {
		for _, e := range entries {
			total += e.Size
		}
	}
	return entries, total
}
