package main

import (
	"bytes"
	"container/heap"
	"context"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"golang.org/x/sync/singleflight"
)

var scanGroup singleflight.Group

func scanPathConcurrent(root string, filesScanned, dirsScanned, bytesScanned *int64, currentPath *string) (scanResult, error) {
	children, err := os.ReadDir(root)
	if err != nil {
		return scanResult{}, err
	}

	var total int64

	// Use heaps to track Top N items, drastically reducing memory usage
	// for directories with millions of files
	entriesHeap := &entryHeap{}
	heap.Init(entriesHeap)

	largeFilesHeap := &largeFileHeap{}
	heap.Init(largeFilesHeap)

	// Use worker pool for concurrent directory scanning
	// For I/O-bound operations, use more workers than CPU count
	numWorkers := runtime.NumCPU() * cpuMultiplier
	if numWorkers < minWorkers {
		numWorkers = minWorkers
	}
	if numWorkers > maxWorkers {
		numWorkers = maxWorkers
	}
	if numWorkers > len(children) {
		numWorkers = len(children)
	}
	if numWorkers < 1 {
		numWorkers = 1
	}
	sem := make(chan struct{}, numWorkers)
	var wg sync.WaitGroup

	// Use channels to collect results without lock contention
	entryChan := make(chan dirEntry, len(children))
	largeFileChan := make(chan fileEntry, maxLargeFiles*2)

	// Start goroutines to collect from channels into heaps
	var collectorWg sync.WaitGroup
	collectorWg.Add(2)
	go func() {
		defer collectorWg.Done()
		for entry := range entryChan {
			// Maintain Top N Heap for entries
			if entriesHeap.Len() < maxEntries {
				heap.Push(entriesHeap, entry)
			} else if entry.Size > (*entriesHeap)[0].Size {
				heap.Pop(entriesHeap)
				heap.Push(entriesHeap, entry)
			}
		}
	}()
	go func() {
		defer collectorWg.Done()
		for file := range largeFileChan {
			// Maintain Top N Heap for large files
			if largeFilesHeap.Len() < maxLargeFiles {
				heap.Push(largeFilesHeap, file)
			} else if file.Size > (*largeFilesHeap)[0].Size {
				heap.Pop(largeFilesHeap)
				heap.Push(largeFilesHeap, file)
			}
		}
	}()

	isRootDir := root == "/"
	home := os.Getenv("HOME")
	isHomeDir := home != "" && root == home

	for _, child := range children {
		fullPath := filepath.Join(root, child.Name())

		// Skip symlinks to avoid following them into unexpected locations
		// Use Type() instead of IsDir() to check without following symlinks
		if child.Type()&fs.ModeSymlink != 0 {
			// For symlinks, check if they point to a directory
			targetInfo, err := os.Stat(fullPath)
			isDir := false
			if err == nil && targetInfo.IsDir() {
				isDir = true
			}

			// Get symlink size (we don't effectively count the target size towards parent to avoid double counting,
			// or we just count the link size itself. Existing logic counts 'size' via getActualFileSize on the link info).
			// Ideally we just want navigation.
			// Re-fetching info for link itself if needed, but child.Info() does that.
			info, err := child.Info()
			if err != nil {
				continue
			}
			size := getActualFileSize(fullPath, info)
			atomic.AddInt64(&total, size)

			entryChan <- dirEntry{
				Name:       child.Name() + " →", // Add arrow to indicate symlink
				Path:       fullPath,
				Size:       size,
				IsDir:      isDir, // Allow navigation if target is directory
				LastAccess: getLastAccessTimeFromInfo(info),
			}
			continue
		}

		if child.IsDir() {
			// Check if directory should be skipped based on user configuration
			if defaultSkipDirs[child.Name()] {
				continue
			}

			// In root directory, skip system directories completely
			if isRootDir && skipSystemDirs[child.Name()] {
				continue
			}

			// Special handling for ~/Library - reuse cache to avoid duplicate scanning
			// This is scanned separately in overview mode
			if isHomeDir && child.Name() == "Library" {
				wg.Add(1)
				go func(name, path string) {
					defer wg.Done()
					sem <- struct{}{}
					defer func() { <-sem }()

					var size int64
					// Try overview cache first (from overview scan)
					if cached, err := loadStoredOverviewSize(path); err == nil && cached > 0 {
						size = cached
					} else if cached, err := loadCacheFromDisk(path); err == nil {
						// Try disk cache
						size = cached.TotalSize
					} else {
						// No cache available, scan normally
						size = calculateDirSizeConcurrent(path, largeFileChan, filesScanned, dirsScanned, bytesScanned, currentPath)
					}
					atomic.AddInt64(&total, size)
					atomic.AddInt64(dirsScanned, 1)

					entryChan <- dirEntry{
						Name:       name,
						Path:       path,
						Size:       size,
						IsDir:      true,
						LastAccess: time.Time{},
					}
				}(child.Name(), fullPath)
				continue
			}

			// For folded directories, calculate size quickly without expanding
			if shouldFoldDirWithPath(child.Name(), fullPath) {
				wg.Add(1)
				go func(name, path string) {
					defer wg.Done()
					sem <- struct{}{}
					defer func() { <-sem }()

					// Try du command first for folded dirs (much faster)
					size, err := getDirectorySizeFromDu(path)
					if err != nil || size <= 0 {
						// Fallback to concurrent walk if du fails
						size = calculateDirSizeFast(path, filesScanned, dirsScanned, bytesScanned, currentPath)
					}
					atomic.AddInt64(&total, size)
					atomic.AddInt64(dirsScanned, 1)

					entryChan <- dirEntry{
						Name:       name,
						Path:       path,
						Size:       size,
						IsDir:      true,
						LastAccess: time.Time{}, // Lazy load when displayed
					}
				}(child.Name(), fullPath)
				continue
			}

			// Normal directory: full scan with detail
			wg.Add(1)
			go func(name, path string) {
				defer wg.Done()
				sem <- struct{}{}
				defer func() { <-sem }()

				size := calculateDirSizeConcurrent(path, largeFileChan, filesScanned, dirsScanned, bytesScanned, currentPath)
				atomic.AddInt64(&total, size)
				atomic.AddInt64(dirsScanned, 1)

				entryChan <- dirEntry{
					Name:       name,
					Path:       path,
					Size:       size,
					IsDir:      true,
					LastAccess: time.Time{}, // Lazy load when displayed
				}
			}(child.Name(), fullPath)
			continue
		}

		info, err := child.Info()
		if err != nil {
			continue
		}
		// Get actual disk usage for sparse files and cloud files
		size := getActualFileSize(fullPath, info)
		atomic.AddInt64(&total, size)
		atomic.AddInt64(filesScanned, 1)
		atomic.AddInt64(bytesScanned, size)

		entryChan <- dirEntry{
			Name:       child.Name(),
			Path:       fullPath,
			Size:       size,
			IsDir:      false,
			LastAccess: getLastAccessTimeFromInfo(info),
		}
		// Only track large files that are not code/text files
		if !shouldSkipFileForLargeTracking(fullPath) && size >= minLargeFileSize {
			largeFileChan <- fileEntry{Name: child.Name(), Path: fullPath, Size: size}
		}
	}

	wg.Wait()

	// Close channels and wait for collectors to finish
	close(entryChan)
	close(largeFileChan)
	collectorWg.Wait()

	// Convert Heaps to sorted slices (Descending order)
	entries := make([]dirEntry, entriesHeap.Len())
	for i := len(entries) - 1; i >= 0; i-- {
		entries[i] = heap.Pop(entriesHeap).(dirEntry)
	}

	largeFiles := make([]fileEntry, largeFilesHeap.Len())
	for i := len(largeFiles) - 1; i >= 0; i-- {
		largeFiles[i] = heap.Pop(largeFilesHeap).(fileEntry)
	}

	// Try to use Spotlight (mdfind) for faster large file discovery
	// This is a performance optimization that gracefully falls back to scan results
	// if Spotlight is unavailable or fails. The fallback is intentionally silent
	// because users only care about correct results, not the method used.
	if spotlightFiles := findLargeFilesWithSpotlight(root, minLargeFileSize); len(spotlightFiles) > 0 {
		// Spotlight results are already sorted top N
		// Use them in place of scanned large files
		largeFiles = spotlightFiles
	}

	// Double check sorting consistency (Spotlight returns sorted, but heap pop handles scan results)
	// If needed, we could re-sort largeFiles, but heap pop ensures ascending, and we filled reverse, so it's Descending.
	// Spotlight returns Descending. So no extra sort needed for either.

	return scanResult{
		Entries:    entries,
		LargeFiles: largeFiles,
		TotalSize:  total,
	}, nil
}

