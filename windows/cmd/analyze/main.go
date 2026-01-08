//go:build windows

package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// ANSI color codes
const (
	colorReset      = "\033[0m"
	colorBold       = "\033[1m"
	colorDim        = "\033[2m"
	colorPurple     = "\033[35m"
	colorPurpleBold = "\033[1;35m"
	colorCyan       = "\033[36m"
	colorCyanBold   = "\033[1;36m"
	colorYellow     = "\033[33m"
	colorGreen      = "\033[32m"
	colorRed        = "\033[31m"
	colorGray       = "\033[90m"
	colorWhite      = "\033[97m"
)

// Icons
const (
	iconFolder   = "📁"
	iconFile     = "📄"
	iconDisk     = "💾"
	iconClean    = "🧹"
	iconTrash    = "🗑️"
	iconBack     = "⬅️"
	iconSelected = "✓"
	iconArrow    = "➤"
)

// Cleanable directory patterns
var cleanablePatterns = map[string]bool{
	"node_modules":  true,
	"vendor":        true,
	".venv":         true,
	"venv":          true,
	"__pycache__":   true,
	".pytest_cache": true,
	"target":        true,
	"build":         true,
	"dist":          true,
	".next":         true,
	".nuxt":         true,
	".turbo":        true,
	".parcel-cache": true,
	"bin":           true,
	"obj":           true,
	".gradle":       true,
	".idea":         true,
	".vs":           true,
}

// Skip patterns for scanning
var skipPatterns = map[string]bool{
	"$Recycle.Bin":              true,
	"System Volume Information": true,
	"Windows":                   true,
	"Program Files":             true,
	"Program Files (x86)":       true,
	"ProgramData":               true,
	"Recovery":                  true,
	"Config.Msi":                true,
}

// Entry types
type dirEntry struct {
	Name        string
	Path        string
	Size        int64
	IsDir       bool
	LastAccess  time.Time
	IsCleanable bool
}

type fileEntry struct {
	Name string
	Path string
	Size int64
}

type historyEntry struct {
	Path       string
	Entries    []dirEntry
	LargeFiles []fileEntry
	TotalSize  int64
	Selected   int
}

// Model for Bubble Tea
type model struct {
	path           string
	entries        []dirEntry
	largeFiles     []fileEntry
	history        []historyEntry
	selected       int
	totalSize      int64
	scanning       bool
	showLargeFiles bool
	multiSelected  map[string]bool
	deleteConfirm  bool
	deleteTarget   string
	scanProgress   int64
	scanTotal      int64
	width          int
	height         int
	err            error
	cache          map[string]historyEntry
}

// Messages
type scanCompleteMsg struct {
	entries    []dirEntry
	largeFiles []fileEntry
	totalSize  int64
}

type scanProgressMsg struct {
	current int64
	total   int64
}

type scanErrorMsg struct {
	err error
}

type deleteCompleteMsg struct {
	path string
	err  error
}

func newModel(startPath string) model {
	return model{
		path:          startPath,
		entries:       []dirEntry{},
		largeFiles:    []fileEntry{},
		history:       []historyEntry{},
		selected:      0,
		scanning:      true,
		multiSelected: make(map[string]bool),
		cache:         make(map[string]historyEntry),
	}
}

func (m model) Init() tea.Cmd {
	return m.scanPath(m.path)
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		return m.handleKeyPress(msg)
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		return m, nil
	case scanCompleteMsg:
		m.entries = msg.entries
		m.largeFiles = msg.largeFiles
		m.totalSize = msg.totalSize
		m.scanning = false
		m.selected = 0
		// Cache result
		m.cache[m.path] = historyEntry{
			Path:       m.path,
			Entries:    msg.entries,
			LargeFiles: msg.largeFiles,
			TotalSize:  msg.totalSize,
		}
		return m, nil
	case scanProgressMsg:
		m.scanProgress = msg.current
		m.scanTotal = msg.total
		return m, nil
	case scanErrorMsg:
		m.err = msg.err
		m.scanning = false
		return m, nil
	case deleteCompleteMsg:
		m.deleteConfirm = false
		m.deleteTarget = ""
		if msg.err != nil {
			m.err = msg.err
		} else {
			// Rescan after delete
			m.scanning = true
			delete(m.cache, m.path)
			return m, m.scanPath(m.path)
		}
		return m, nil
	}
	return m, nil
}

