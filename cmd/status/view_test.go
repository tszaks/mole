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

func TestParseInt(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  int
	}{
		// Basic integers.
		{"simple number", "123", 123},
		{"zero", "0", 0},
		{"single digit", "5", 5},

		// With whitespace.
		{"leading space", "  42", 42},
		{"trailing space", "42  ", 42},
		{"both spaces", "  42  ", 42},

		// With non-numeric padding.
		{"leading @", "@60", 60},
		{"trailing Hz", "120Hz", 120},
		{"both padding", "@60Hz", 60},

		// Decimals (truncated to int).
		{"decimal", "60.00", 60},
		{"decimal with suffix", "119.88hz", 119},

		// Edge cases.
		{"empty string", "", 0},
		{"only spaces", "   ", 0},
		{"no digits", "abc", 0},
		{"negative strips sign", "-5", 5}, // Strips non-numeric prefix.
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := parseInt(tt.input)
			if got != tt.want {
				t.Errorf("parseInt(%q) = %d, want %d", tt.input, got, tt.want)
			}
		})
	}
}

func TestParseRefreshRate(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  string
	}{
		// Standard formats.
		{"60Hz format", "Resolution: 1920x1080 @ 60Hz", "60Hz"},
		{"120Hz format", "Resolution: 2560x1600 @ 120Hz", "120Hz"},
		{"separated Hz", "Refresh Rate: 60 Hz", "60Hz"},

		// Decimal refresh rates.
		{"decimal Hz", "Resolution: 3840x2160 @ 59.94Hz", "59Hz"},
		{"ProMotion", "Resolution: 3456x2234 @ 120.00Hz", "120Hz"},

		// Multiple lines — picks highest valid.
		{"multiple rates", "Display 1: 60Hz\nDisplay 2: 120Hz", "120Hz"},

		// Edge cases.
		{"empty string", "", ""},
		{"no Hz found", "Resolution: 1920x1080", ""},
		{"invalid Hz value", "Rate: abcHz", ""},
		{"Hz too high filtered", "Rate: 600Hz", ""},

		// Case insensitivity.
		{"lowercase hz", "60hz", "60Hz"},
		{"uppercase HZ", "60HZ", "60Hz"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := parseRefreshRate(tt.input)
			if got != tt.want {
				t.Errorf("parseRefreshRate(%q) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

func TestIsNoiseInterface(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  bool
	}{
		// Noise interfaces (should return true).
		{"loopback", "lo0", true},
		{"awdl", "awdl0", true},
		{"utun", "utun0", true},
		{"llw", "llw0", true},
		{"bridge", "bridge0", true},
		{"gif", "gif0", true},
		{"stf", "stf0", true},
		{"xhc", "xhc0", true},
		{"anpi", "anpi0", true},
		{"ap", "ap1", true},

		// Real interfaces (should return false).
		{"ethernet", "en0", false},
		{"wifi", "en1", false},
		{"thunderbolt", "en5", false},

		// Case insensitivity.
		{"uppercase LO", "LO0", true},
		{"mixed case Awdl", "Awdl0", true},

		// Edge cases.
		{"empty string", "", false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := isNoiseInterface(tt.input)
			if got != tt.want {
				t.Errorf("isNoiseInterface(%q) = %v, want %v", tt.input, got, tt.want)
			}
		})
	}
}

func TestParsePMSet(t *testing.T) {
	tests := []struct {
		name     string
		raw      string
		health   string
		cycles   int
		capacity int
		wantLen  int
		wantPct  float64
		wantStat string
		wantTime string
	}{
		{
			name: "charging with time",
			raw: `Now drawing from 'AC Power'
 -InternalBattery-0 (id=1234)	85%; charging; 0:45 remaining present: true`,
			health:   "Good",
			cycles:   150,
			capacity: 92,
			wantLen:  1,
			wantPct:  85,
			wantStat: "charging",
			wantTime: "0:45",
		},
		{
			name: "discharging",
			raw: `Now drawing from 'Battery Power'
 -InternalBattery-0 (id=1234)	45%; discharging; 2:30 remaining present: true`,
			health:   "Normal",
			cycles:   200,
			capacity: 88,
			wantLen:  1,
			wantPct:  45,
			wantStat: "discharging",
			wantTime: "2:30",
		},
		{
			name: "fully charged",
			raw: `Now drawing from 'AC Power'
 -InternalBattery-0 (id=1234)	100%; charged; present: true`,
			health:   "Good",
			cycles:   50,
			capacity: 100,
			wantLen:  1,
			wantPct:  100,
			wantStat: "charged",
			wantTime: "",
		},
		{
			name:     "empty output",
			raw:      "",
			health:   "",
			cycles:   0,
			capacity: 0,
			wantLen:  0,
		},
		{
			name:     "no battery line",
			raw:      "Now drawing from 'AC Power'\nNo batteries found.",
			health:   "",
			cycles:   0,
			capacity: 0,
			wantLen:  0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := parsePMSet(tt.raw, tt.health, tt.cycles, tt.capacity)
			if len(got) != tt.wantLen {
				t.Errorf("parsePMSet() returned %d batteries, want %d", len(got), tt.wantLen)
				return
			}
			if tt.wantLen == 0 {
				return
			}
			b := got[0]
			if b.Percent != tt.wantPct {
				t.Errorf("Percent = %v, want %v", b.Percent, tt.wantPct)
			}
			if b.Status != tt.wantStat {
				t.Errorf("Status = %q, want %q", b.Status, tt.wantStat)
			}
			if b.TimeLeft != tt.wantTime {
				t.Errorf("TimeLeft = %q, want %q", b.TimeLeft, tt.wantTime)
			}
			if b.Health != tt.health {
				t.Errorf("Health = %q, want %q", b.Health, tt.health)
			}
			if b.CycleCount != tt.cycles {
				t.Errorf("CycleCount = %d, want %d", b.CycleCount, tt.cycles)
			}
			if b.Capacity != tt.capacity {
				t.Errorf("Capacity = %d, want %d", b.Capacity, tt.capacity)
			}
		})
	}
}