func shouldFoldDirWithPath(name, path string) bool {
	// Check basic fold list first
	if foldDirs[name] {
		return true
	}

	// Special case: npm cache directories - fold all subdirectories
	// This includes: .npm/_quick/*, .npm/_cacache/*, .npm/a-z/*, .tnpm/*
	if strings.Contains(path, "/.npm/") || strings.Contains(path, "/.tnpm/") {
		// Get the parent directory name
		parent := filepath.Base(filepath.Dir(path))
		// If parent is a cache folder (_quick, _cacache, etc) or npm dir itself, fold it
		if parent == ".npm" || parent == ".tnpm" || strings.HasPrefix(parent, "_") {
			return true
		}
		// Also fold single-letter subdirectories (npm cache structure like .npm/a/, .npm/b/)
		if len(name) == 1 {
			return true
		}
	}

	return false
}

func shouldSkipFileForLargeTracking(path string) bool {
	ext := strings.ToLower(filepath.Ext(path))
	return skipExtensions[ext]
}

// calculateDirSizeFast performs concurrent directory size calculation using os.ReadDir
// This is a faster fallback than filepath.WalkDir when du fails
func calculateDirSizeFast(root string, filesScanned, dirsScanned, bytesScanned *int64, currentPath *string) int64 {
	var total int64
	var wg sync.WaitGroup

	// Create context with timeout
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	// Limit total concurrency for this walk
	concurrency := runtime.NumCPU() * 4
	if concurrency > 64 {
		concurrency = 64
	}
	sem := make(chan struct{}, concurrency)

	var walk func(string)
	walk = func(dirPath string) {
		select {
		case <-ctx.Done():
			return
		default:
		}

		if currentPath != nil && atomic.LoadInt64(filesScanned)%int64(batchUpdateSize) == 0 {
			*currentPath = dirPath
		}

		entries, err := os.ReadDir(dirPath)
		if err != nil {
			return
		}

		var localBytes, localFiles int64

		for _, entry := range entries {
			if entry.IsDir() {
				// Directories: recurse concurrently
				wg.Add(1)
				// Capture loop variable
				subDir := filepath.Join(dirPath, entry.Name())
				go func(p string) {
					defer wg.Done()
					sem <- struct{}{}        // Acquire token
					defer func() { <-sem }() // Release token
					walk(p)
				}(subDir)
				atomic.AddInt64(dirsScanned, 1)
			} else {
				// Files: process immediately
				info, err := entry.Info()
				if err == nil {
					size := getActualFileSize(filepath.Join(dirPath, entry.Name()), info)
					localBytes += size
					localFiles++
				}
			}
		}

		if localBytes > 0 {
			atomic.AddInt64(&total, localBytes)
			atomic.AddInt64(bytesScanned, localBytes)
		}
		if localFiles > 0 {
			atomic.AddInt64(filesScanned, localFiles)
		}
	}

	walk(root)
	wg.Wait()

	return total
}

