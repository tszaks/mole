//go:build darwin

package main

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// insightEntry represents a hidden-space insight for the overview screen.
type insightEntry struct {
	Name string
	Path string // primary path to measure (may be virtual for multi-path insights)
}

// createInsightEntries returns the list of hidden-space insight entries
// to show in the overview screen alongside the standard directory entries.
func createInsightEntries() []dirEntry {
	home := os.Getenv("HOME")
	if home == "" {
		return nil
	}

	var entries []dirEntry

	// iOS Backups — ~/Library/Application Support/MobileSync/Backup
	backupPath := filepath.Join(home, "Library", "Application Support", "MobileSync", "Backup")
	if info, err := os.Stat(backupPath); err == nil && info.IsDir() {
		entries = append(entries, dirEntry{
			Name:  "iOS Backups",
			Path:  backupPath,
			IsDir: true,
			Size:  -1,
		})
	}

	// Old Downloads — ~/Downloads (files older than 90 days)
	downloadsPath := filepath.Join(home, "Downloads")
	if info, err := os.Stat(downloadsPath); err == nil && info.IsDir() {
		entries = append(entries, dirEntry{
			Name:  "Old Downloads (90d+)",
			Path:  downloadsPath,
			IsDir: true,
			Size:  -1,
		})
	}

	// Mail Attachments — ~/Library/Mail
	mailPath := filepath.Join(home, "Library", "Mail")
	if info, err := os.Stat(mailPath); err == nil && info.IsDir() {
		entries = append(entries, dirEntry{
			Name:  "Mail Data",
			Path:  mailPath,
			IsDir: true,
			Size:  -1,
		})
	}

	// Cleanable paths — things mo clean can remove or the user can safely delete.
	cleanablePaths := []struct {
		name string
		path string
	}{
		// Universal (everyone has these)
		{"Trash", filepath.Join(home, ".Trash")},
		{"System Caches", filepath.Join(home, "Library", "Caches")},
		{"System Logs", filepath.Join(home, "Library", "Logs")},
		{"Homebrew Cache", filepath.Join(home, "Library", "Caches", "Homebrew")},

		// Developer-specific (only shown if path exists)
		{"Xcode DerivedData", filepath.Join(home, "Library", "Developer", "Xcode", "DerivedData")},
		{"Xcode Simulators", filepath.Join(home, "Library", "Developer", "CoreSimulator", "Devices")},
		{"Xcode Archives", filepath.Join(home, "Library", "Developer", "Xcode", "Archives")},
		{"Spotify Cache", filepath.Join(home, "Library", "Application Support", "Spotify", "PersistentCache")},
		{"JetBrains Cache", filepath.Join(home, "Library", "Caches", "JetBrains")},
		{"Docker Data", filepath.Join(home, "Library", "Containers", "com.docker.docker", "Data")},
		{"pip Cache", filepath.Join(home, "Library", "Caches", "pip")},
		{"Gradle Cache", filepath.Join(home, ".gradle", "caches")},
		{"CocoaPods Cache", filepath.Join(home, "Library", "Caches", "CocoaPods")},
	}
	cacheBreakdownPaths := cleanablePaths
	for _, c := range cacheBreakdownPaths {
		if info, err := os.Stat(c.path); err == nil && info.IsDir() {
			entries = append(entries, dirEntry{
				Name:  c.name,
				Path:  c.path,
				IsDir: true,
				Size:  -1,
			})
		}
	}

	return entries
}

// measureInsightSize measures the size of an insight entry.
// Some insights need special measurement (e.g., Old Downloads only counts old files).
func measureInsightSize(entry dirEntry) (int64, error) {
	home := os.Getenv("HOME")

	// Old Downloads: only count files older than 90 days.
	if home != "" && entry.Path == filepath.Join(home, "Downloads") {
		return measureOldDownloads(entry.Path, 90)
	}

	// All others: standard directory size measurement.
	return measureOverviewSize(entry.Path)
}

