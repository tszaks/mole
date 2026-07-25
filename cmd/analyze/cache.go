//go:build darwin

package main

import (
	"container/heap"
	"context"
	"encoding/gob"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"time"

	"github.com/cespare/xxhash/v2"
)

// cacheSchemaVersion is bumped whenever directory-size semantics change so
// stale on-disk cache entries are rejected instead of silently reused.
// v2: analyze deduplicates hardlinked files to match `du`.
const cacheSchemaVersion = 2

type overviewSizeSnapshot struct {
	Size    int64     `json:"size"`
	Updated time.Time `json:"updated"`
}

var (
	overviewSnapshotMu     sync.Mutex
	overviewSnapshotCache  map[string]overviewSizeSnapshot
	overviewSnapshotLoaded bool
)

func snapshotFromModel(m model) historyEntry {
	return historyEntry{
		Path:          m.path,
		Entries:       slices.Clone(m.entries),
		LargeFiles:    slices.Clone(m.largeFiles),
		TotalSize:     m.totalSize,
		TotalFiles:    m.totalFiles,
		Selected:      m.selected,
		EntryOffset:   m.offset,
		LargeSelected: m.largeSelected,
		LargeOffset:   m.largeOffset,
		NeedsRefresh:  m.viewNeedsRefresh || m.scanning,
		IsOverview:    m.isOverview,
	}
}

func filterNonEmptyEntries(entries []dirEntry) []dirEntry {
	filtered := make([]dirEntry, 0, len(entries))
	for _, entry := range entries {
		if entry.Size > 0 {
			filtered = append(filtered, entry)
		}
	}
	return filtered
}

func historyEntryFromScanResult(path string, result scanResult, previous historyEntry, needsRefresh bool) historyEntry {
	entry := historyEntry{
		Path:          path,
		Entries:       slices.Clone(result.Entries),
		LargeFiles:    slices.Clone(result.LargeFiles),
		TotalSize:     result.TotalSize,
		TotalFiles:    result.TotalFiles,
		Selected:      previous.Selected,
		EntryOffset:   previous.EntryOffset,
		LargeSelected: previous.LargeSelected,
		LargeOffset:   previous.LargeOffset,
		NeedsRefresh:  needsRefresh,
		IsOverview:    previous.IsOverview,
	}
	return entry
}

func ensureOverviewSnapshotCacheLocked() error {
	if overviewSnapshotLoaded {
		return nil
	}
	storePath, err := getOverviewSizeStorePath()
	if err != nil {
		return err
	}
	data, err := os.ReadFile(storePath)
	if err != nil {
		if os.IsNotExist(err) {
			overviewSnapshotCache = make(map[string]overviewSizeSnapshot)
			overviewSnapshotLoaded = true
			return nil
		}
		return err
	}
	if len(data) == 0 {
		overviewSnapshotCache = make(map[string]overviewSizeSnapshot)
		overviewSnapshotLoaded = true
		return nil
	}
	var snapshots map[string]overviewSizeSnapshot
	if err := json.Unmarshal(data, &snapshots); err != nil || snapshots == nil {
		backupPath := storePath + ".corrupt"
		_ = os.Rename(storePath, backupPath)
		overviewSnapshotCache = make(map[string]overviewSizeSnapshot)
		overviewSnapshotLoaded = true
		return nil
	}
	overviewSnapshotCache = snapshots
	overviewSnapshotLoaded = true
	return nil
}

func getOverviewSizeStorePath() (string, error) {
	cacheDir, err := getCacheDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(cacheDir, overviewCacheFile), nil
}

func loadStoredOverviewSize(path string) (int64, error) {
	if path == "" {
		return 0, fmt.Errorf("empty path")
	}
	overviewSnapshotMu.Lock()
	defer overviewSnapshotMu.Unlock()
	if err := ensureOverviewSnapshotCacheLocked(); err != nil {
		return 0, err
	}
	if overviewSnapshotCache == nil {
		return 0, fmt.Errorf("snapshot cache unavailable")
	}
	if snapshot, ok := overviewSnapshotCache[path]; ok && snapshot.Size > 0 {
		if time.Since(snapshot.Updated) < overviewCacheTTL {
			return snapshot.Size, nil
		}
		return 0, fmt.Errorf("snapshot expired")
	}
	return 0, fmt.Errorf("snapshot not found")
}