// Use Spotlight (mdfind) to quickly find large files in a directory
func findLargeFilesWithSpotlight(root string, minSize int64) []fileEntry {
	// mdfind query: files >= minSize in the specified directory
	query := fmt.Sprintf("kMDItemFSSize >= %d", minSize)

	ctx, cancel := context.WithTimeout(context.Background(), mdlsTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "mdfind", "-onlyin", root, query)
	output, err := cmd.Output()
	if err != nil {
		// Fallback: mdfind not available or failed
		return nil
	}

	lines := strings.Split(strings.TrimSpace(string(output)), "\n")
	var files []fileEntry

	for _, line := range lines {
		if line == "" {
			continue
		}

		// Filter out code files first (cheapest check, no I/O)
		if shouldSkipFileForLargeTracking(line) {
			continue
		}

		// Filter out files in folded directories (cheap string check)
		if isInFoldedDir(line) {
			continue
		}

		// Use Lstat instead of Stat (faster, doesn't follow symlinks)
		info, err := os.Lstat(line)
		if err != nil {
			continue
		}

		// Skip if it's a directory or symlink
		if info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			continue
		}

		// Get actual disk usage for sparse files and cloud files
		actualSize := getActualFileSize(line, info)
		files = append(files, fileEntry{
			Name: filepath.Base(line),
			Path: line,
			Size: actualSize,
		})
	}

	// Sort by size (descending)
	sort.Slice(files, func(i, j int) bool {
		return files[i].Size > files[j].Size
	})

	// Return top N
	if len(files) > maxLargeFiles {
		files = files[:maxLargeFiles]
	}

	return files
}

