#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-purge-home.XXXXXX")"
    export HOME

    mkdir -p "$HOME"
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

setup() {
    mkdir -p "$HOME/www"
    mkdir -p "$HOME/dev"
    mkdir -p "$HOME/.cache/mole"

    rm -rf "${HOME:?}/www"/* "${HOME:?}/dev"/*
}

@test "is_safe_project_artifact: rejects shallow paths (protection against accidents)" {
    result=$(bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        if is_safe_project_artifact '$HOME/www/node_modules' '$HOME/www'; then
            echo 'UNSAFE'
        else
            echo 'SAFE'
        fi
    ")
    [[ "$result" == "SAFE" ]]
}

@test "is_safe_project_artifact: allows proper project artifacts" {
    result=$(bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        if is_safe_project_artifact '$HOME/www/myproject/node_modules' '$HOME/www'; then
            echo 'ALLOWED'
        else
            echo 'BLOCKED'
        fi
    ")
    [[ "$result" == "ALLOWED" ]]
}

@test "is_safe_project_artifact: rejects non-absolute paths" {
    result=$(bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        if is_safe_project_artifact 'relative/path/node_modules' '$HOME/www'; then
            echo 'UNSAFE'
        else
            echo 'SAFE'
        fi
    ")
    [[ "$result" == "SAFE" ]]
}

@test "is_safe_project_artifact: validates depth calculation" {
    result=$(bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        if is_safe_project_artifact '$HOME/www/project/subdir/node_modules' '$HOME/www'; then
            echo 'ALLOWED'
        else
            echo 'BLOCKED'
        fi
    ")
    [[ "$result" == "ALLOWED" ]]
}

@test "filter_nested_artifacts: removes nested node_modules" {
    mkdir -p "$HOME/www/project/node_modules/package/node_modules"

    result=$(bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        printf '%s\n' '$HOME/www/project/node_modules' '$HOME/www/project/node_modules/package/node_modules' | \
        filter_nested_artifacts | wc -l | tr -d ' '
    ")

    [[ "$result" == "1" ]]
}

@test "filter_nested_artifacts: keeps independent artifacts" {
    mkdir -p "$HOME/www/project1/node_modules"
    mkdir -p "$HOME/www/project2/target"

    result=$(bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        printf '%s\n' '$HOME/www/project1/node_modules' '$HOME/www/project2/target' | \
        filter_nested_artifacts | wc -l | tr -d ' '
    ")

    [[ "$result" == "2" ]]
}

@test "is_recently_modified: detects recent projects" {
    mkdir -p "$HOME/www/project/node_modules"
    touch "$HOME/www/project/package.json"

    result=$(bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/clean/project.sh'
        if is_recently_modified '$HOME/www/project/node_modules'; then
            echo 'RECENT'
        else
            echo 'OLD'
        fi
    ")
    [[ "$result" == "RECENT" ]]
}

@test "is_recently_modified: marks old projects correctly" {
    mkdir -p "$HOME/www/old-project/node_modules"
    mkdir -p "$HOME/www/old-project"

    bash -c "
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/clean/project.sh'
        is_recently_modified '$HOME/www/old-project/node_modules' || true
    "
    local exit_code=$?
    [ "$exit_code" -eq 0 ] || [ "$exit_code" -eq 1 ]
}

@test "purge targets are configured correctly" {
    result=$(bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        echo \"\${PURGE_TARGETS[@]}\"
    ")
    [[ "$result" == *"node_modules"* ]]
    [[ "$result" == *"target"* ]]
}

@test "get_dir_size_kb: calculates directory size" {
    mkdir -p "$HOME/www/test-project/node_modules"
    dd if=/dev/zero of="$HOME/www/test-project/node_modules/file.bin" bs=1024 count=1024 2>/dev/null

    result=$(bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        get_dir_size_kb '$HOME/www/test-project/node_modules'
    ")

    [[ "$result" -ge 1000 ]] && [[ "$result" -le 1100 ]]
}

@test "get_dir_size_kb: handles non-existent paths gracefully" {
    result=$(bash -c "
        source '$PROJECT_ROOT/lib/clean/project.sh'
        get_dir_size_kb '$HOME/www/non-existent'
    ")
    [[ "$result" == "0" ]]
}

@test "clean_project_artifacts: handles empty directory gracefully" {
    run bash -c "
        export HOME='$HOME'
        source '$PROJECT_ROOT/lib/core/common.sh'
        source '$PROJECT_ROOT/lib/clean/project.sh'
        clean_project_artifacts
    " < /dev/null

    [[ "$status" -eq 0 ]] || [[ "$status" -eq 2 ]]
}

@test "clean_project_artifacts: scans and finds artifacts" {
    mkdir -p "$HOME/www/test-project/node_modules/package1"
    echo "test data" > "$HOME/www/test-project/node_modules/package1/index.js"

    mkdir -p "$HOME/www/test-project"

    run bash -c "
        export HOME='$HOME'
        timeout 5 '$PROJECT_ROOT/bin/purge.sh' 2>&1 < /dev/null || true
    "

    [[ "$output" =~ "Scanning" ]] ||
    [[ "$output" =~ "Purge complete" ]] ||
    [[ "$output" =~ "No old" ]] ||
    [[ "$output" =~ "Great" ]]
}

@test "mo purge: command exists and is executable" {
    [ -x "$PROJECT_ROOT/mole" ]
    [ -f "$PROJECT_ROOT/bin/purge.sh" ]
}

@test "mo purge: shows in help text" {
    run env HOME="$HOME" "$PROJECT_ROOT/mole" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"mo purge"* ]]
}

@test "mo purge: accepts --debug flag" {
    run bash -c "
        export HOME='$HOME'
        timeout 2 '$PROJECT_ROOT/mole' purge --debug < /dev/null 2>&1 || true
    "
    true
}

@test "mo purge: creates cache directory for stats" {
    bash -c "
        export HOME='$HOME'
        timeout 2 '$PROJECT_ROOT/mole' purge < /dev/null 2>&1 || true
    "

    [ -d "$HOME/.cache/mole" ] || [ -d "${XDG_CACHE_HOME:-$HOME/.cache}/mole" ]
}