func storeOverviewSize(path string, size int64) error {
	if path == "" || size <= 0 {
		return fmt.Errorf("invalid overview size")
	}
	overviewSnapshotMu.Lock()
	defer overviewSnapshotMu.Unlock()
	if err := ensureOverviewSnapshotCacheLocked(); err != nil {
		return err
	}
	if overviewSnapshotCache == nil {
		overviewSnapshotCache = make(map[string]overviewSizeSnapshot)
	}
	overviewSnapshotCache[path] = overviewSizeSnapshot{
		Size:    size,
		Updated: time.Now(),
	}
	return persistOverviewSnapshotLocked()
}

func persistOverviewSnapshotLocked() error {
	storePath, err := getOverviewSizeStorePath()
	if err != nil {
		return err
	}
	tmpPath := storePath + ".tmp"
	data, err := json.MarshalIndent(overviewSnapshotCache, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(tmpPath, data, 0644); err != nil {
		return err
	}
	return os.Rename(tmpPath, storePath)
}

func loadOverviewCachedSize(path string) (int64, error) {
	if path == "" {
		return 0, fmt.Errorf("empty path")
	}
	if snapshot, err := loadStoredOverviewSize(path); err == nil {
		return snapshot, nil
	}
	cacheEntry, err := loadCacheFromDisk(path)
	if err != nil {
		return 0, err
	}
	_ = storeOverviewSize(path, cacheEntry.TotalSize)
	return cacheEntry.TotalSize, nil
}

// getMoleCacheRoot is the shared `~/.cache/mole` directory. The shell side
// keeps its own state files there, so nothing may be swept from it wholesale.
func getMoleCacheRoot() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".cache", "mole"), nil
}

// getCacheDir is the analyzer-owned subdirectory. Keeping analyzer entries out
// of the shared root is what lets the legacy sweep and the entry caps operate
// on a directory whose every file the analyzer owns.
func getCacheDir() (string, error) {
	root, err := getMoleCacheRoot()
	if err != nil {
		return "", err
	}
	cacheDir := filepath.Join(root, analyzerCacheDirName)
	if err := os.MkdirAll(cacheDir, 0755); err != nil {
		return "", err
	}
	return cacheDir, nil
}

func getCachePath(path string) (string, error) {
	cacheDir, err := getCacheDir()
	if err != nil {
		return "", err
	}
	hash := xxhash.Sum64String(path)
	filename := fmt.Sprintf("%x.cache", hash)
	return filepath.Join(cacheDir, filename), nil
}

// shouldPersistSubdirCache decides whether a scanned subtree earns a cache
// file. Memoizing a directory that holds a handful of files costs more than it
// saves: the entry occupies a whole 4KB block plus an inode, and reading it
// back is slower than the single readdir it replaces. Only subtrees expensive
// enough to rescan are persisted; see the budget comment in constants.go.
func shouldPersistSubdirCache(result scanResult) bool {
	return result.TotalFiles >= subdirCacheMinFiles || result.TotalSize >= subdirCacheMinSize
}

// removeCacheEntry drops a cache file that can never be useful again (its
// schema is gone, it failed to decode, its directory no longer exists, or it
// outlived the TTL). Expiring an entry only at load time used to leave the file
// on disk until a prune pass happened to reach it, which is how a store grows
// far past what any scan still reads.
//
// Deliberately not invalidateCache: that also drops the overview snapshot,
// which rewrites the whole JSON store under a lock. This runs per entry inside
// a scan, so it stays a single unlink.
func removeCacheEntry(path string) {
	if cachePath, err := getCachePath(path); err == nil {
		_ = os.Remove(cachePath)
	}
}

