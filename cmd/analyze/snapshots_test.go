//go:build darwin

package main

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestParseLocalSnapshotCount(t *testing.T) {
	tests := []struct {
		name   string
		output string
		want   int
	}{
		{
			name: "counts documented snapshot dates",
			output: `Snapshot dates for volume group containing disk /:
2026-08-26-091500
2026-08-26-101500
`,
			want: 2,
		},
		{
			name:   "ignores a localized heading with no snapshots",
			output: "本地快照日期：\n",
			want:   0,
		},
		{
			name: "ignores snapshot names and malformed dates",
			output: `Snapshots for volume group containing disk /:
com.apple.os.update-MSUPrepareUpdate
2026-99-99-999999
`,
			want: 0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := parseLocalSnapshotCount([]byte(tt.output))
			if got != tt.want {
				t.Fatalf("parseLocalSnapshotCount() = %d, want %d", got, tt.want)
			}
		})
	}
}

func TestLocalSnapshotProbeUsesBoundedReadOnlyTMUtilQuery(t *testing.T) {
	var gotName string
	var gotArgs []string
	runner := func(ctx context.Context, name string, args ...string) ([]byte, error) {
		gotName = name
		gotArgs = append([]string(nil), args...)
		deadline, ok := ctx.Deadline()
		if !ok || time.Until(deadline) <= 0 || time.Until(deadline) > localSnapshotProbeTimeout {
			t.Fatalf("snapshot probe context deadline = %v, want a live %s budget", deadline, localSnapshotProbeTimeout)
		}
		return []byte("Snapshot dates:\n2026-08-26-091500\n2026-08-26-101500\n"), nil
	}

	msg := localSnapshotProbeCmd(runner)().(localSnapshotMsg)
	if msg.err != nil || msg.count != 2 {
		t.Fatalf("snapshot probe result = %#v, want count 2", msg)
	}
	if gotName != "/usr/bin/tmutil" {
		t.Fatalf("snapshot probe command = %q, want /usr/bin/tmutil", gotName)
	}
	wantArgs := []string{"listlocalsnapshotdates", "/"}
	if !reflect.DeepEqual(gotArgs, wantArgs) {
		t.Fatalf("snapshot probe args = %#v, want %#v", gotArgs, wantArgs)
	}
}

func TestLocalSnapshotProbeReportsCommandFailure(t *testing.T) {
	wantErr := errors.New("tmutil unavailable")
	msg := localSnapshotProbeCmd(func(context.Context, string, ...string) ([]byte, error) {
		return nil, wantErr
	})().(localSnapshotMsg)
	if !errors.Is(msg.err, wantErr) || msg.count != 0 {
		t.Fatalf("snapshot probe result = %#v, want command error", msg)
	}
}

func TestOverviewStoresSuccessfulLocalSnapshotCount(t *testing.T) {
	m := model{path: "/", isOverview: true}
	updated, cmd := m.Update(localSnapshotMsg{count: 3})
	if cmd != nil {
		t.Fatalf("snapshot update command = %v, want nil", cmd)
	}
	got := updated.(model)
	if got.localSnapshotCount != 3 {
		t.Fatalf("snapshot count = %d, want 3", got.localSnapshotCount)
	}

	updated, _ = got.Update(localSnapshotMsg{count: 9, err: errors.New("bad output")})
	if got := updated.(model).localSnapshotCount; got != 3 {
		t.Fatalf("failed refresh changed snapshot count to %d, want 3", got)
	}
}

func TestOverviewViewExplainsLocalSnapshotOnlySpace(t *testing.T) {
	m := model{
		path:               "/",
		isOverview:         true,
		localSnapshotCount: 2,
		entries:            []dirEntry{{Name: "Home", Path: "/tmp/home", Size: 1, IsDir: true}},
	}

	view := m.View()
	for _, want := range []string{"2 Time Machine local snapshots", "snapshot-only space is not listed below"} {
		if !strings.Contains(view, want) {
			t.Fatalf("expected overview snapshot notice %q, got:\n%s", want, view)
		}
	}
}

func TestOverviewViewUsesSingularSnapshotLabel(t *testing.T) {
	m := model{
		path:               "/",
		isOverview:         true,
		localSnapshotCount: 1,
		entries:            []dirEntry{{Name: "Home", Path: "/tmp/home", Size: 1, IsDir: true}},
	}

	view := m.View()
	if !strings.Contains(view, "1 Time Machine local snapshot") || strings.Contains(view, "1 Time Machine local snapshots") {
		t.Fatalf("expected singular snapshot notice, got:\n%s", view)
	}
}

func TestOverviewViewOmitsSnapshotNoticeWhenNoneDetected(t *testing.T) {
	m := model{
		path:       "/",
		isOverview: true,
		entries:    []dirEntry{{Name: "Home", Path: "/tmp/home", Size: 1, IsDir: true}},
	}

	if view := m.View(); strings.Contains(view, "Time Machine local snapshot") {
		t.Fatalf("expected no snapshot notice, got:\n%s", view)
	}
}
