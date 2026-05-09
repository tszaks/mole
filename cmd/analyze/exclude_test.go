//go:build darwin

package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestReadAnalyzeExcludeConfigExpandsHomeAndSkipsComments(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	configDir := filepath.Join(home, ".config", "mole")
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		t.Fatalf("mkdir config dir: %v", err)
	}
	configFile := filepath.Join(configDir, analyzeExcludeConfigName)
	config := "# comment\n\n~/Library/CloudStorage\n"
	if err := os.WriteFile(configFile, []byte(config), 0o644); err != nil {
		t.Fatalf("write config: %v", err)
	}

	paths, err := readAnalyzeExcludeConfig()
	if err != nil {
		t.Fatalf("readAnalyzeExcludeConfig: %v", err)
	}
	if len(paths) != 1 {
		t.Fatalf("expected one configured path, got %#v", paths)
	}
	want := filepath.Join(home, "Library", "CloudStorage")
	if paths[0] != want {
		t.Fatalf("expected %s, got %s", want, paths[0])
	}
}

func TestDedupeAnalyzeExcludePathsDropsChildren(t *testing.T) {
	root := filepath.Join(t.TempDir(), "root")
	paths := dedupeAnalyzeExcludePaths([]string{
		filepath.Join(root, "nested", "child"),
		filepath.Join(root, "nested"),
		filepath.Join(root, "other"),
		filepath.Join(root, "nested"),
	})

	if len(paths) != 2 {
		t.Fatalf("expected parent and sibling only, got %#v", paths)
	}
	if paths[0] != filepath.Join(root, "other") && paths[1] != filepath.Join(root, "other") {
		t.Fatalf("expected sibling path to remain, got %#v", paths)
	}
	for _, path := range paths {
		if path == filepath.Join(root, "nested", "child") {
			t.Fatalf("expected child path to be dropped, got %#v", paths)
		}
	}
}