func (m model) handleKeyPress(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	// Handle delete confirmation
	if m.deleteConfirm {
		switch msg.String() {
		case "y", "Y":
			target := m.deleteTarget
			m.deleteConfirm = false
			return m, m.deletePath(target)
		case "n", "N", "esc":
			m.deleteConfirm = false
			m.deleteTarget = ""
			return m, nil
		}
		return m, nil
	}

	switch msg.String() {
	case "q", "ctrl+c":
		return m, tea.Quit
	case "up", "k":
		if m.selected > 0 {
			m.selected--
		}
	case "down", "j":
		if m.selected < len(m.entries)-1 {
			m.selected++
		}
	case "enter", "right", "l":
		if !m.scanning && len(m.entries) > 0 {
			entry := m.entries[m.selected]
			if entry.IsDir {
				// Save current state to history
				m.history = append(m.history, historyEntry{
					Path:       m.path,
					Entries:    m.entries,
					LargeFiles: m.largeFiles,
					TotalSize:  m.totalSize,
					Selected:   m.selected,
				})
				m.path = entry.Path
				m.selected = 0
				m.multiSelected = make(map[string]bool)

				// Check cache
				if cached, ok := m.cache[entry.Path]; ok {
					m.entries = cached.Entries
					m.largeFiles = cached.LargeFiles
					m.totalSize = cached.TotalSize
					return m, nil
				}

				m.scanning = true
				return m, m.scanPath(entry.Path)
			}
		}
	case "left", "h", "backspace":
		if len(m.history) > 0 {
			last := m.history[len(m.history)-1]
			m.history = m.history[:len(m.history)-1]
			m.path = last.Path
			m.entries = last.Entries
			m.largeFiles = last.LargeFiles
			m.totalSize = last.TotalSize
			m.selected = last.Selected
			m.multiSelected = make(map[string]bool)
			m.scanning = false
		}
	case "space":
		if len(m.entries) > 0 {
			entry := m.entries[m.selected]
			if m.multiSelected[entry.Path] {
				delete(m.multiSelected, entry.Path)
			} else {
				m.multiSelected[entry.Path] = true
			}
		}
	case "d", "delete":
		if len(m.entries) > 0 {
			entry := m.entries[m.selected]
			m.deleteConfirm = true
			m.deleteTarget = entry.Path
		}
	case "D":
		// Delete all selected
		if len(m.multiSelected) > 0 {
			m.deleteConfirm = true
			m.deleteTarget = fmt.Sprintf("%d items", len(m.multiSelected))
		}
	case "f":
		m.showLargeFiles = !m.showLargeFiles
	case "r":
		// Refresh
		delete(m.cache, m.path)
		m.scanning = true
		return m, m.scanPath(m.path)
	case "o":
		// Open in Explorer
		if len(m.entries) > 0 {
			entry := m.entries[m.selected]
			openInExplorer(entry.Path)
		}
	case "g":
		m.selected = 0
	case "G":
		m.selected = len(m.entries) - 1
	}
	return m, nil
}

