//go:build darwin

package main

import (
	"context"
	"os"
	"reflect"
	"strconv"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func TestIsDeepSystemPath(t *testing.T) {
	cases := []struct {
		path string
		want bool
	}{
		{"/private", true},
		{"/private/var/folders", true},
		{"/private/var/folders/zz/abc/T/com.apple.idleassetsd", true},
		{"/private/var/vm", true},
		{"/private/../private/var", true}, // cleaned to /private/var
		{"", false},
		{"/Users/someone", false},
		{"/Applications", false},
		{"/Library", false},
		{"/privatex/y", false}, // must not match by raw prefix
		{"/var/folders/zz", false},
	}
	for _, c := range cases {
		if got := isDeepSystemPath(c.path); got != c.want {
			t.Errorf("isDeepSystemPath(%q) = %v, want %v", c.path, got, c.want)
		}
	}
}

func TestDeepScanEnabledAndSudoGuards(t *testing.T) {
	// Disabled by default.
	t.Setenv("MO_ANALYZE_DEEP", "")
	t.Setenv("MOLE_TEST_NO_AUTH", "")
	t.Setenv("MOLE_TEST_MODE", "")
	if deepScanEnabled() {
		t.Fatal("deepScanEnabled() should be false when MO_ANALYZE_DEEP is unset")
	}
	if deepScanUsesSudo() {
		t.Fatal("deepScanUsesSudo() should be false when deep is disabled")
	}

	// Enabled, no test guard -> elevates.
	t.Setenv("MO_ANALYZE_DEEP", "1")
	if !deepScanEnabled() {
		t.Fatal("deepScanEnabled() should be true when MO_ANALYZE_DEEP=1")
	}
	if !deepScanUsesSudo() {
		t.Fatal("deepScanUsesSudo() should be true when deep is enabled and not under the test guard")
	}

	// Test no-auth guard must suppress sudo even when deep is enabled.
	t.Setenv("MOLE_TEST_NO_AUTH", "1")
	if deepScanUsesSudo() {
		t.Fatal("deepScanUsesSudo() must be false under MOLE_TEST_NO_AUTH=1")
	}

	// MOLE_TEST_MODE is the other project-wide auth guard and must suppress
	// sudo on its own, matching has_sudo_session() in lib/core/sudo.sh.
	t.Setenv("MOLE_TEST_NO_AUTH", "")
	t.Setenv("MOLE_TEST_MODE", "1")
	if deepScanUsesSudo() {
		t.Fatal("deepScanUsesSudo() must be false under MOLE_TEST_MODE=1")
	}
}

func TestDeepScanRequiresElevation(t *testing.T) {
	// Elevation is only required for system paths in an active deep scan;
	// everywhere else measureOverviewSize keeps its unprivileged fallbacks.
	t.Setenv("MO_ANALYZE_DEEP", "")
	t.Setenv("MOLE_TEST_NO_AUTH", "")
	t.Setenv("MOLE_TEST_MODE", "")
	if deepScanRequiresElevation("/private/var/folders") {
		t.Fatal("non-deep system path must not require elevation")
	}

	t.Setenv("MO_ANALYZE_DEEP", "1")
	if !deepScanRequiresElevation("/private/var/folders") {
		t.Fatal("deep system path must require elevation")
	}
	if deepScanRequiresElevation("/Users/someone") {
		t.Fatal("user path must never require elevation")
	}

	t.Setenv("MOLE_TEST_NO_AUTH", "1")
	if deepScanRequiresElevation("/private/var/folders") {
		t.Fatal("guarded deep system path must not require elevation")
	}
}

func TestDuCommandFor(t *testing.T) {
	// Not deep: always plain du, no matter the path.
	t.Setenv("MO_ANALYZE_DEEP", "")
	t.Setenv("MOLE_TEST_NO_AUTH", "")
	t.Setenv("MOLE_TEST_MODE", "")
	if name, lead := duCommandFor("/private/var/folders"); name != "du" || lead != nil {
		t.Fatalf("non-deep du for system path = (%q, %v), want (du, nil)", name, lead)
	}

	// Deep + system path (no test guard): elevate with sudo -n.
	t.Setenv("MO_ANALYZE_DEEP", "1")
	name, lead := duCommandFor("/private/var/folders")
	if name != "sudo" || !reflect.DeepEqual(lead, []string{"-n", "du"}) {
		t.Fatalf("deep du for system path = (%q, %v), want (sudo, [-n du])", name, lead)
	}

	// Deep + user path: never elevated.
	if name, lead := duCommandFor("/Users/someone/Downloads"); name != "du" || lead != nil {
		t.Fatalf("deep du for user path = (%q, %v), want (du, nil)", name, lead)
	}

	// Deep + system path but under the test guard: no sudo.
	t.Setenv("MOLE_TEST_NO_AUTH", "1")
	if name, lead := duCommandFor("/private/var/folders"); name != "du" || lead != nil {
		t.Fatalf("guarded deep du for system path = (%q, %v), want (du, nil)", name, lead)
	}
}

func TestDeepDuCommandArgs(t *testing.T) {
	ctx := context.Background()

	// Non-deep: exactly the plain du argv.
	t.Setenv("MO_ANALYZE_DEEP", "")
	t.Setenv("MOLE_TEST_NO_AUTH", "")
	t.Setenv("MOLE_TEST_MODE", "")
	cmd := deepDuCommand(ctx, "/tmp/x", "-sk", "/tmp/x")
	want := []string{"du", "-sk", "/tmp/x"}
	if !reflect.DeepEqual(cmd.Args, want) {
		t.Fatalf("non-deep argv = %v, want %v", cmd.Args, want)
	}

	// Deep + system path: sudo -n is prepended, du flags/target preserved.
	t.Setenv("MO_ANALYZE_DEEP", "1")
	cmd = deepDuCommand(ctx, "/private/var/folders", "-skPx", "/private/var/folders")
	want = []string{"sudo", "-n", "du", "-skPx", "/private/var/folders"}
	if !reflect.DeepEqual(cmd.Args, want) {
		t.Fatalf("deep argv = %v, want %v", cmd.Args, want)
	}
}

func TestCreateInsightEntriesDeepGating(t *testing.T) {
	// /private/var/folders exists on every macOS host; use it as the probe.
	const probe = "/private/var/folders"
	if info, err := os.Stat(probe); err != nil || !info.IsDir() {
		t.Skipf("%s not available on this host", probe)
	}

	hasProbe := func(entries []dirEntry) bool {
		for _, e := range entries {
			if e.Path == probe {
				return true
			}
		}
		return false
	}

	// Deep disabled: system temp must not appear.
	t.Setenv("MO_ANALYZE_DEEP", "")
	if hasProbe(createInsightEntries()) {
		t.Fatal("deep-only insight leaked into the default overview")
	}

	// Deep enabled: system temp must appear.
	t.Setenv("MO_ANALYZE_DEEP", "1")
	if !hasProbe(createInsightEntries()) {
		t.Fatalf("deep insight for %s missing when deep mode is enabled", probe)
	}
}

func TestParseDuDepth1(t *testing.T) {
	root := "/private/var/folders/zz/abc/T"
	// Tab-separated `du -k -d 1` output: children plus the root aggregate line,
	// deliberately out of order to prove the sort.
	out := "" +
		"1024\t" + root + "/com.apple.small\n" +
		"209715200\t" + root + "/com.apple.idleassetsd\n" +
		"51200\t" + root + "/com.apple.medium\n" +
		"209767424\t" + root + "\n"

	entries, total := parseDuDepth1(out, root)
	if len(entries) != 3 {
		t.Fatalf("got %d entries, want 3: %+v", len(entries), entries)
	}
	// Root aggregate becomes the total (bytes), not a row.
	if want := int64(209767424) * 1024; total != want {
		t.Fatalf("total = %d, want %d", total, want)
	}
	// Sorted largest first, root line excluded.
	if entries[0].Name != "com.apple.idleassetsd" || entries[0].Size != int64(209715200)*1024 {
		t.Fatalf("top row = %+v, want idleassetsd largest", entries[0])
	}
	if entries[2].Name != "com.apple.small" {
		t.Fatalf("smallest row = %+v, want com.apple.small", entries[2])
	}
	for _, e := range entries {
		if !e.IsDir {
			t.Fatalf("breakdown row %q must be marked IsDir", e.Path)
		}
		if e.Path == root {
			t.Fatalf("root line leaked into rows: %q", e.Path)
		}
	}
}

func TestParseDuDepth1CapsRows(t *testing.T) {
	root := "/private/var/folders/zz/abc/T"
	var out strings.Builder
	for i := range elevatedBreakdownRows + 15 {
		out.WriteString("100\t" + root + "/child" + strconv.Itoa(i) + "\n")
	}
	entries, _ := parseDuDepth1(out.String(), root)
	if len(entries) != elevatedBreakdownRows {
		t.Fatalf("got %d rows, want cap of %d", len(entries), elevatedBreakdownRows)
	}
}

func TestParseDuDepth1SpaceSeparated(t *testing.T) {
	// Some du builds/locales use spaces instead of a tab.
	root := "/private/var/vm"
	out := "2097152 " + root + "/sleepimage\n2097152 " + root + "\n"
	entries, total := parseDuDepth1(out, root)
	if len(entries) != 1 || entries[0].Name != "sleepimage" {
		t.Fatalf("space-separated parse = %+v", entries)
	}
	if total != int64(2097152)*1024 {
		t.Fatalf("total = %d", total)
	}
}

// TestElevatedBreakdownArgvContract proves the breakdown reads and never
// deletes: the argv is a plain du with no destructive verb, prefixed with
// `sudo -n` only for /private targets when deep mode elevates.
func TestElevatedBreakdownArgvContract(t *testing.T) {
	t.Setenv("MO_ANALYZE_DEEP", "1")
	t.Setenv("MOLE_TEST_NO_AUTH", "")
	t.Setenv("MOLE_TEST_MODE", "")

	cmd := deepDuCommand(context.Background(), "/private/var/folders", "-kPx", "-d", "1", "/private/var/folders")
	want := []string{"sudo", "-n", "du", "-kPx", "-d", "1", "/private/var/folders"}
	if !reflect.DeepEqual(cmd.Args, want) {
		t.Fatalf("breakdown argv = %v, want %v", cmd.Args, want)
	}
	for _, a := range cmd.Args {
		switch a {
		case "rm", "-delete", "-exec", "-execdir", "-ok", "unlink":
			t.Fatalf("breakdown argv contains a destructive verb: %q", a)
		}
	}
}

func TestInElevatedBreakdownPredicate(t *testing.T) {
	t.Setenv("MO_ANALYZE_DEEP", "1")
	t.Setenv("MOLE_TEST_NO_AUTH", "")
	t.Setenv("MOLE_TEST_MODE", "")

	deep := model{path: "/private/var/folders/zz/abc", isOverview: false}
	if !deep.inElevatedBreakdown() {
		t.Fatal("deep system path in deep mode must be an elevated breakdown")
	}
	// Overview is never a breakdown.
	ov := model{path: "/", isOverview: true}
	if ov.inElevatedBreakdown() {
		t.Fatal("overview must not be an elevated breakdown")
	}
	// A user path is never a breakdown.
	usr := model{path: "/Users/someone/Downloads"}
	if usr.inElevatedBreakdown() {
		t.Fatal("user path must not be an elevated breakdown")
	}
	// Under the test guard, deep is suppressed, so no breakdown.
	t.Setenv("MOLE_TEST_NO_AUTH", "1")
	if deep.inElevatedBreakdown() {
		t.Fatal("test guard must suppress the elevated breakdown state")
	}
}

// TestDeleteRefusedInElevatedBreakdown is the core safety regression: a delete
// keypress while viewing a root-owned breakdown must never arm the delete flow.
func TestDeleteRefusedInElevatedBreakdown(t *testing.T) {
	t.Setenv("MO_ANALYZE_DEEP", "1")
	t.Setenv("MOLE_TEST_NO_AUTH", "")
	t.Setenv("MOLE_TEST_MODE", "")

	m := model{
		path:       "/private/var/folders/zz/abc/T",
		isOverview: false,
		entries: []dirEntry{
			{Name: "com.apple.idleassetsd", Path: "/private/var/folders/zz/abc/T/com.apple.idleassetsd", Size: 1 << 30, IsDir: true},
		},
		selected: 0,
		height:   40,
		width:    120,
	}

	updated, _ := m.updateKey(tea.KeyMsg{Type: tea.KeyDelete})
	got, ok := updated.(model)
	if !ok {
		t.Fatalf("expected model, got %T", updated)
	}
	if got.deleteConfirm {
		t.Fatal("delete confirm must not arm for a root-owned breakdown row")
	}
	if got.deleteTarget != nil {
		t.Fatalf("delete target must stay nil, got %+v", got.deleteTarget)
	}
}

// TestElevatedBreakdownNeverCaches proves the handler writes no cache, so a
// lapsed sudo credential can never mask a later non-deep run with a stale,
// undercounted listing.
func TestElevatedBreakdownNeverCaches(t *testing.T) {
	path := "/private/var/folders/zz/abc/T"
	seed := map[string]historyEntry{path: {Path: path}}

	// Success path.
	m := model{path: path, cache: seed, height: 40, width: 120}
	updated, _ := m.Update(elevatedBreakdownMsg{
		path:      path,
		entries:   []dirEntry{{Name: "child", Path: path + "/child", Size: 1 << 20, IsDir: true}},
		totalSize: 1 << 20,
	})
	got := updated.(model)
	if len(got.cache) != 1 || got.cache[path].Entries != nil {
		t.Fatalf("success path must not write cache entries: %+v", got.cache[path])
	}
	if len(got.entries) != 1 {
		t.Fatalf("success path must render the breakdown rows, got %d", len(got.entries))
	}

	// Error path.
	m2 := model{path: path, cache: map[string]historyEntry{path: {Path: path}}, height: 40, width: 120}
	updated2, _ := m2.Update(elevatedBreakdownMsg{path: path, err: context.DeadlineExceeded})
	got2 := updated2.(model)
	if got2.cache[path].Entries != nil {
		t.Fatal("error path must not write cache entries")
	}
	if len(got2.entries) != 0 {
		t.Fatalf("error path must clear entries, got %d", len(got2.entries))
	}
}
