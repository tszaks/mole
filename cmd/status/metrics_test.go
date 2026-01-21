package main

import (
	"reflect"
	"testing"
)

func TestNewRingBuffer(t *testing.T) {
	tests := []struct {
		name     string
		capacity int
	}{
		{"small buffer", 5},
		{"standard buffer", 120},
		{"single element", 1},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rb := NewRingBuffer(tt.capacity)
			if rb == nil {
				t.Fatal("NewRingBuffer returned nil")
			}
			if rb.cap != tt.capacity {
				t.Errorf("expected capacity %d, got %d", tt.capacity, rb.cap)
			}
			if rb.size != 0 {
				t.Errorf("expected size 0 for new buffer, got %d", rb.size)
			}
			if rb.index != 0 {
				t.Errorf("expected index 0 for new buffer, got %d", rb.index)
			}
			if len(rb.data) != tt.capacity {
				t.Errorf("expected data slice length %d, got %d", tt.capacity, len(rb.data))
			}
		})
	}
}

func TestRingBuffer_EmptyBuffer(t *testing.T) {
	rb := NewRingBuffer(5)
	result := rb.Slice()

	if result != nil {
		t.Errorf("expected nil for empty buffer, got %v", result)
	}
}

func TestRingBuffer_AddWithinCapacity(t *testing.T) {
	rb := NewRingBuffer(5)

	// Add 3 elements (less than capacity)
	rb.Add(1.0)
	rb.Add(2.0)
	rb.Add(3.0)

	if rb.size != 3 {
		t.Errorf("expected size 3, got %d", rb.size)
	}

	result := rb.Slice()
	expected := []float64{1.0, 2.0, 3.0}

	if !reflect.DeepEqual(result, expected) {
		t.Errorf("expected %v, got %v", expected, result)
	}
}

func TestRingBuffer_ExactCapacity(t *testing.T) {
	rb := NewRingBuffer(5)

	// Fill exactly to capacity
	for i := 1; i <= 5; i++ {
		rb.Add(float64(i))
	}

	if rb.size != 5 {
		t.Errorf("expected size 5, got %d", rb.size)
	}

	result := rb.Slice()
	expected := []float64{1.0, 2.0, 3.0, 4.0, 5.0}

	if !reflect.DeepEqual(result, expected) {
		t.Errorf("expected %v, got %v", expected, result)
	}
}

func TestRingBuffer_WrapAround(t *testing.T) {
	rb := NewRingBuffer(5)

	// Add 7 elements to trigger wrap-around (2 past capacity)
	// Internal state after: data=[6, 7, 3, 4, 5], index=2, size=5
	// Oldest element is at index 2 (value 3)
	for i := 1; i <= 7; i++ {
		rb.Add(float64(i))
	}

	if rb.size != 5 {
		t.Errorf("expected size to cap at 5, got %d", rb.size)
	}

	result := rb.Slice()
	// Should return chronological order: 3, 4, 5, 6, 7
	expected := []float64{3.0, 4.0, 5.0, 6.0, 7.0}

	if !reflect.DeepEqual(result, expected) {
		t.Errorf("expected %v, got %v", expected, result)
	}
}

func TestRingBuffer_MultipleWrapArounds(t *testing.T) {
	rb := NewRingBuffer(3)

	// Add 10 elements (wraps multiple times)
	for i := 1; i <= 10; i++ {
		rb.Add(float64(i))
	}

	result := rb.Slice()
	// Should have the last 3 values: 8, 9, 10
	expected := []float64{8.0, 9.0, 10.0}

	if !reflect.DeepEqual(result, expected) {
		t.Errorf("expected %v, got %v", expected, result)
	}
}

func TestRingBuffer_SingleElementBuffer(t *testing.T) {
	rb := NewRingBuffer(1)

	rb.Add(5.0)
	result := rb.Slice()
	if !reflect.DeepEqual(result, []float64{5.0}) {
		t.Errorf("expected [5.0], got %v", result)
	}

	// Overwrite the single element
	rb.Add(10.0)
	result = rb.Slice()
	if !reflect.DeepEqual(result, []float64{10.0}) {
		t.Errorf("expected [10.0], got %v", result)
	}
}

func TestRingBuffer_SliceReturnsNewSlice(t *testing.T) {
	rb := NewRingBuffer(3)
	rb.Add(1.0)
	rb.Add(2.0)

	slice1 := rb.Slice()
	slice2 := rb.Slice()

	// Modify slice1 and verify slice2 is unaffected
	slice1[0] = 999.0

	if slice2[0] == 999.0 {
		t.Error("Slice should return a new copy, not a reference to internal data")
	}
}
