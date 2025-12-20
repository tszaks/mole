package main

import (
	"fmt"
	"os"
	"strings"
	"time"
)

func displayPath(path string) string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return path
	}
	if strings.HasPrefix(path, home) {
		return strings.Replace(path, home, "~", 1)
	}
	return path
}

// truncateMiddle truncates string in the middle, keeping head and tail.
func truncateMiddle(s string, maxWidth int) string {
	runes := []rune(s)
	currentWidth := displayWidth(s)

	if currentWidth <= maxWidth {
		return s
	}

	// Reserve 3 width for "..."
	if maxWidth < 10 {
		// Simple truncation for very small width
		width := 0
		for i, r := range runes {
			width += runeWidth(r)
			if width > maxWidth {
				return string(runes[:i])
			}
		}
		return s
	}

	// Keep more of the tail (filename usually more important)
	targetHeadWidth := (maxWidth - 3) / 3
	targetTailWidth := maxWidth - 3 - targetHeadWidth

	// Find head cutoff point based on display width
	headWidth := 0
	headIdx := 0
	for i, r := range runes {
		w := runeWidth(r)
		if headWidth+w > targetHeadWidth {
			break
		}
		headWidth += w
		headIdx = i + 1
	}

	// Find tail cutoff point
	tailWidth := 0
	tailIdx := len(runes)
	for i := len(runes) - 1; i >= 0; i-- {
		w := runeWidth(runes[i])
		if tailWidth+w > targetTailWidth {
			break
		}
		tailWidth += w
		tailIdx = i
	}

	return string(runes[:headIdx]) + "..." + string(runes[tailIdx:])
}

func formatNumber(n int64) string {
	if n < 1000 {
		return fmt.Sprintf("%d", n)
	}
	if n < 1000000 {
		return fmt.Sprintf("%.1fk", float64(n)/1000)
	}
	return fmt.Sprintf("%.1fM", float64(n)/1000000)
}

func humanizeBytes(size int64) string {
	if size < 0 {
		return "0 B"
	}
	const unit = 1024
	if size < unit {
		return fmt.Sprintf("%d B", size)
	}
	div, exp := int64(unit), 0
	for n := size / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	value := float64(size) / float64(div)
	return fmt.Sprintf("%.1f %cB", value, "KMGTPE"[exp])
}

func coloredProgressBar(value, max int64, percent float64) string {
	if max <= 0 {
		return colorGray + strings.Repeat("░", barWidth) + colorReset
	}

	filled := int((value * int64(barWidth)) / max)
	if filled > barWidth {
		filled = barWidth
	}

	// Choose color based on percentage
	var barColor string
	if percent >= 50 {
		barColor = colorRed
	} else if percent >= 20 {
		barColor = colorYellow
	} else if percent >= 5 {
		barColor = colorBlue
	} else {
		barColor = colorGreen
	}

	bar := barColor
	for i := 0; i < barWidth; i++ {
		if i < filled {
			if i < filled-1 {
				bar += "█"
			} else {
				remainder := (value * int64(barWidth)) % max
				if remainder > max/2 {
					bar += "█"
				} else if remainder > max/4 {
					bar += "▓"
				} else {
					bar += "▒"
				}
			}
		} else {
			bar += colorGray + "░" + barColor
		}
	}
	return bar + colorReset
}

// Calculate display width considering CJK characters.
func runeWidth(r rune) int {
	if r >= 0x4E00 && r <= 0x9FFF ||
		r >= 0x3400 && r <= 0x4DBF ||
		r >= 0xAC00 && r <= 0xD7AF ||
		r >= 0xFF00 && r <= 0xFFEF {
		return 2
	}
	return 1
}

func displayWidth(s string) int {
	width := 0
	for _, r := range s {
		width += runeWidth(r)
	}
	return width
}

// calculateNameWidth computes the optimal name column width based on terminal width.
// Fixed elements: prefix(3) + num(3) + bar(24) + percent(7) + sep(5) + icon(3) + size(12) + hint(4) = 61
func calculateNameWidth(termWidth int) int {
	const fixedWidth = 61
	available := termWidth - fixedWidth

	// Constrain to reasonable bounds
	if available < 24 {
		return 24 // Minimum for readability
	}
	if available > 60 {
		return 60 // Maximum to avoid overly wide columns
	}
	return available
}

func trimName(name string) string {
	return trimNameWithWidth(name, 45) // Default width for backward compatibility
}

func trimNameWithWidth(name string, maxWidth int) string {
	const (
		ellipsis      = "..."
		ellipsisWidth = 3
	)

	runes := []rune(name)
	widths := make([]int, len(runes))
	for i, r := range runes {
		widths[i] = runeWidth(r)
	}

	currentWidth := 0
	for i, w := range widths {
		if currentWidth+w > maxWidth {
			subWidth := currentWidth
			j := i
			for j > 0 && subWidth+ellipsisWidth > maxWidth {
				j--
				subWidth -= widths[j]
			}
			if j == 0 {
				return ellipsis
			}
			return string(runes[:j]) + ellipsis
		}
		currentWidth += w
	}

	return name
}

func padName(name string, targetWidth int) string {
	currentWidth := displayWidth(name)
	if currentWidth >= targetWidth {
		return name
	}
	return name + strings.Repeat(" ", targetWidth-currentWidth)
}

// formatUnusedTime formats the time since last access in a compact way.
func formatUnusedTime(lastAccess time.Time) string {
	if lastAccess.IsZero() {
		return ""
	}

	duration := time.Since(lastAccess)
	days := int(duration.Hours() / 24)

	if days < 90 {
		return ""
	}

	months := days / 30
	years := days / 365

	if years >= 2 {
		return fmt.Sprintf(">%dyr", years)
	} else if years >= 1 {
		return ">1yr"
	} else if months >= 3 {
		return fmt.Sprintf(">%dmo", months)
	}

	return ""
}