// isInFoldedDir checks if a path is inside a folded directory (optimized)
func isInFoldedDir(path string) bool {
	// Split path into components for faster checking
	parts := strings.Split(path, string(os.PathSeparator))
	for _, part := range parts {
		if foldDirs[part] {
			return true
		}
	}
	return false
}

func calculateDirSizeConcurrent(root string, largeFileChan chan<- fileEntry, filesScanned, dirsScanned, bytesScanned *int64, currentPath *string) int64 {
	// Read immediate children
	children, err := os.ReadDir(root)
	if err != nil {
		return 0
	}

	var total int64
	var wg sync.WaitGroup

	// Limit concurrent subdirectory scans to avoid too many goroutines
	maxConcurrent := runtime.NumCPU() * 2
	if maxConcurrent > maxDirWorkers {
		maxConcurrent = maxDirWorkers
	}
	sem := make(chan struct{}, maxConcurrent)

	for _, child := range children {
		fullPath := filepath.Join(root, child.Name())

		// Skip symlinks to avoid following them into unexpected locations
		if child.Type()&fs.ModeSymlink != 0 {
			// For symlinks, just count their size without following
			info, err := child.Info()
			if err != nil {
				continue
			}
			size := getActualFileSize(fullPath, info)
			total += size
			atomic.AddInt64(filesScanned, 1)
			atomic.AddInt64(bytesScanned, size)
			continue
		}

		if child.IsDir() {
			// Check if this is a folded directory
			if shouldFoldDirWithPath(child.Name(), fullPath) {
				// Use du for folded directories (much faster)
				wg.Add(1)
				go func(path string) {
					defer wg.Done()
					size, err := getDirectorySizeFromDu(path)
					if err == nil && size > 0 {
						atomic.AddInt64(&total, size)
						atomic.AddInt64(bytesScanned, size)
						atomic.AddInt64(dirsScanned, 1)
					}
				}(fullPath)
				continue
			}

			// Recursively scan subdirectory in parallel
			wg.Add(1)
			go func(path string) {
				defer wg.Done()
				sem <- struct{}{}
				defer func() { <-sem }()

				size := calculateDirSizeConcurrent(path, largeFileChan, filesScanned, dirsScanned, bytesScanned, currentPath)
				atomic.AddInt64(&total, size)
				atomic.AddInt64(dirsScanned, 1)
			}(fullPath)
			continue
		}

		// Handle files
		info, err := child.Info()
		if err != nil {
			continue
		}

		size := getActualFileSize(fullPath, info)
		total += size
		atomic.AddInt64(filesScanned, 1)
		atomic.AddInt64(bytesScanned, size)

		// Track large files
		if !shouldSkipFileForLargeTracking(fullPath) && size >= minLargeFileSize {
			largeFileChan <- fileEntry{Name: child.Name(), Path: fullPath, Size: size}
		}

		// Update current path occasionally to prevent UI jitter
		if currentPath != nil && atomic.LoadInt64(filesScanned)%int64(batchUpdateSize) == 0 {
			*currentPath = fullPath
		}
	}

	wg.Wait()
	return total
}