// cacheFileStat is the eviction record for one analyzer cache file.
type cacheFileStat struct {
	name    string
	modTime time.Time
	size    int64
}

// oldestFirstHeap is a min-heap by mod time, so the root is always the next
// entry to evict. Retaining the newest N through a bounded heap keeps prune's
// memory tied to the cap instead of to the directory it is pruning.
type oldestFirstHeap []cacheFileStat

func (h oldestFirstHeap) Len() int           { return len(h) }
func (h oldestFirstHeap) Less(i, j int) bool { return h[i].modTime.Before(h[j].modTime) }
func (h oldestFirstHeap) Swap(i, j int)      { h[i], h[j] = h[j], h[i] }
func (h *oldestFirstHeap) Push(x any)        { *h = append(*h, x.(cacheFileStat)) }
func (h *oldestFirstHeap) Pop() any {
	old := *h
	n := len(old)
	x := old[n-1]
	*h = old[0 : n-1]
	return x
}

func pruneAnalyzerCache() {
	// Best-effort throughout; errors are ignored so startup never blocks on
	// cache housekeeping.
	if root, err := getMoleCacheRoot(); err == nil {
		_ = sweepLegacyAnalyzerCache(root)
	}
	cacheDir, err := getCacheDir()
	if err != nil {
		return
	}
	_ = pruneAnalyzerCacheDir(cacheDir, time.Now())
}

// pruneAnalyzerCacheDir removes expired entries and then enforces the count and
// byte caps, evicting oldest first. The directory is streamed in batches rather
// than read whole: os.ReadDir buffers and sorts every name, which is exactly
// what an oversized store cannot afford.
func pruneAnalyzerCacheDir(cacheDir string, now time.Time) error {
	return pruneAnalyzerCacheDirWithLimits(cacheDir, now, analyzerCacheMaxEntries, analyzerCacheMaxBytes)
}