func (m model) View() string {
	var b strings.Builder

	// Header
	b.WriteString(fmt.Sprintf("%s%s Mole Disk Analyzer %s\n", colorPurpleBold, iconDisk, colorReset))
	b.WriteString(fmt.Sprintf("%s%s%s\n", colorGray, m.path, colorReset))
	b.WriteString("\n")

	// Show delete confirmation
	if m.deleteConfirm {
		b.WriteString(fmt.Sprintf("%s%s Delete %s? (y/n)%s\n", colorRed, iconTrash, m.deleteTarget, colorReset))
		return b.String()
	}

	// Scanning indicator
	if m.scanning {
		b.WriteString(fmt.Sprintf("%s⠋ Scanning...%s\n", colorCyan, colorReset))
		if m.scanTotal > 0 {
			b.WriteString(fmt.Sprintf("%s  %d / %d items%s\n", colorGray, m.scanProgress, m.scanTotal, colorReset))
		}
		return b.String()
	}

	// Error display
	if m.err != nil {
		b.WriteString(fmt.Sprintf("%sError: %v%s\n", colorRed, m.err, colorReset))
		b.WriteString("\n")
	}

	// Total size
	b.WriteString(fmt.Sprintf("  Total: %s%s%s\n", colorYellow, formatBytes(m.totalSize), colorReset))
	b.WriteString("\n")

	// Large files toggle
	if m.showLargeFiles && len(m.largeFiles) > 0 {
		b.WriteString(fmt.Sprintf("%s%s Large Files (>100MB):%s\n", colorCyanBold, iconFile, colorReset))
		for i, f := range m.largeFiles {
			if i >= 10 {
				b.WriteString(fmt.Sprintf("  %s... and %d more%s\n", colorGray, len(m.largeFiles)-10, colorReset))
				break
			}
			b.WriteString(fmt.Sprintf("  %s%s%s %s\n", colorYellow, formatBytes(f.Size), colorReset, truncatePath(f.Path, 60)))
		}
		b.WriteString("\n")
	}

	// Directory entries
	visibleEntries := m.height - 12
	if visibleEntries < 5 {
		visibleEntries = 20
	}

	start := 0
	if m.selected >= visibleEntries {
		start = m.selected - visibleEntries + 1
	}

	for i := start; i < len(m.entries) && i < start+visibleEntries; i++ {
		entry := m.entries[i]
		prefix := "  "

		// Selection indicator
		if i == m.selected {
			prefix = fmt.Sprintf("%s%s%s ", colorCyan, iconArrow, colorReset)
		} else if m.multiSelected[entry.Path] {
			prefix = fmt.Sprintf("%s%s%s ", colorGreen, iconSelected, colorReset)
		}

		// Icon
		icon := iconFile
		if entry.IsDir {
			icon = iconFolder
		}
		if entry.IsCleanable {
			icon = iconClean
		}

		// Size and percentage
		pct := float64(0)
		if m.totalSize > 0 {
			pct = float64(entry.Size) / float64(m.totalSize) * 100
		}

		// Bar
		barWidth := 20
		filled := int(pct / 100 * float64(barWidth))
		bar := strings.Repeat("█", filled) + strings.Repeat("░", barWidth-filled)

		// Color based on selection
		nameColor := colorReset
		if i == m.selected {
			nameColor = colorCyanBold
		}

		b.WriteString(fmt.Sprintf("%s%s %s%8s%s %s%s%s %s%.1f%%%s %s\n",
			prefix,
			icon,
			colorYellow, formatBytes(entry.Size), colorReset,
			colorGray, bar, colorReset,
			colorDim, pct, colorReset,
			nameColor+entry.Name+colorReset,
		))
	}

	// Footer with keybindings
	b.WriteString("\n")
	b.WriteString(fmt.Sprintf("%s↑↓%s navigate  %s↵%s enter  %s←%s back  %sf%s files  %sd%s delete  %sr%s refresh  %sq%s quit%s\n",
		colorCyan, colorReset,
		colorCyan, colorReset,
		colorCyan, colorReset,
		colorCyan, colorReset,
		colorCyan, colorReset,
		colorCyan, colorReset,
		colorCyan, colorReset,
		colorReset,
	))

	return b.String()
}

// scanPath scans a directory and returns entries
func (m model) scanPath(path string) tea.Cmd {
	return func() tea.Msg {
		entries, largeFiles, totalSize, err := scanDirectory(path)
		if err != nil {
			return scanErrorMsg{err: err}
		}
		return scanCompleteMsg{
			entries:    entries,
			largeFiles: largeFiles,
			totalSize:  totalSize,
		}
	}
}

// deletePath deletes a file or directory
func (m model) deletePath(path string) tea.Cmd {
	return func() tea.Msg {
		err := os.RemoveAll(path)
		return deleteCompleteMsg{path: path, err: err}
	}
}

