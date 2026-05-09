//go:build darwin

package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

const analyzeExcludeConfigName = "analyze_exclude"

var (
	analyzeExcludeFlag            stringListFlag
	manageAnalyzeExcludePathsFlag = flag.Bool("exclude-paths", false, "open the analyze exclude path config")
	activeAnalyzeExcludePaths     []string
)

func init() {
	flag.Var(&analyzeExcludeFlag, "exclude", "exclude path from analysis (repeatable)")
}

type stringListFlag []string

func (f *stringListFlag) String() string {
	if f == nil {
		return ""
	}
	return strings.Join(*f, ",")
}

func (f *stringListFlag) Set(value string) error {
	path, err := normalizeAnalyzeExcludePath(value)
	if err != nil {
		return err
	}
	*f = append(*f, path)
	return nil
}

func loadAnalyzeExcludePaths(cliPaths []string) ([]string, error) {
	configPaths, err := readAnalyzeExcludeConfig()
	if err != nil {
		return nil, err
	}

	paths := make([]string, 0, len(configPaths)+len(cliPaths))
	paths = append(paths, configPaths...)
	paths = append(paths, cliPaths...)
	return dedupeAnalyzeExcludePaths(paths), nil
}

func readAnalyzeExcludeConfig() ([]string, error) {
	configFile, err := analyzeExcludeConfigFile()
	if err != nil {
		return nil, err
	}

	data, err := os.ReadFile(configFile)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}

	var paths []string
	for lineNumber, rawLine := range strings.Split(string(data), "\n") {
		line := strings.TrimSpace(rawLine)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		path, err := normalizeAnalyzeExcludePath(line)
		if err != nil {
			return nil, fmt.Errorf("%s:%d: %w", configFile, lineNumber+1, err)
		}
		paths = append(paths, path)
	}
	return paths, nil
}

func manageAnalyzeExcludePaths() error {
	configFile, err := analyzeExcludeConfigFile()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(configFile), 0o755); err != nil {
		return err
	}
	if _, err := os.Stat(configFile); os.IsNotExist(err) {
		initial := strings.Join([]string{
			"# Mole analyze exclude paths",
			"# One path per line. Blank lines and # comments are ignored.",
			"# Examples:",
			"# ~/Library/CloudStorage",
			"# ~/Movies",
			"",
		}, "\n")
		if err := os.WriteFile(configFile, []byte(initial), 0o644); err != nil {
			return err
		}
	}

	editor := os.Getenv("VISUAL")
	if editor == "" {
		editor = os.Getenv("EDITOR")
	}

	if editor != "" {
		cmd := exec.Command("sh", "-c", `$EDITOR_CMD "$1"`, "mole-analyze-exclude", configFile)
		cmd.Env = append(os.Environ(), "EDITOR_CMD="+editor)
		cmd.Stdin = os.Stdin
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		if err := cmd.Run(); err != nil {
			return err
		}
		fmt.Printf("Analyze exclude paths: %s\n", configFile)
		return nil
	}

	if _, err := exec.LookPath("open"); err == nil {
		cmd := exec.Command("open", "-t", configFile)
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		if err := cmd.Run(); err != nil {
			return err
		}
		fmt.Printf("Analyze exclude paths: %s\n", configFile)
		return nil
	}

	fmt.Printf("Analyze exclude paths: %s\n", configFile)
	return nil
}

func analyzeExcludeConfigFile() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	if home == "" {
		return "", fmt.Errorf("HOME is not set")
	}
	return filepath.Join(home, ".config", "mole", analyzeExcludeConfigName), nil
}

func normalizeAnalyzeExcludePath(raw string) (string, error) {
	path := strings.TrimSpace(raw)
	if path == "" {
		return "", fmt.Errorf("exclude path is empty")
	}
	if strings.Contains(path, "\x00") {
		return "", fmt.Errorf("exclude path contains null byte")
	}

	if path == "~" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		path = home
	} else if strings.HasPrefix(path, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		path = filepath.Join(home, path[2:])
	}

	var err error
	if !filepath.IsAbs(path) {
		path, err = filepath.Abs(path)
		if err != nil {
			return "", err
		}
	}
	return filepath.Clean(path), nil
}

func dedupeAnalyzeExcludePaths(paths []string) []string {
	if len(paths) == 0 {
		return nil
	}

	cleaned := make([]string, 0, len(paths))
	for _, path := range paths {
		if path == "" {
			continue
		}
		cleaned = append(cleaned, filepath.Clean(path))
	}
	if len(cleaned) == 0 {
		return nil
	}

	slicesSortByPathLength(cleaned)

	result := make([]string, 0, len(cleaned))
	for _, path := range cleaned {
		covered := false
		for _, existing := range result {
			if isSameOrChildPath(path, existing) {
				covered = true
				break
			}
		}
		if !covered {
			result = append(result, path)
		}
	}
	return result
}

func slicesSortByPathLength(paths []string) {
	for i := 1; i < len(paths); i++ {
		for j := i; j > 0; j-- {
			if len(paths[j-1]) < len(paths[j]) {
				break
			}
			if len(paths[j-1]) == len(paths[j]) && paths[j-1] <= paths[j] {
				break
			}
			paths[j-1], paths[j] = paths[j], paths[j-1]
		}
	}
}

func hasAnalyzeExcludes() bool {
	return len(activeAnalyzeExcludePaths) > 0
}

func isAnalyzePathExcluded(path string) bool {
	if len(activeAnalyzeExcludePaths) == 0 || path == "" {
		return false
	}
	cleanPath := filepath.Clean(path)
	for _, excludePath := range activeAnalyzeExcludePaths {
		if isSameOrChildPath(cleanPath, excludePath) {
			return true
		}
	}
	return false
}

func isSameOrChildPath(path string, base string) bool {
	path = filepath.Clean(path)
	base = filepath.Clean(base)
	if path == base {
		return true
	}
	if base == string(os.PathSeparator) {
		return strings.HasPrefix(path, string(os.PathSeparator))
	}
	return strings.HasPrefix(path, base+string(os.PathSeparator))
}

func filterAnalyzeExcludedDirEntries(entries []dirEntry) []dirEntry {
	if !hasAnalyzeExcludes() {
		return entries
	}
	filtered := entries[:0]
	for _, entry := range entries {
		if !isAnalyzePathExcluded(entry.Path) {
			filtered = append(filtered, entry)
		}
	}
	return filtered
}
