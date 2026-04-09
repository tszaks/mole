//go:build darwin

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"sync/atomic"
)

type jsonOutput struct {
	Path       string          `json:"path"`
	Entries    []jsonEntry     `json:"entries"`
	LargeFiles []jsonFileEntry `json:"large_files,omitempty"`
	TotalSize  int64           `json:"total_size"`
	TotalFiles int64           `json:"total_files"`
}

type jsonEntry struct {
	Name  string `json:"name"`
	Path  string `json:"path"`
	Size  int64  `json:"size"`
	IsDir bool   `json:"is_dir"`
}

type jsonFileEntry struct {
	Name string `json:"name"`
	Path string `json:"path"`
	Size int64  `json:"size"`
}

func runJSONMode(path string, isOverview bool) {
	result := performScanForJSON(path)

	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(result); err != nil {
		fmt.Fprintf(os.Stderr, "failed to encode JSON: %v\n", err)
		os.Exit(1)
	}
}

func performScanForJSON(path string) jsonOutput {
	var filesScanned, dirsScanned, bytesScanned int64
	currentPath := &atomic.Value{}
	currentPath.Store("")

	result, err := scanPathConcurrentAllEntries(path, &filesScanned, &dirsScanned, &bytesScanned, currentPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to scan directory: %v\n", err)
		os.Exit(1)
	}

	entries := make([]jsonEntry, 0, len(result.Entries))
	for _, e := range result.Entries {
		entries = append(entries, jsonEntry{
			Name:  e.Name,
			Path:  e.Path,
			Size:  e.Size,
			IsDir: e.IsDir,
		})
	}

	largeFiles := make([]jsonFileEntry, 0, len(result.LargeFiles))
	for _, f := range result.LargeFiles {
		largeFiles = append(largeFiles, jsonFileEntry(f))
	}

	return jsonOutput{
		Path:       path,
		Entries:    entries,
		LargeFiles: largeFiles,
		TotalSize:  result.TotalSize,
		TotalFiles: result.TotalFiles,
	}
}
