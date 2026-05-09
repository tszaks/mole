//go:build darwin

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestPerformScanForJSONIncludesAllEntriesAndLargeFiles(t *testing.T) {
	root := t.TempDir()

	totalFiles := maxEntries + 6
	for i := 0; i < totalFiles-1; i++ {
		path := filepath.Join(root, fmt.Sprintf("small-%02d.txt", i))
		if err := os.WriteFile(path, []byte("x"), 0o644); err != nil {
			t.Fatalf("write small file %d: %v", i, err)
		}
	}

	hugeFile := filepath.Join(root, "huge.bin")
	if err := os.WriteFile(hugeFile, make([]byte, 2<<20), 0o644); err != nil {
		t.Fatalf("write huge file: %v", err)
	}

	result := performScanForJSON(root, false)

	if result.Overview {
		t.Fatalf("expected non-overview JSON result")
	}
	if got := len(result.Entries); got != totalFiles {
		t.Fatalf("expected %d entries, got %d", totalFiles, got)
	}
	if result.TotalFiles != int64(totalFiles) {
		t.Fatalf("expected %d total files, got %d", totalFiles, result.TotalFiles)
	}
	if len(result.LargeFiles) == 0 {
		t.Fatalf("expected large_files to include the large file")
	}

	foundHuge := false
	for _, file := range result.LargeFiles {
		if file.Name == "huge.bin" && file.Path == hugeFile {
			foundHuge = true
			break
		}
	}
	if !foundHuge {
		t.Fatalf("expected huge.bin in large_files, got %#v", result.LargeFiles)
	}
}

func TestPerformScanForJSONExcludesConfiguredPaths(t *testing.T) {
	root := t.TempDir()
	includedDir := filepath.Join(root, "included")
	excludedDir := filepath.Join(root, "excluded")
	if err := os.MkdirAll(includedDir, 0o755); err != nil {
		t.Fatalf("mkdir included: %v", err)
	}
	if err := os.MkdirAll(excludedDir, 0o755); err != nil {
		t.Fatalf("mkdir excluded: %v", err)
	}
	if err := os.WriteFile(filepath.Join(includedDir, "keep.bin"), []byte("keep"), 0o644); err != nil {
		t.Fatalf("write included: %v", err)
	}
	if err := os.WriteFile(filepath.Join(excludedDir, "drop.bin"), []byte("drop"), 0o644); err != nil {
		t.Fatalf("write excluded: %v", err)
	}

	oldExcludes := activeAnalyzeExcludePaths
	activeAnalyzeExcludePaths = []string{excludedDir}
	t.Cleanup(func() {
		activeAnalyzeExcludePaths = oldExcludes
	})

	result := performScanForJSON(root, false)
	if result.TotalFiles != 1 {
		t.Fatalf("expected one included file, got %d", result.TotalFiles)
	}
	for _, entry := range result.Entries {
		if strings.HasPrefix(entry.Path, excludedDir) {
			t.Fatalf("excluded path appeared in JSON entries: %#v", entry)
		}
	}
	for _, file := range result.LargeFiles {
		if strings.HasPrefix(file.Path, excludedDir) {
			t.Fatalf("excluded path appeared in JSON large files: %#v", file)
		}
	}
}

func TestJSONEntriesFromDirEntriesIncludesMetadata(t *testing.T) {
	oldAccess := time.Now().AddDate(0, 0, -120)

	entries := jsonEntriesFromDirEntries([]dirEntry{
		{
			Name:       "old.bin",
			Path:       "/tmp/old.bin",
			Size:       42,
			IsDir:      false,
			LastAccess: oldAccess,
		},
		{
			Name:  "node_modules",
			Path:  "/tmp/project/node_modules",
			Size:  128,
			IsDir: true,
		},
	}, false, nil)

	if entries[0].LastAccess == "" {
		t.Fatalf("expected last_access to be populated")
	}
	if entries[1].Cleanable != true {
		t.Fatalf("expected node_modules entry to be marked cleanable")
	}
}

func TestJSONEntriesFromDirEntriesMarksOverviewInsights(t *testing.T) {
	entry := dirEntry{
		Name:  "Old Downloads (90d+)",
		Path:  "/tmp/test-home/Downloads",
		Size:  256,
		IsDir: true,
	}

	entries := jsonEntriesFromDirEntries([]dirEntry{entry}, true, map[string]bool{
		entry.Path: true,
	})

	if len(entries) != 1 {
		t.Fatalf("expected one entry, got %d", len(entries))
	}
	if !entries[0].Insight {
		t.Fatalf("expected entry to be marked as insight")
	}
}
