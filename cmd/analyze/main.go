//go:build darwin

package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync/atomic"
	"syscall"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

var (
	jsonMode = flag.Bool("json", false, "output analysis as JSON instead of TUI")
)

// systemRootsEnv overrides the machine-wide overview rows. See systemOverviewRoots.
const systemRootsEnv = "MO_ANALYZE_SYSTEM_ROOTS"

func main() {
	flag.Parse()

	target := os.Getenv("MO_ANALYZE_PATH")
	if target == "" && len(flag.Args()) > 0 {
		target = flag.Args()[0]
	}

	var abs string
	var isOverview bool

	if target == "" {
		isOverview = true
		abs = "/"
	} else {
		var err error
		abs, err = filepath.Abs(target)
		if err != nil {
			fmt.Fprintf(os.Stderr, "cannot resolve %q: %v\n", target, err)
			os.Exit(1)
		}
		isOverview = false
	}

	go pruneAnalyzerCache()
	if *jsonMode {
		runJSONMode(abs, isOverview)
	} else {
		runTUIMode(abs, isOverview)
	}
}

func runTUIMode(path string, isOverview bool) {
	// Warm overview cache only when the user opens a specific directory.
	// Overview mode already schedules the same measurements for the foreground UI;
	// running the prefetcher there doubles the du/io workload on cold start.
	if !isOverview {
		prefetchCtx, prefetchCancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer prefetchCancel()
		go prefetchOverviewCache(prefetchCtx)
	}

	p := tea.NewProgram(newModel(path, isOverview), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "analyzer error: %v\n", err)
		os.Exit(1)
	}
}

func newModel(path string, isOverview bool) model {
	var filesScanned, dirsScanned, bytesScanned int64
	currentPath := &atomic.Value{}
	currentPath.Store("")
	var diskFreeBytes int64
	var stat syscall.Statfs_t
	if err := syscall.Statfs(path, &stat); err == nil {
		diskFreeBytes = int64(stat.Bavail) * int64(stat.Bsize)
	}

	m := model{
		path:                path,
		selected:            0,
		status:              "Preparing scan...",
		diskFree:            diskFreeBytes,
		scanning:            !isOverview,
		filesScanned:        &filesScanned,
		dirsScanned:         &dirsScanned,
		bytesScanned:        &bytesScanned,
		currentPath:         currentPath,
		showLargeFiles:      false,
		isOverview:          isOverview,
		cache:               make(map[string]historyEntry),
		overviewSizeCache:   make(map[string]int64),
		overviewScanningSet: make(map[string]bool),
		multiSelected:       make(map[string]bool),
		largeMultiSelected:  make(map[string]bool),
		liveSortMode:        liveScanSortModeFromEnv(),
	}

	if isOverview {
		m.scanning = false
		m.hydrateOverviewEntries()
		m.selected = 0
		m.offset = 0
		if nextPendingOverviewIndex(m.entries) >= 0 {
			m.overviewScanning = true
			m.status = "Checking system folders..."
		} else {
			m.status = "Ready"
		}
	}

	// Try to peek last total files for progress bar, even if cache is stale
	if !isOverview {
		if total, err := peekCacheTotalFiles(path); err == nil && total > 0 {
			m.lastTotalFiles = total
		}
	}

	return m
}

func createOverviewEntries() []dirEntry {
	return createOverviewEntriesWithInsights(createInsightEntries())
}

func createOverviewEntriesWithInsights(insightEntries []dirEntry) []dirEntry {
	home := os.Getenv("HOME")
	entries := []dirEntry{}

	// Separate Home and ~/Library to avoid double counting.
	if home != "" {
		entries = append(entries, dirEntry{Name: "Home", Path: home, IsDir: true, Size: -1})

		userLibrary := filepath.Join(home, "Library")
		if _, err := os.Stat(userLibrary); err == nil {
			// Renamed from "App Library" to "User Library" so it parallels
			// "System Library" (`/Library`) and is not confused with
			// `/Applications`. Path unchanged.
			entries = append(entries, dirEntry{Name: "User Library", Path: userLibrary, IsDir: true, Size: -1})
		}
	}

	entries = append(entries, systemOverviewRoots()...)

	// Hidden space insights: paths that silently accumulate disk usage.
	entries = append(entries, insightEntries...)

	return entries
}

// systemOverviewRoots are the machine-wide overview rows. Every other overview
// and insight row derives from $HOME, so these two are the only ones a test
// cannot scope by repointing HOME. MO_ANALYZE_SYSTEM_ROOTS replaces them with a
// colon-separated list, which is what keeps an end-to-end overview scan off the
// host's real system volumes: measuring them on a cold CI runner takes minutes.
func systemOverviewRoots() []dirEntry {
	override, ok := os.LookupEnv(systemRootsEnv)
	if !ok {
		return []dirEntry{
			{Name: "Applications", Path: "/Applications", IsDir: true, Size: -1},
			{Name: "System Library", Path: "/Library", IsDir: true, Size: -1},
		}
	}

	var entries []dirEntry
	for _, path := range filepath.SplitList(override) {
		if path == "" {
			continue
		}
		entries = append(entries, dirEntry{Name: filepath.Base(path), Path: path, IsDir: true, Size: -1})
	}
	return entries
}

func sumKnownEntrySizes(entries []dirEntry) int64 {
	var total int64
	for _, entry := range entries {
		if entry.Size > 0 {
			total += entry.Size
		}
	}
	return total
}

func nextPendingOverviewIndex(entries []dirEntry) int {
	for i, entry := range entries {
		if entry.Size < 0 {
			return i
		}
	}
	return -1
}

func hasPendingOverviewEntries(entries []dirEntry) bool {
	for _, entry := range entries {
		if entry.Size < 0 {
			return true
		}
	}
	return false
}

func safeOpen(path string, reveal bool) error {
	if err := validatePath(path); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), openCommandTimeout)
	defer cancel()
	args := []string{path}
	if reveal {
		args = []string{"-R", path}
	}
	return exec.CommandContext(ctx, "open", args...).Run()
}

// safePreview opens the file with the default macOS application.
func safePreview(path string) error {
	if err := validatePath(path); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), openCommandTimeout)
	defer cancel()
	return exec.CommandContext(ctx, "open", path).Run()
}