// scanDirectory scans a directory concurrently
func scanDirectory(path string) ([]dirEntry, []fileEntry, int64, error) {
	entries, err := os.ReadDir(path)
	if err != nil {
		return nil, nil, 0, err
	}

	var (
		dirEntries []dirEntry
		largeFiles []fileEntry
		totalSize  int64
		mu         sync.Mutex
		wg         sync.WaitGroup
	)

	numWorkers := runtime.NumCPU() * 2
	if numWorkers > 32 {
		numWorkers = 32
	}

	sem := make(chan struct{}, numWorkers)
	var processedCount int64

	for _, entry := range entries {
		name := entry.Name()
		entryPath := filepath.Join(path, name)

		// Skip system directories
		if skipPatterns[name] {
			continue
		}

		wg.Add(1)
		sem <- struct{}{}

		go func(name, entryPath string, isDir bool) {
			defer wg.Done()
			defer func() { <-sem }()

			var size int64
			var lastAccess time.Time
			var isCleanable bool

			if isDir {
				size = calculateDirSize(entryPath)
				isCleanable = cleanablePatterns[name]
			} else {
				info, err := os.Stat(entryPath)
				if err == nil {
					size = info.Size()
					lastAccess = info.ModTime()
				}
			}

			mu.Lock()
			defer mu.Unlock()

			dirEntries = append(dirEntries, dirEntry{
				Name:        name,
				Path:        entryPath,
				Size:        size,
				IsDir:       isDir,
				LastAccess:  lastAccess,
				IsCleanable: isCleanable,
			})

			totalSize += size

			// Track large files
			if !isDir && size >= 100*1024*1024 {
				largeFiles = append(largeFiles, fileEntry{
					Name: name,
					Path: entryPath,
					Size: size,
				})
			}

			atomic.AddInt64(&processedCount, 1)
		}(name, entryPath, entry.IsDir())
	}

	wg.Wait()

	// Sort by size descending
	sort.Slice(dirEntries, func(i, j int) bool {
		return dirEntries[i].Size > dirEntries[j].Size
	})

	sort.Slice(largeFiles, func(i, j int) bool {
		return largeFiles[i].Size > largeFiles[j].Size
	})

	return dirEntries, largeFiles, totalSize, nil
}

// calculateDirSize calculates the size of a directory
func calculateDirSize(path string) int64 {
	var size int64

	filepath.Walk(path, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return nil // Skip errors
		}
		if !info.IsDir() {
			size += info.Size()
		}
		return nil
	})

	return size
}

// formatBytes formats bytes to human readable string
func formatBytes(bytes int64) string {
	const unit = 1024
	if bytes < unit {
		return fmt.Sprintf("%d B", bytes)
	}
	div, exp := int64(unit), 0
	for n := bytes / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(bytes)/float64(div), "KMGTPE"[exp])
}

// truncatePath truncates a path to fit in maxLen
func truncatePath(path string, maxLen int) string {
	if len(path) <= maxLen {
		return path
	}
	return "..." + path[len(path)-maxLen+3:]
}

// openInExplorer opens a path in Windows Explorer
func openInExplorer(path string) {
	// Use explorer.exe to open the path
	cmd := fmt.Sprintf("explorer.exe /select,\"%s\"", path)
	go func() {
		_ = runCommand("cmd", "/c", cmd)
	}()
}

// runCommand runs a command and returns the output
func runCommand(name string, args ...string) error {
	cmd := fmt.Sprintf("%s %s", name, strings.Join(args, " "))
	_ = cmd
	return nil
}

func main() {
	var startPath string

	flag.StringVar(&startPath, "path", "", "Path to analyze")
	flag.Parse()

	// Check environment variable
	if startPath == "" {
		startPath = os.Getenv("MO_ANALYZE_PATH")
	}

	// Use command line argument
	if startPath == "" && len(flag.Args()) > 0 {
		startPath = flag.Args()[0]
	}

	// Default to user profile
	if startPath == "" {
		startPath = os.Getenv("USERPROFILE")
	}

	// Resolve to absolute path
	absPath, err := filepath.Abs(startPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	// Check if path exists
	if _, err := os.Stat(absPath); os.IsNotExist(err) {
		fmt.Fprintf(os.Stderr, "Error: Path does not exist: %s\n", absPath)
		os.Exit(1)
	}

	p := tea.NewProgram(newModel(absPath), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}