// measureOldDownloads calculates total size of files in a directory
// that haven't been modified in the given number of days.
func measureOldDownloads(dir string, daysOld int) (int64, error) {
	cutoff := time.Now().AddDate(0, 0, -daysOld)
	var total int64

	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0, err
	}

	for _, entry := range entries {
		// Skip hidden files.
		if strings.HasPrefix(entry.Name(), ".") {
			continue
		}

		info, err := entry.Info()
		if err != nil {
			continue
		}

		if info.ModTime().Before(cutoff) {
			if entry.IsDir() {
				// Use du for directories.
				if size, err := getDirSizeFast(filepath.Join(dir, entry.Name())); err == nil {
					total += size
				}
			} else {
				total += info.Size()
			}
		}
	}

	return total, nil
}

// measureNodeModulesTotal finds all node_modules directories under home and sums their sizes.
func measureNodeModulesTotal() (int64, error) {
	home := os.Getenv("HOME")
	if home == "" {
		return 0, nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Use find to locate node_modules, prune to avoid nested ones.
	cmd := exec.CommandContext(ctx, "find", home,
		"-name", "node_modules", "-type", "d",
		"-not", "-path", "*/node_modules/*/node_modules",
		"-maxdepth", "6",
		"-prune")
	output, err := cmd.Output()
	if err != nil {
		return 0, err
	}

	var total int64
	for _, line := range strings.Split(strings.TrimSpace(string(output)), "\n") {
		if line == "" {
			continue
		}
		if size, err := getDirSizeFast(line); err == nil {
			total += size
		}
	}

	return total, nil
}

// measureTimeMachineSnapshots returns the total size of local Time Machine snapshots.
func measureTimeMachineSnapshots() (int64, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "tmutil", "listlocalsnapshots", "/")
	output, err := cmd.Output()
	if err != nil {
		return 0, err
	}

	lines := strings.Split(strings.TrimSpace(string(output)), "\n")
	snapshotCount := 0
	for _, line := range lines {
		if strings.Contains(line, "com.apple.TimeMachine") {
			snapshotCount++
		}
	}

	if snapshotCount == 0 {
		return 0, nil
	}

	// Get purgeable space from diskutil which includes TM snapshots.
	cmd2 := exec.CommandContext(ctx, "tmutil", "thinlocalsnapshots", "/", "1", "1")
	output2, err := cmd2.Output()
	if err != nil {
		// Estimate: each snapshot ~1-5GB avg, rough estimate.
		return int64(snapshotCount) * 2 * 1024 * 1024 * 1024, nil
	}

	// Parse "Thinned local snapshots: X bytes" from output.
	for _, line := range strings.Split(string(output2), "\n") {
		if strings.Contains(line, "Purged Amount") || strings.Contains(line, "Thinned") {
			fields := strings.Fields(line)
			for _, f := range fields {
				if val, err := strconv.ParseInt(f, 10, 64); err == nil && val > 0 {
					return val, nil
				}
			}
		}
	}

	// Fallback estimate.
	return int64(snapshotCount) * 2 * 1024 * 1024 * 1024, nil
}

// insightIcon returns an appropriate icon for an overview entry.
func insightIcon(entry dirEntry) string {
	switch entry.Name {
	case "iOS Backups":
		return "📱"
	case "Old Downloads (90d+)":
		return "📥"
	case "Mail Data":
		return "📧"
	case "node_modules (all)":
		return "📦"
	case "Time Machine Local":
		return "🕐"
	case "Trash":
		return "🗑️"
	case "System Caches", "Homebrew Cache", "pip Cache", "CocoaPods Cache", "Gradle Cache":
		return "💾"
	case "System Logs":
		return "📋"
	case "Xcode DerivedData", "Xcode Archives":
		return "🔨"
	case "Xcode Simulators":
		return "📲"
	case "Spotify Cache", "JetBrains Cache":
		return "💾"
	case "Docker Data":
		return "🐳"
	default:
		return "📁"
	}
}

// isVirtualInsightPath returns true for paths that are virtual aggregations
// and cannot be navigated into directly.
func isVirtualInsightPath(path string) bool {
	return strings.HasSuffix(path, ".node_modules_total") || path == "/.timemachine_local"
}

// getDirSizeFast measures directory size using du.
func getDirSizeFast(path string) (int64, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "du", "-sk", path)
	output, err := cmd.Output()
	if err != nil {
		return 0, err
	}

	fields := strings.Fields(string(output))
	if len(fields) == 0 {
		return 0, nil
	}

	kb, err := strconv.ParseInt(fields[0], 10, 64)
	if err != nil {
		return 0, err
	}

	return kb * 1024, nil
}
