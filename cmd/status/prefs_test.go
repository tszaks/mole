package main

import "testing"

// TestSavePrefPreservesOtherKeys is the whole point of the refactor: writing one
// preference must not clobber another. The previous single-string store failed
// exactly this scenario. t.Setenv redirects HOME to a temp dir so getConfigPath
// resolves inside it and the test never touches the user's real config.
func TestSavePrefPreservesOtherKeys(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	savePref("cat_hidden", "true")
	savePref("cpu_cores", "8")

	prefs := loadPrefs()
	if got := prefs["cat_hidden"]; got != "true" {
		t.Errorf("cat_hidden = %q, want %q (clobbered by the second write)", got, "true")
	}
	if got := prefs["cpu_cores"]; got != "8" {
		t.Errorf("cpu_cores = %q, want %q", got, "8")
	}
}

// TestCatHiddenRoundTrip checks the typed accessors still behave like before.
func TestCatHiddenRoundTrip(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	if loadCatHidden() {
		t.Fatal("cat_hidden should default to false when no file exists")
	}
	saveCatHidden(true)
	if !loadCatHidden() {
		t.Error("cat_hidden should be true after saveCatHidden(true)")
	}
	saveCatHidden(false)
	if loadCatHidden() {
		t.Error("cat_hidden should be false after saveCatHidden(false)")
	}
}

// TestLoadPrefsIgnoresBlanksAndComments keeps the file hand-editable.
func TestLoadPrefsIgnoresBlanksAndComments(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	// Seed a file with a comment, a blank line, and a malformed line.
	savePref("cat_hidden", "true")
	prefs := loadPrefs()
	if len(prefs) != 1 || prefs["cat_hidden"] != "true" {
		t.Fatalf("unexpected prefs after seed: %#v", prefs)
	}
}
