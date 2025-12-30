#!/usr/bin/env bats
# Performance benchmark tests for Mole optimizations
# Tests the performance improvements introduced in V1.14.0+

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    # Create test data directory
    TEST_DATA_DIR="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-perf.XXXXXX")"
    export TEST_DATA_DIR
}

teardown_file() {
    rm -rf "$TEST_DATA_DIR"
}

setup() {
    source "$PROJECT_ROOT/lib/core/base.sh"
}

# ============================================================================
# bytes_to_human Performance Tests
# ============================================================================

@test "bytes_to_human handles large values efficiently" {
    local start end elapsed

    # Warm up
    bytes_to_human 1073741824 > /dev/null

    # Benchmark: 1000 iterations should complete in < 2 seconds (relaxed threshold)
    start=$(date +%s%N)
    for i in {1..1000}; do
        bytes_to_human 1073741824 > /dev/null
    done
    end=$(date +%s%N)

    elapsed=$(( (end - start) / 1000000 )) # Convert to milliseconds

    # Should complete in less than 2000ms (2 seconds)
    [ "$elapsed" -lt 2000 ]
}

@test "bytes_to_human produces correct output for GB range" {
    result=$(bytes_to_human 1073741824)
    [ "$result" = "1.00GB" ]

    result=$(bytes_to_human 5368709120)
    [ "$result" = "5.00GB" ]
}

@test "bytes_to_human produces correct output for MB range" {
    result=$(bytes_to_human 1048576)
    [ "$result" = "1.0MB" ]

    result=$(bytes_to_human 104857600)
    [ "$result" = "100.0MB" ]
}

@test "bytes_to_human produces correct output for KB range" {
    result=$(bytes_to_human 1024)
    [ "$result" = "1KB" ]

    result=$(bytes_to_human 10240)
    [ "$result" = "10KB" ]
}

@test "bytes_to_human handles edge cases" {
    # Zero bytes
    result=$(bytes_to_human 0)
    [ "$result" = "0B" ]

    # Invalid input returns 0B (with error code 1)
    run bytes_to_human "invalid"
    [ "$status" -eq 1 ]
    [ "$output" = "0B" ]

    # Negative should also fail validation
    run bytes_to_human "-100"
    [ "$status" -eq 1 ]
    [ "$output" = "0B" ]
}

# ============================================================================
# BSD Stat Wrapper Performance Tests
# ============================================================================

@test "get_file_size is faster than multiple stat calls" {
    # Create test file
    local test_file="$TEST_DATA_DIR/size_test.txt"
    dd if=/dev/zero of="$test_file" bs=1024 count=100 2> /dev/null

    # Benchmark: 100 calls should complete quickly
    local start end elapsed
    start=$(date +%s%N)
    for i in {1..100}; do
        get_file_size "$test_file" > /dev/null
    done
    end=$(date +%s%N)

    elapsed=$(( (end - start) / 1000000 ))

    # Should complete in less than 1000ms (relaxed threshold)
    [ "$elapsed" -lt 1000 ]
}

@test "get_file_mtime returns valid timestamp" {
    local test_file="$TEST_DATA_DIR/mtime_test.txt"
    touch "$test_file"

    result=$(get_file_mtime "$test_file")

    # Should be a valid epoch timestamp (10 digits)
    [[ "$result" =~ ^[0-9]{10,}$ ]]
}

@test "get_file_owner returns current user for owned files" {
    local test_file="$TEST_DATA_DIR/owner_test.txt"
    touch "$test_file"

    result=$(get_file_owner "$test_file")
    current_user=$(whoami)

    [ "$result" = "$current_user" ]
}

# ============================================================================
# User Context Detection Performance Tests
# ============================================================================

@test "get_invoking_user executes quickly" {
    local start end elapsed

    start=$(date +%s%N)
    for i in {1..100}; do
        get_invoking_user > /dev/null
    done
    end=$(date +%s%N)

    elapsed=$(( (end - start) / 1000000 ))

    # Should complete in less than 200ms
    [ "$elapsed" -lt 200 ]
}

@test "get_darwin_major caches correctly" {
    # Multiple calls should return same result
    local first second
    first=$(get_darwin_major)
    second=$(get_darwin_major)

    [ "$first" = "$second" ]
    [[ "$first" =~ ^[0-9]+$ ]]
}

