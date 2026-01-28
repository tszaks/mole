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