// maxEntries must stay positive: it is what bounds the retained heap, and with
// it the memory this pass needs. A non-positive maxBytes just disables the byte
// cap.
func pruneAnalyzerCacheDirWithLimits(cacheDir string, now time.Time, maxEntries int, maxBytes int64) error {
	if cacheDir == "" || analyzerCacheTTL <= 0 {
		return nil
	}

	dir, err := os.Open(cacheDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	defer dir.Close() //nolint:errcheck

	cutoff := now.Add(-analyzerCacheTTL)
	retained := &oldestFirstHeap{}
	var retainedBytes int64

	evictOldest := func() {
		if retained.Len() == 0 {
			return
		}
		oldest := heap.Pop(retained).(cacheFileStat)
		retainedBytes -= oldest.size
		_ = os.Remove(filepath.Join(cacheDir, oldest.name))
	}

	for {
		entries, readErr := dir.ReadDir(cacheDirReadBatch)
		for _, entry := range entries {
			if entry.Type()&os.ModeSymlink != 0 || filepath.Ext(entry.Name()) != ".cache" {
				continue
			}

			info, infoErr := entry.Info()
			if infoErr != nil || !info.Mode().IsRegular() {
				continue
			}
			if !info.ModTime().After(cutoff) {
				_ = os.Remove(filepath.Join(cacheDir, entry.Name()))
				continue
			}

			heap.Push(retained, cacheFileStat{
				name:    entry.Name(),
				modTime: info.ModTime(),
				size:    info.Size(),
			})
			retainedBytes += info.Size()
			if maxEntries > 0 && retained.Len() > maxEntries {
				evictOldest()
			}
		}
		if readErr != nil {
			if errors.Is(readErr, io.EOF) {
				break
			}
			return readErr
		}
		if len(entries) == 0 {
			break
		}
	}

	for maxBytes > 0 && retained.Len() > 0 && retainedBytes > maxBytes {
		evictOldest()
	}

	return nil
}

// sweepLegacyAnalyzerCache removes the flat `<hash>.cache` entries the analyzer
// used to write directly into `~/.cache/mole`, plus the overview snapshot that
// sat beside them. Everything else in that directory belongs to the shell side
// and is left alone.
//
// The sweep streams the directory rather than reading it whole, so a legacy
// store with millions of entries is never held in memory, and it is resumable:
// whatever a short-lived process does not reach is picked up by the next run.
// Unlinks are spread over a few workers because a single one clears roughly
// 7k files/s on APFS, which is a long tail on the largest stores seen in the
// wild (1.88M files); the small pool roughly doubles that without turning
// housekeeping into a competitor for the scan itself.
func sweepLegacyAnalyzerCache(root string) error {
	if root == "" {
		return nil
	}

	dir, err := os.Open(root)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	defer dir.Close() //nolint:errcheck

	names := make(chan string, cacheDirReadBatch)
	var workers sync.WaitGroup
	for range legacySweepWorkers {
		workers.Go(func() {
			for name := range names {
				_ = os.Remove(filepath.Join(root, name))
			}
		})
	}
	defer func() {
		close(names)
		workers.Wait()
	}()

	for {
		entries, readErr := dir.ReadDir(cacheDirReadBatch)
		for _, entry := range entries {
			if !entry.Type().IsRegular() {
				continue
			}
			if filepath.Ext(entry.Name()) != ".cache" && entry.Name() != overviewCacheFile {
				continue
			}
			names <- entry.Name()
		}
		if readErr != nil {
			if errors.Is(readErr, io.EOF) {
				return nil
			}
			return readErr
		}
		if len(entries) == 0 {
			return nil
		}
	}
}

func loadRawCacheFromDisk(path string) (*cacheEntry, error) {
	cachePath, err := getCachePath(path)
	if err != nil {
		return nil, err
	}

	file, err := os.Open(cachePath)
	if err != nil {
		return nil, err
	}
	defer file.Close() //nolint:errcheck

	var entry cacheEntry
	decoder := gob.NewDecoder(file)
	if err := decoder.Decode(&entry); err != nil {
		// A truncated or foreign payload will never decode; keeping it only
		// costs a block until some prune pass reaches it.
		_ = os.Remove(cachePath)
		return nil, err
	}

	if entry.SchemaVersion != cacheSchemaVersion {
		_ = os.Remove(cachePath)
		return nil, fmt.Errorf("cache schema mismatch: got %d, want %d", entry.SchemaVersion, cacheSchemaVersion)
	}

	return &entry, nil
}

func loadCacheFromDisk(path string) (*cacheEntry, error) {
	entry, err := loadRawCacheFromDisk(path)
	if err != nil {
		return nil, err
	}

	info, err := os.Stat(path)
	if err != nil {
		// The directory is gone, so nothing will ever refresh or reuse this
		// entry. Churn-heavy trees (node_modules, simulator data) otherwise
		// leave one orphan per directory behind for a full TTL.
		if os.IsNotExist(err) {
			removeCacheEntry(path)
		}
		return nil, err
	}

	scanAge := time.Since(entry.ScanTime)
	if scanAge > analyzerCacheTTL {
		removeCacheEntry(path)
		return nil, fmt.Errorf("cache expired: too old")
	}

	if info.ModTime().After(entry.ModTime) {
		// Allow grace window.
		if cacheModTimeGrace <= 0 || info.ModTime().Sub(entry.ModTime) > cacheModTimeGrace {
			// Directory mod time is noisy on macOS; reuse recent cache to avoid
			// frequent full rescans while still forcing refresh for older entries.
			if cacheReuseWindow <= 0 || scanAge > cacheReuseWindow {
				return nil, fmt.Errorf("cache expired: directory modified")
			}
		}
	}

	return entry, nil
}

// loadStaleCacheFromDisk loads cache without strict freshness checks.
// It is used for fast first paint before triggering a background refresh.
func loadStaleCacheFromDisk(path string) (*cacheEntry, error) {
	entry, err := loadRawCacheFromDisk(path)
	if err != nil {
		return nil, err
	}

	if _, err := os.Stat(path); err != nil {
		if os.IsNotExist(err) {
			removeCacheEntry(path)
		}
		return nil, err
	}

	// Only the authoritative TTL deletes: staleCacheTTL is the shorter
	// first-paint window, and an entry past it is still valid for a full scan.
	if time.Since(entry.ScanTime) > staleCacheTTL {
		return nil, fmt.Errorf("stale cache expired")
	}

	return entry, nil
}

func saveCacheToDisk(path string, result scanResult) error {
	return saveCacheToDiskWithOptions(path, result, false)
}

func saveCacheToDiskWithOptions(path string, result scanResult, needsRefresh bool) error {
	cachePath, err := getCachePath(path)
	if err != nil {
		return err
	}

	info, err := os.Stat(path)
	if err != nil {
		return err
	}

	entry := cacheEntry{
		Entries:       result.Entries,
		LargeFiles:    result.LargeFiles,
		TotalSize:     result.TotalSize,
		TotalFiles:    result.TotalFiles,
		ModTime:       info.ModTime(),
		ScanTime:      time.Now(),
		NeedsRefresh:  needsRefresh,
		SchemaVersion: cacheSchemaVersion,
	}

	file, err := os.Create(cachePath)
	if err != nil {
		return err
	}
	defer file.Close() //nolint:errcheck

	encoder := gob.NewEncoder(file)
	return encoder.Encode(entry)
}

// peekCacheTotalFiles attempts to read the total file count from cache,
// ignoring expiration. Used for initial scan progress estimates.
func peekCacheTotalFiles(path string) (int64, error) {
	cachePath, err := getCachePath(path)
	if err != nil {
		return 0, err
	}

	file, err := os.Open(cachePath)
	if err != nil {
		return 0, err
	}
	defer file.Close() //nolint:errcheck

	var entry cacheEntry
	decoder := gob.NewDecoder(file)
	if err := decoder.Decode(&entry); err != nil {
		return 0, err
	}

	return entry.TotalFiles, nil
}

func invalidateCache(path string) {
	cachePath, err := getCachePath(path)
	if err == nil {
		_ = os.Remove(cachePath)
	}
	removeOverviewSnapshot(path)
}

// invalidateCacheTree invalidates the cache for path and all its direct
// child directories so that a rescan does not reuse stale subdirectory
// sizes. See #812.
func invalidateCacheTree(path string) {
	invalidateCache(path)
	children, err := os.ReadDir(path)
	if err != nil {
		return
	}
	for _, child := range children {
		if child.IsDir() {
			invalidateCache(filepath.Join(path, child.Name()))
		}
	}
}

func removeOverviewSnapshot(path string) {
	if path == "" {
		return
	}
	overviewSnapshotMu.Lock()
	defer overviewSnapshotMu.Unlock()
	if err := ensureOverviewSnapshotCacheLocked(); err != nil {
		return
	}
	if overviewSnapshotCache == nil {
		return
	}
	if _, ok := overviewSnapshotCache[path]; ok {
		delete(overviewSnapshotCache, path)
		_ = persistOverviewSnapshotLocked()
	}
}

// prefetchOverviewCache warms overview cache in background.
func prefetchOverviewCache(ctx context.Context) {
	entries := createOverviewEntries()

	var needScan []string
	for _, entry := range entries {
		if size, err := loadStoredOverviewSize(entry.Path); err == nil && size > 0 {
			continue
		}
		needScan = append(needScan, entry.Path)
	}

	if len(needScan) == 0 {
		return
	}

	sem := make(chan struct{}, maxConcurrentOverview)
	var wg sync.WaitGroup
	for _, path := range needScan {
		select {
		case <-ctx.Done():
			wg.Wait()
			return
		default:
		}

		wg.Go(func() {
			select {
			case sem <- struct{}{}:
				defer func() { <-sem }()
			case <-ctx.Done():
				return
			}

			size, err := measureOverviewSize(path)
			if err == nil && size > 0 {
				_ = storeOverviewSize(path, size)
			}
		})
	}
	wg.Wait()
}