# ============================================================================
# Temporary File Management Performance Tests
# ============================================================================

@test "create_temp_file and cleanup_temp_files work efficiently" {
    local start end elapsed

    # Ensure MOLE_TEMP_DIRS is initialized (base.sh should do this)
    declare -a MOLE_TEMP_DIRS=()

    # Create 50 temp files (reduced from 100 for faster testing)
    start=$(date +%s%N)
    for i in {1..50}; do
        create_temp_file > /dev/null
    done
    end=$(date +%s%N)

    elapsed=$(( (end - start) / 1000000 ))

    # Should complete in less than 1000ms
    [ "$elapsed" -lt 1000 ]

    # Verify temp files were tracked
    [ "${#MOLE_TEMP_FILES[@]}" -eq 50 ]

    # Cleanup should also be reasonably fast
    start=$(date +%s%N)
    cleanup_temp_files
    end=$(date +%s%N)

    elapsed=$(( (end - start) / 1000000 ))
    # Relaxed threshold: should complete within 2 seconds
    [ "$elapsed" -lt 2000 ]

    # Verify cleanup
    [ "${#MOLE_TEMP_FILES[@]}" -eq 0 ]
}

@test "mktemp_file creates files with correct prefix" {
    local temp_file
    temp_file=$(mktemp_file "test_prefix")

    # Should contain prefix
    [[ "$temp_file" =~ test_prefix ]]

    # Should exist
    [ -f "$temp_file" ]

    # Cleanup
    rm -f "$temp_file"
}

# ============================================================================
# Brand Name Lookup Performance Tests
# ============================================================================

@test "get_brand_name handles common apps efficiently" {
    local start end elapsed

    # Warm up (first call includes defaults read which is slow)
    get_brand_name "wechat" > /dev/null

    # Benchmark: 50 lookups (reduced from 100)
    start=$(date +%s%N)
    for i in {1..50}; do
        get_brand_name "wechat" > /dev/null
        get_brand_name "QQ" > /dev/null
        get_brand_name "dingtalk" > /dev/null
    done
    end=$(date +%s%N)

    elapsed=$(( (end - start) / 1000000 ))

    # Relaxed threshold: defaults read is called multiple times
    # Should complete within 5 seconds on most systems
    [ "$elapsed" -lt 5000 ]
}

@test "get_brand_name returns correct localized names" {
    # Test should work regardless of system language
    local result
    result=$(get_brand_name "wechat")

    # Should return either "WeChat" or "微信"
    [[ "$result" == "WeChat" || "$result" == "微信" ]]
}

# ============================================================================
# Parallel Job Calculation Tests
# ============================================================================

@test "get_optimal_parallel_jobs returns sensible values" {
    local result

    # Default mode
    result=$(get_optimal_parallel_jobs)
    [[ "$result" =~ ^[0-9]+$ ]]
    [ "$result" -gt 0 ]
    [ "$result" -le 128 ]

    # Scan mode (should be higher)
    local scan_jobs
    scan_jobs=$(get_optimal_parallel_jobs "scan")
    [ "$scan_jobs" -gt "$result" ]

    # Compute mode (should be lower)
    local compute_jobs
    compute_jobs=$(get_optimal_parallel_jobs "compute")
    [ "$compute_jobs" -le "$scan_jobs" ]
}

# ============================================================================
# Section Tracking Performance Tests
# ============================================================================

@test "section tracking has minimal overhead" {
    local start end elapsed

    # Define note_activity if not already defined (it's in bin/clean.sh)
    if ! declare -f note_activity > /dev/null 2>&1; then
        TRACK_SECTION=0
        SECTION_ACTIVITY=0
        note_activity() {
            if [[ $TRACK_SECTION -eq 1 ]]; then
                SECTION_ACTIVITY=1
            fi
        }
    fi

    # Warm up
    note_activity

    start=$(date +%s%N)
    for i in {1..1000}; do
        note_activity
    done
    end=$(date +%s%N)

    elapsed=$(( (end - start) / 1000000 ))

    # Should complete in less than 2000ms (relaxed for CI environments)
    [ "$elapsed" -lt 2000 ]
}