// measureOverviewSize calculates the size of a directory using multiple strategies.
// When scanning Home, it excludes ~/Library to avoid duplicate counting.
func measureOverviewSize(path string) (int64, error) {
	if path == "" {
		return 0, fmt.Errorf("empty path")
	}

	path = filepath.Clean(path)
	if !filepath.IsAbs(path) {
		return 0, fmt.Errorf("path must be absolute: %s", path)
	}

	if _, err := os.Stat(path); err != nil {
		return 0, fmt.Errorf("cannot access path: %v", err)
	}

	// Determine if we should exclude ~/Library (when scanning Home)
	home := os.Getenv("HOME")
	excludePath := ""
	if home != "" && path == home {
		excludePath = filepath.Join(home, "Library")
	}

	if cached, err := loadStoredOverviewSize(path); err == nil && cached > 0 {
		return cached, nil
	}

	if duSize, err := getDirectorySizeFromDuWithExclude(path, excludePath); err == nil && duSize > 0 {
		_ = storeOverviewSize(path, duSize)
		return duSize, nil
	}

	if logicalSize, err := getDirectoryLogicalSizeWithExclude(path, excludePath); err == nil && logicalSize > 0 {
		_ = storeOverviewSize(path, logicalSize)
		return logicalSize, nil
	}

	if cached, err := loadCacheFromDisk(path); err == nil {
		_ = storeOverviewSize(path, cached.TotalSize)
		return cached.TotalSize, nil
	}

	return 0, fmt.Errorf("unable to measure directory size with fast methods")
}

func getDirectorySizeFromDu(path string) (int64, error) {
	return getDirectorySizeFromDuWithExclude(path, "")
}

func getDirectorySizeFromDuWithExclude(path string, excludePath string) (int64, error) {
	runDuSize := func(target string) (int64, error) {
		if _, err := os.Stat(target); err != nil {
			return 0, err
		}

		ctx, cancel := context.WithTimeout(context.Background(), duTimeout)
		defer cancel()

		cmd := exec.CommandContext(ctx, "du", "-sk", target)
		var stdout, stderr bytes.Buffer
		cmd.Stdout = &stdout
		cmd.Stderr = &stderr

		if err := cmd.Run(); err != nil {
			if ctx.Err() == context.DeadlineExceeded {
				return 0, fmt.Errorf("du timeout after %v", duTimeout)
			}
			if stderr.Len() > 0 {
				return 0, fmt.Errorf("du failed: %v (%s)", err, stderr.String())
			}
			return 0, fmt.Errorf("du failed: %v", err)
		}
		fields := strings.Fields(stdout.String())
		if len(fields) == 0 {
			return 0, fmt.Errorf("du output empty")
		}
		kb, err := strconv.ParseInt(fields[0], 10, 64)
		if err != nil {
			return 0, fmt.Errorf("failed to parse du output: %v", err)
		}
		if kb <= 0 {
			return 0, fmt.Errorf("du size invalid: %d", kb)
		}
		return kb * 1024, nil
	}

	// When excluding a path (e.g., ~/Library), subtract only that exact directory instead of ignoring every "Library"
	if excludePath != "" {
		totalSize, err := runDuSize(path)
		if err != nil {
			return 0, err
		}
		excludeSize, err := runDuSize(excludePath)
		if err != nil {
			if !os.IsNotExist(err) {
				return 0, err
			}
			excludeSize = 0
		}
		if excludeSize > totalSize {
			excludeSize = 0
		}
		return totalSize - excludeSize, nil
	}

	return runDuSize(path)
}

func getDirectoryLogicalSizeWithExclude(path string, excludePath string) (int64, error) {
	var total int64
	err := filepath.WalkDir(path, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			if os.IsPermission(err) {
				return filepath.SkipDir
			}
			return nil
		}
		// Skip excluded path
		if excludePath != "" && p == excludePath {
			return filepath.SkipDir
		}
		if d.IsDir() {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		total += getActualFileSize(p, info)
		return nil
	})
	if err != nil && err != filepath.SkipDir {
		return 0, err
	}
	return total, nil
}

func getActualFileSize(_ string, info fs.FileInfo) int64 {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return info.Size()
	}

	actualSize := stat.Blocks * 512
	if actualSize < info.Size() {
		return actualSize
	}
	return info.Size()
}

func getLastAccessTime(path string) time.Time {
	info, err := os.Stat(path)
	if err != nil {
		return time.Time{}
	}
	return getLastAccessTimeFromInfo(info)
}

func getLastAccessTimeFromInfo(info fs.FileInfo) time.Time {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return time.Time{}
	}
	return time.Unix(stat.Atimespec.Sec, stat.Atimespec.Nsec)
}
