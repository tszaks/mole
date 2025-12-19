package main

import (
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"

	tea "github.com/charmbracelet/bubbletea"
)

func deletePathCmd(path string, counter *int64) tea.Cmd {
	return func() tea.Msg {
		count, err := deletePathWithProgress(path, counter)
		return deleteProgressMsg{
			done:  true,
			err:   err,
			count: count,
			path:  path,
		}
	}
}

// deleteMultiplePathsCmd deletes multiple paths and returns combined results
func deleteMultiplePathsCmd(paths []string, counter *int64) tea.Cmd {
	return func() tea.Msg {
		var totalCount int64
		var errors []string

		for _, path := range paths {
			count, err := deletePathWithProgress(path, counter)
			totalCount += count
			if err != nil {
				errors = append(errors, err.Error())
			}
		}

		var resultErr error
		if len(errors) > 0 {
			resultErr = &multiDeleteError{errors: errors}
		}

		// Return empty path to trigger full refresh since multiple items were deleted
		return deleteProgressMsg{
			done:  true,
			err:   resultErr,
			count: totalCount,
			path:  "", // Empty path signals multiple deletions
		}
	}
}

// multiDeleteError holds multiple deletion errors
type multiDeleteError struct {
	errors []string
}

func (e *multiDeleteError) Error() string {
	if len(e.errors) == 1 {
		return e.errors[0]
	}
	return strings.Join(e.errors[:min(3, len(e.errors))], "; ")
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func deletePathWithProgress(root string, counter *int64) (int64, error) {
	var count int64
	var firstErr error

	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			// Skip permission errors but continue walking
			if os.IsPermission(err) {
				if firstErr == nil {
					firstErr = err
				}
				return filepath.SkipDir
			}
			// For other errors, record and continue
			if firstErr == nil {
				firstErr = err
			}
			return nil
		}

		if !d.IsDir() {
			if removeErr := os.Remove(path); removeErr == nil {
				count++
				if counter != nil {
					atomic.StoreInt64(counter, count)
				}
			} else if firstErr == nil {
				// Record first deletion error
				firstErr = removeErr
			}
		}

		return nil
	})

	// Track walk error separately
	if err != nil && firstErr == nil {
		firstErr = err
	}

	// Try to remove remaining directory structure
	// Even if this fails, we still report files deleted
	if removeErr := os.RemoveAll(root); removeErr != nil {
		if firstErr == nil {
			firstErr = removeErr
		}
	}

	// Always return count (even if there were errors), along with first error
	return count, firstErr
}
