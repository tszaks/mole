//go:build darwin

package main

import (
	"fmt"
	"strings"
	"sync/atomic"
)

// View renders the TUI display.
func (m model) View() string {
	var b strings.Builder
	fmt.Fprintln(&b)

	if m.inOverviewMode() {
		fmt.Fprintf(&b, "%sAnalyze Disk%s\n", colorPurpleBold, colorReset)
		if m.overviewScanning {
			// Check if we're in initial scan (all entries are pending)
			allPending := true
			for _, entry := range m.entries {
				if entry.Size >= 0 {
					allPending = false
					break
				}
			}

			if allPending {
				// Show prominent loading screen for initial scan
				fmt.Fprintf(&b, "%s%s%s%s Analyzing disk usage, please wait...%s\n",
					colorCyan, colorBold,
					spinnerFrames[m.spinner],
					colorReset, colorReset)
				return b.String()
			} else {
				// Progressive scanning - show subtle indicator
				fmt.Fprintf(&b, "%sSelect a location to explore:%s  ", colorGray, colorReset)
				fmt.Fprintf(&b, "%s%s%s%s Scanning...\n\n", colorCyan, colorBold, spinnerFrames[m.spinner], colorReset)
			}
		} else {
			// Check if there are still pending items
			hasPending := false
			for _, entry := range m.entries {
				if entry.Size < 0 {
					hasPending = true
					break
				}
			}
			if hasPending {
				fmt.Fprintf(&b, "%sSelect a location to explore:%s  ", colorGray, colorReset)
				fmt.Fprintf(&b, "%s%s%s%s Scanning...\n\n", colorCyan, colorBold, spinnerFrames[m.spinner], colorReset)
			} else {
				fmt.Fprintf(&b, "%sSelect a location to explore:%s\n\n", colorGray, colorReset)
			}
		}
	} else {
		fmt.Fprintf(&b, "%sAnalyze Disk%s  %s%s%s", colorPurpleBold, colorReset, colorGray, displayPath(m.path), colorReset)
		if !m.scanning {
			fmt.Fprintf(&b, "  |  Total: %s", humanizeBytes(m.totalSize))
		}
		fmt.Fprintf(&b, "\n\n")
	}

	if m.deleting {
		// Show delete progress
		count := int64(0)
		if m.deleteCount != nil {
			count = atomic.LoadInt64(m.deleteCount)
		}

		fmt.Fprintf(&b, "%s%s%s%s Deleting: %s%s items%s removed, please wait...\n",
			colorCyan, colorBold,
			spinnerFrames[m.spinner],
			colorReset,
			colorYellow, formatNumber(count), colorReset)

		return b.String()
	}

	if m.scanning {
		filesScanned, dirsScanned, bytesScanned := m.getScanProgress()

		fmt.Fprintf(&b, "%s%s%s%s Scanning: %s%s files%s, %s%s dirs%s, %s%s%s\n",
			colorCyan, colorBold,
			spinnerFrames[m.spinner],
			colorReset,
			colorYellow, formatNumber(filesScanned), colorReset,
			colorYellow, formatNumber(dirsScanned), colorReset,
			colorGreen, humanizeBytes(bytesScanned), colorReset)

		if m.currentPath != nil {
			currentPath := *m.currentPath
			if currentPath != "" {
				shortPath := displayPath(currentPath)
				shortPath = truncateMiddle(shortPath, 50)
				fmt.Fprintf(&b, "%s%s%s\n", colorGray, shortPath, colorReset)
			}
		}

		return b.String()
	}

	if m.showLargeFiles {
		if len(m.largeFiles) == 0 {
			fmt.Fprintln(&b, "  No large files found (>=100MB)")
		} else {
			viewport := calculateViewport(m.height, true)
			start := m.largeOffset
			if start < 0 {
				start = 0
			}
			end := start + viewport
			if end > len(m.largeFiles) {
				end = len(m.largeFiles)
			}
			maxLargeSize := int64(1)
			for _, file := range m.largeFiles {
				if file.Size > maxLargeSize {
					maxLargeSize = file.Size
				}
			}
			nameWidth := calculateNameWidth(m.width)
			for idx := start; idx < end; idx++ {
				file := m.largeFiles[idx]
				shortPath := displayPath(file.Path)
				shortPath = truncateMiddle(shortPath, nameWidth)
				paddedPath := padName(shortPath, nameWidth)
				entryPrefix := "   "
				nameColor := ""
				sizeColor := colorGray
				numColor := ""
				if idx == m.largeSelected {
					entryPrefix = fmt.Sprintf(" %s%s▶%s ", colorCyan, colorBold, colorReset)
					nameColor = colorCyan
					sizeColor = colorCyan
					numColor = colorCyan
				}
				size := humanizeBytes(file.Size)
				bar := coloredProgressBar(file.Size, maxLargeSize, 0)
				fmt.Fprintf(&b, "%s%s%2d.%s %s  |  📄 %s%s%s  %s%10s%s\n",
					entryPrefix, numColor, idx+1, colorReset, bar, nameColor, paddedPath, colorReset, sizeColor, size, colorReset)
			}
		}
	} else {
		if len(m.entries) == 0 {
			fmt.Fprintln(&b, "  Empty directory")
		} else {
			if m.inOverviewMode() {
				maxSize := int64(1)
				for _, entry := range m.entries {
					if entry.Size > maxSize {
						maxSize = entry.Size
					}
				}
				totalSize := m.totalSize
				nameWidth := calculateNameWidth(m.width)
				for idx, entry := range m.entries {
					icon := "📁"
					sizeVal := entry.Size
					barValue := sizeVal
					if barValue < 0 {
						barValue = 0
					}
					var percent float64
					if totalSize > 0 && sizeVal >= 0 {
						percent = float64(sizeVal) / float64(totalSize) * 100
					} else {
						percent = 0
					}
					percentStr := fmt.Sprintf("%5.1f%%", percent)
					if totalSize == 0 || sizeVal < 0 {
						percentStr = "  --  "
					}
					bar := coloredProgressBar(barValue, maxSize, percent)
					sizeText := "pending.."
					if sizeVal >= 0 {
						sizeText = humanizeBytes(sizeVal)
					}
					sizeColor := colorGray
					if sizeVal >= 0 && totalSize > 0 {
						switch {
						case percent >= 50:
							sizeColor = colorRed
						case percent >= 20:
							sizeColor = colorYellow
						case percent >= 5:
							sizeColor = colorBlue
						default:
							sizeColor = colorGray
						}
					}
					entryPrefix := "   "
					name := trimNameWithWidth(entry.Name, nameWidth)
					paddedName := padName(name, nameWidth)
					nameSegment := fmt.Sprintf("%s %s", icon, paddedName)
					numColor := ""
					percentColor := ""
					if idx == m.selected {
						entryPrefix = fmt.Sprintf(" %s%s▶%s ", colorCyan, colorBold, colorReset)
						nameSegment = fmt.Sprintf("%s%s %s%s", colorCyan, icon, paddedName, colorReset)
						numColor = colorCyan
						percentColor = colorCyan
						sizeColor = colorCyan
					}
					displayIndex := idx + 1

					// Priority: cleanable > unused time
					var hintLabel string
					if entry.IsDir && isCleanableDir(entry.Path) {
						hintLabel = fmt.Sprintf("%s🧹%s", colorYellow, colorReset)
					} else {
						// For overview mode, get access time on-demand if not set
						lastAccess := entry.LastAccess
						if lastAccess.IsZero() && entry.Path != "" {
							lastAccess = getLastAccessTime(entry.Path)
						}
						if unusedTime := formatUnusedTime(lastAccess); unusedTime != "" {
							hintLabel = fmt.Sprintf("%s%s%s", colorGray, unusedTime, colorReset)
						}
					}

					if hintLabel == "" {
						fmt.Fprintf(&b, "%s%s%2d.%s %s %s%s%s  |  %s %s%10s%s\n",
							entryPrefix, numColor, displayIndex, colorReset, bar, percentColor, percentStr, colorReset,
							nameSegment, sizeColor, sizeText, colorReset)
					} else {
						fmt.Fprintf(&b, "%s%s%2d.%s %s %s%s%s  |  %s %s%10s%s  %s\n",
							entryPrefix, numColor, displayIndex, colorReset, bar, percentColor, percentStr, colorReset,
							nameSegment, sizeColor, sizeText, colorReset, hintLabel)
					}
				}
			} else {
				// Normal mode with sizes and progress bars
				maxSize := int64(1)
				for _, entry := range m.entries {
					if entry.Size > maxSize {
						maxSize = entry.Size
					}
				}

				viewport := calculateViewport(m.height, false)
				nameWidth := calculateNameWidth(m.width)
				start := m.offset
				if start < 0 {
					start = 0
				}
				end := start + viewport
				if end > len(m.entries) {
					end = len(m.entries)
				}

				for idx := start; idx < end; idx++ {
					entry := m.entries[idx]
					icon := "📄"
					if entry.IsDir {
						icon = "📁"
					}
					size := humanizeBytes(entry.Size)
					name := trimNameWithWidth(entry.Name, nameWidth)
					paddedName := padName(name, nameWidth)

					// Calculate percentage
					percent := float64(entry.Size) / float64(m.totalSize) * 100
					percentStr := fmt.Sprintf("%5.1f%%", percent)

					// Get colored progress bar
					bar := coloredProgressBar(entry.Size, maxSize, percent)

					// Color the size based on magnitude
					var sizeColor string
					if percent >= 50 {
						sizeColor = colorRed
					} else if percent >= 20 {
						sizeColor = colorYellow
					} else if percent >= 5 {
						sizeColor = colorBlue
					} else {
						sizeColor = colorGray
					}

					// Keep chart columns aligned even when arrow is shown
					entryPrefix := "   "
					nameSegment := fmt.Sprintf("%s %s", icon, paddedName)
					numColor := ""
					percentColor := ""
					if idx == m.selected {
						entryPrefix = fmt.Sprintf(" %s%s▶%s ", colorCyan, colorBold, colorReset)
						nameSegment = fmt.Sprintf("%s%s %s%s", colorCyan, icon, paddedName, colorReset)
						numColor = colorCyan
						percentColor = colorCyan
						sizeColor = colorCyan
					}

					displayIndex := idx + 1

					// Priority: cleanable > unused time
					var hintLabel string
					if entry.IsDir && isCleanableDir(entry.Path) {
						hintLabel = fmt.Sprintf("%s🧹%s", colorYellow, colorReset)
					} else {
						// Get access time on-demand if not set
						lastAccess := entry.LastAccess
						if lastAccess.IsZero() && entry.Path != "" {
							lastAccess = getLastAccessTime(entry.Path)
						}
						if unusedTime := formatUnusedTime(lastAccess); unusedTime != "" {
							hintLabel = fmt.Sprintf("%s%s%s", colorGray, unusedTime, colorReset)
						}
					}

					if hintLabel == "" {
						fmt.Fprintf(&b, "%s%s%2d.%s %s %s%s%s  |  %s %s%10s%s\n",
							entryPrefix, numColor, displayIndex, colorReset, bar, percentColor, percentStr, colorReset,
							nameSegment, sizeColor, size, colorReset)
					} else {
						fmt.Fprintf(&b, "%s%s%2d.%s %s %s%s%s  |  %s %s%10s%s  %s\n",
							entryPrefix, numColor, displayIndex, colorReset, bar, percentColor, percentStr, colorReset,
							nameSegment, sizeColor, size, colorReset, hintLabel)
					}
				}
			}
		}
	}

	fmt.Fprintln(&b)
	if m.inOverviewMode() {
		// Show ← Back if there's history (entered from a parent directory)
		if len(m.history) > 0 {
			fmt.Fprintf(&b, "%s↑↓←→ | Enter | R Refresh | O Open | F File | ← Back | Q Quit%s\n", colorGray, colorReset)
		} else {
			fmt.Fprintf(&b, "%s↑↓→ | Enter | R Refresh | O Open | F File | Q Quit%s\n", colorGray, colorReset)
		}
	} else if m.showLargeFiles {
		fmt.Fprintf(&b, "%s↑↓← | R Refresh | O Open | F File | ⌫ Del | ← Back | Q Quit%s\n", colorGray, colorReset)
	} else {
		largeFileCount := len(m.largeFiles)
		if largeFileCount > 0 {
			fmt.Fprintf(&b, "%s↑↓←→ | Enter | R Refresh | O Open | F File | ⌫ Del | T Top(%d) | Q Quit%s\n", colorGray, largeFileCount, colorReset)
		} else {
			fmt.Fprintf(&b, "%s↑↓←→ | Enter | R Refresh | O Open | F File | ⌫ Del | Q Quit%s\n", colorGray, colorReset)
		}
	}
	if m.deleteConfirm && m.deleteTarget != nil {
		fmt.Fprintln(&b)
		fmt.Fprintf(&b, "%sDelete:%s %s (%s)  %sPress ⌫ again  |  ESC cancel%s\n",
			colorRed, colorReset,
			m.deleteTarget.Name, humanizeBytes(m.deleteTarget.Size),
			colorGray, colorReset)
	}
	return b.String()
}

// calculateViewport computes the number of visible items based on terminal height.
func calculateViewport(termHeight int, isLargeFiles bool) int {
	if termHeight <= 0 {
		// Terminal height unknown, use default
		return defaultViewport
	}

	// Calculate reserved space for UI elements
	reserved := 6 // header (3-4 lines) + footer (2 lines)
	if isLargeFiles {
		reserved = 5 // Large files view has less overhead
	}

	available := termHeight - reserved

	// Ensure minimum and maximum bounds
	if available < 1 {
		return 1 // Minimum 1 line for very short terminals
	}
	if available > 30 {
		return 30 // Maximum 30 lines to avoid information overload
	}

	return available
}
