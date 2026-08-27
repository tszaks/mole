//go:build darwin

package main

import (
	"context"
	"os/exec"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

const localSnapshotProbeTimeout = 3 * time.Second

type localSnapshotMsg struct {
	count int
	err   error
}

type localSnapshotCommandRunner func(context.Context, string, ...string) ([]byte, error)

func detectLocalSnapshotsCmd() tea.Cmd {
	return localSnapshotProbeCmd(func(ctx context.Context, name string, args ...string) ([]byte, error) {
		return exec.CommandContext(ctx, name, args...).Output()
	})
}

func localSnapshotProbeCmd(run localSnapshotCommandRunner) tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), localSnapshotProbeTimeout)
		defer cancel()

		output, err := run(ctx, "/usr/bin/tmutil", "listlocalsnapshotdates", "/")
		if err != nil {
			return localSnapshotMsg{err: err}
		}

		return localSnapshotMsg{count: parseLocalSnapshotCount(output)}
	}
}

// parseLocalSnapshotCount ignores tmutil's localized heading and counts only
// the documented YYYY-MM-DD-HHMMSS snapshot-date rows. Snapshot sizes are
// intentionally not inferred because tmutil does not expose retained bytes.
func parseLocalSnapshotCount(data []byte) int {
	count := 0
	for line := range strings.SplitSeq(string(data), "\n") {
		if _, err := time.Parse("2006-01-02-150405", strings.TrimSpace(line)); err == nil {
			count++
		}
	}
	return count
}
