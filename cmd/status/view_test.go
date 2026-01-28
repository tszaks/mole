package main

import "testing"

func TestFormatRate(t *testing.T) {
	tests := []struct {
		name  string
		input float64
		want  string
	}{
		// Below threshold (< 0.01).
		{"zero", 0, "0 MB/s"},
		{"tiny", 0.001, "0 MB/s"},
		{"just under threshold", 0.009, "0 MB/s"},

		// Small rates (0.01 to < 1) — 2 decimal places.
		{"at threshold", 0.01, "0.01 MB/s"},
		{"small rate", 0.5, "0.50 MB/s"},
		{"just under 1", 0.99, "0.99 MB/s"},

		// Medium rates (1 to < 10) — 1 decimal place.
		{"exactly 1", 1.0, "1.0 MB/s"},
		{"medium rate", 5.5, "5.5 MB/s"},
		{"just under 10", 9.9, "9.9 MB/s"},

		// Large rates (>= 10) — no decimal places.
		{"exactly 10", 10.0, "10 MB/s"},
		{"large rate", 100.5, "100 MB/s"},
		{"very large", 1000.0, "1000 MB/s"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := formatRate(tt.input)
			if got != tt.want {
				t.Errorf("formatRate(%v) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

func TestColorizePercent(t *testing.T) {
	tests := []struct {
		name         string
		percent      float64
		input        string
		expectDanger bool
		expectWarn   bool
		expectOk     bool
	}{
		{"low usage", 30.0, "30%", false, false, true},
		{"just below warn", 59.9, "59.9%", false, false, true},
		{"at warn threshold", 60.0, "60%", false, true, false},
		{"mid range", 70.0, "70%", false, true, false},
		{"just below danger", 84.9, "84.9%", false, true, false},
		{"at danger threshold", 85.0, "85%", true, false, false},
		{"high usage", 95.0, "95%", true, false, false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := colorizePercent(tt.percent, tt.input)

			if got == "" {
				t.Errorf("colorizePercent(%v, %q) returned empty string", tt.percent, tt.input)
				return
			}

			expected := ""
			if tt.expectDanger {
				expected = dangerStyle.Render(tt.input)
			} else if tt.expectWarn {
				expected = warnStyle.Render(tt.input)
			} else if tt.expectOk {
				expected = okStyle.Render(tt.input)
			}

			if got != expected {
				t.Errorf("colorizePercent(%v, %q) = %q, want %q (danger=%v warn=%v ok=%v)",
					tt.percent, tt.input, got, expected, tt.expectDanger, tt.expectWarn, tt.expectOk)
			}
		})
	}
}

func TestColorizeBattery(t *testing.T) {
	tests := []struct {
		name         string
		percent      float64
		input        string
		expectDanger bool
		expectWarn   bool
		expectOk     bool
	}{
		{"critical low", 10.0, "10%", true, false, false},
		{"just below low", 19.9, "19.9%", true, false, false},
		{"at low threshold", 20.0, "20%", false, true, false},
		{"mid range", 35.0, "35%", false, true, false},
		{"just below ok", 49.9, "49.9%", false, true, false},
		{"at ok threshold", 50.0, "50%", false, false, true},
		{"healthy", 80.0, "80%", false, false, true},
		{"full", 100.0, "100%", false, false, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := colorizeBattery(tt.percent, tt.input)

			if got == "" {
				t.Errorf("colorizeBattery(%v, %q) returned empty string", tt.percent, tt.input)
				return
			}

			expected := ""
			if tt.expectDanger {
				expected = dangerStyle.Render(tt.input)
			} else if tt.expectWarn {
				expected = warnStyle.Render(tt.input)
			} else if tt.expectOk {
				expected = okStyle.Render(tt.input)
			}

			if got != expected {
				t.Errorf("colorizeBattery(%v, %q) = %q, want %q (danger=%v warn=%v ok=%v)",
					tt.percent, tt.input, got, expected, tt.expectDanger, tt.expectWarn, tt.expectOk)
			}
		})
	}
}

func TestShorten(t *testing.T) {
	tests := []struct {
		name   string
		input  string
		maxLen int
		want   string
	}{
		// No truncation needed.
		{"empty string", "", 10, ""},
		{"shorter than max", "hello", 10, "hello"},
		{"exactly at max", "hello", 5, "hello"},

		// Truncation needed.
		{"one over max", "hello!", 5, "hell…"},
		{"much longer", "hello world", 5, "hell…"},

		// Edge cases.
		{"maxLen 1", "hello", 1, "…"},
		{"maxLen 2", "hello", 2, "h…"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := shorten(tt.input, tt.maxLen)
			if got != tt.want {
				t.Errorf("shorten(%q, %d) = %q, want %q", tt.input, tt.maxLen, got, tt.want)
			}
		})
	}
}

func TestHumanBytesShort(t *testing.T) {
	tests := []struct {
		name  string
		input uint64
		want  string
	}{
		// Zero and small values.
		{"zero", 0, "0"},
		{"one byte", 1, "1"},
		{"999 bytes", 999, "999"},

		// Kilobyte boundaries.
		{"exactly 1KB", 1 << 10, "1K"},
		{"just under 1KB", (1 << 10) - 1, "1023"},
		{"1.5KB rounds to 2K", 1536, "2K"},
		{"999KB", 999 << 10, "999K"},

		// Megabyte boundaries.
		{"exactly 1MB", 1 << 20, "1M"},
		{"just under 1MB", (1 << 20) - 1, "1024K"},
		{"500MB", 500 << 20, "500M"},

		// Gigabyte boundaries.
		{"exactly 1GB", 1 << 30, "1G"},
		{"just under 1GB", (1 << 30) - 1, "1024M"},
		{"100GB", 100 << 30, "100G"},

		// Terabyte boundaries.
		{"exactly 1TB", 1 << 40, "1T"},
		{"just under 1TB", (1 << 40) - 1, "1024G"},
		{"2TB", 2 << 40, "2T"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := humanBytesShort(tt.input)
			if got != tt.want {
				t.Errorf("humanBytesShort(%d) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

func TestHumanBytes(t *testing.T) {
	tests := []struct {
		name  string
		input uint64
		want  string
	}{
		// Zero and small values.
		{"zero", 0, "0 B"},
		{"one byte", 1, "1 B"},
		{"1023 bytes", 1023, "1023 B"},

		// Kilobyte boundaries (uses > not >=).
		{"exactly 1KB", 1 << 10, "1024 B"},
		{"just over 1KB", (1 << 10) + 1, "1.0 KB"},
		{"1.5KB", 1536, "1.5 KB"},

		// Megabyte boundaries (uses > not >=).
		{"exactly 1MB", 1 << 20, "1024.0 KB"},
		{"just over 1MB", (1 << 20) + 1, "1.0 MB"},
		{"500MB", 500 << 20, "500.0 MB"},

		// Gigabyte boundaries (uses > not >=).
		{"exactly 1GB", 1 << 30, "1024.0 MB"},
		{"just over 1GB", (1 << 30) + 1, "1.0 GB"},
		{"100GB", 100 << 30, "100.0 GB"},

		// Terabyte boundaries (uses > not >=).
		{"exactly 1TB", 1 << 40, "1024.0 GB"},
		{"just over 1TB", (1 << 40) + 1, "1.0 TB"},
		{"2TB", 2 << 40, "2.0 TB"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := humanBytes(tt.input)
			if got != tt.want {
				t.Errorf("humanBytes(%d) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

func TestHumanBytesCompact(t *testing.T) {
	tests := []struct {
		name  string
		input uint64
		want  string
	}{
		// Zero and small values.
		{"zero", 0, "0"},
		{"one byte", 1, "1"},
		{"1023 bytes", 1023, "1023"},

		// Kilobyte boundaries (uses >= not >).
		{"exactly 1KB", 1 << 10, "1.0K"},
		{"1.5KB", 1536, "1.5K"},

		// Megabyte boundaries.
		{"exactly 1MB", 1 << 20, "1.0M"},
		{"500MB", 500 << 20, "500.0M"},

		// Gigabyte boundaries.
		{"exactly 1GB", 1 << 30, "1.0G"},
		{"100GB", 100 << 30, "100.0G"},

		// Terabyte boundaries.
		{"exactly 1TB", 1 << 40, "1.0T"},
		{"2TB", 2 << 40, "2.0T"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := humanBytesCompact(tt.input)
			if got != tt.want {
				t.Errorf("humanBytesCompact(%d) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

func TestSplitDisks(t *testing.T) {
	tests := []struct {
		name         string
		disks        []DiskStatus
		wantInternal int
		wantExternal int
	}{
		{
			name:         "empty slice",
			disks:        []DiskStatus{},
			wantInternal: 0,
			wantExternal: 0,
		},
		{
			name: "all internal",
			disks: []DiskStatus{
				{Mount: "/", External: false},
				{Mount: "/System", External: false},
			},
			wantInternal: 2,
			wantExternal: 0,
		},
		{
			name: "all external",
			disks: []DiskStatus{
				{Mount: "/Volumes/USB", External: true},
				{Mount: "/Volumes/Backup", External: true},
			},
			wantInternal: 0,
			wantExternal: 2,
		},
		{
			name: "mixed",
			disks: []DiskStatus{
				{Mount: "/", External: false},
				{Mount: "/Volumes/USB", External: true},
				{Mount: "/System", External: false},
			},
			wantInternal: 2,
			wantExternal: 1,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			internal, external := splitDisks(tt.disks)
			if len(internal) != tt.wantInternal {
				t.Errorf("splitDisks() internal count = %d, want %d", len(internal), tt.wantInternal)
			}
			if len(external) != tt.wantExternal {
				t.Errorf("splitDisks() external count = %d, want %d", len(external), tt.wantExternal)
			}
		})
	}
}

func TestDiskLabel(t *testing.T) {
	tests := []struct {
		name   string
		prefix string
		index  int
		total  int
		want   string
	}{
		// Single disk — no numbering.
		{"single disk", "INTR", 0, 1, "INTR"},
		{"single external", "EXTR", 0, 1, "EXTR"},

		// Multiple disks — numbered (1-indexed).
		{"first of two", "INTR", 0, 2, "INTR1"},
		{"second of two", "INTR", 1, 2, "INTR2"},
		{"third of three", "EXTR", 2, 3, "EXTR3"},

		// Edge case: total 0 treated as single.
		{"total zero", "DISK", 0, 0, "DISK"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := diskLabel(tt.prefix, tt.index, tt.total)
			if got != tt.want {
				t.Errorf("diskLabel(%q, %d, %d) = %q, want %q", tt.prefix, tt.index, tt.total, got, tt.want)
			}
		})
	}
}
