#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-clean-retention.XXXXXX")"
    export HOME
}

teardown_file() {
    if [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        rm -rf "$HOME"
    fi
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

read_retention_values() {
    env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" "$@" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
printf '%s|%s|%s|%s\n' \
    "$ORPHAN_AGE_THRESHOLD" \
    "$CLAUDE_VM_ORPHAN_AGE_THRESHOLD" \
    "$(_darwin_user_runtime_retention_days)" \
    "$(_support_cache_retention_days)"
EOF
}

@test "retention defaults remain 30 7 7 30 days" {
    run read_retention_values

    [ "$status" -eq 0 ]
    [ "$output" = "30|7|7|30" ]
}

@test "MOLE_RETENTION_DAYS accepts zero and positive integers" {
    run read_retention_values MOLE_RETENTION_DAYS=0
    [ "$status" -eq 0 ]
    [ "$output" = "0|0|0|0" ]

    run read_retention_values MOLE_RETENTION_DAYS=14
    [ "$status" -eq 0 ]
    [ "$output" = "14|14|14|14" ]

    run read_retention_values MOLE_RETENTION_DAYS=014
    [ "$status" -eq 0 ]
    [ "$output" = "14|14|14|14" ]
}

@test "empty and invalid total retention fall back to defaults" {
    run read_retention_values MOLE_RETENTION_DAYS=
    [ "$status" -eq 0 ]
    [ "$output" = "30|7|7|30" ]

    run read_retention_values MOLE_RETENTION_DAYS=-1
    [ "$status" -eq 0 ]
    [ "$output" = "30|7|7|30" ]

    run read_retention_values MOLE_RETENTION_DAYS=invalid
    [ "$status" -eq 0 ]
    [ "$output" = "30|7|7|30" ]

    run read_retention_values \
        MOLE_RETENTION_DAYS=-1 \
        MOLE_ORPHAN_AGE_DAYS=31 \
        MOLE_CLAUDE_VM_ORPHAN_AGE_DAYS=32 \
        MOLE_DARWIN_USER_RUNTIME_AGE_DAYS=33 \
        MOLE_SUPPORT_CACHE_AGE_DAYS=34
    [ "$status" -eq 0 ]
    [ "$output" = "31|32|33|34" ]
}

@test "total retention takes priority over legacy variables" {
    run read_retention_values \
        MOLE_RETENTION_DAYS=14 \
        ORPHAN_AGE_THRESHOLD=91 \
        MOLE_ORPHAN_AGE_DAYS=92 \
        MOLE_CLAUDE_VM_ORPHAN_AGE_DAYS=93 \
        MOLE_DARWIN_USER_RUNTIME_AGE_DAYS=94 \
        MOLE_SUPPORT_CACHE_AGE_DAYS=95

    [ "$status" -eq 0 ]
    [ "$output" = "14|14|14|14" ]
}

@test "legacy retention variables remain compatible without total override" {
    run read_retention_values \
        MOLE_ORPHAN_AGE_DAYS=31 \
        MOLE_CLAUDE_VM_ORPHAN_AGE_DAYS=32 \
        MOLE_DARWIN_USER_RUNTIME_AGE_DAYS=33 \
        MOLE_SUPPORT_CACHE_AGE_DAYS=34

    [ "$status" -eq 0 ]
    [ "$output" = "31|32|33|34" ]

    run read_retention_values ORPHAN_AGE_THRESHOLD=35 MOLE_ORPHAN_AGE_DAYS=31
    [ "$status" -eq 0 ]
    [ "$output" = "35|7|7|30" ]
}

@test "debug output reports one total retention override line" {
    run env \
        HOME="$HOME" \
        PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_TEST_MODE=1 \
        MOLE_TEST_NO_AUTH=1 \
        MO_DEBUG=1 \
        MOLE_RETENTION_DAYS=14 \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
start_cleanup
EOF

    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c "Retention override: 14 days")" -eq 1 ]
}

@test "normal output does not report retention override" {
    run env \
        HOME="$HOME" \
        PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_TEST_MODE=1 \
        MOLE_TEST_NO_AUTH=1 \
        MO_DEBUG=0 \
        MOLE_RETENTION_DAYS=14 \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
start_cleanup
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"Retention override:"* ]]
}

@test "clean help documents only the total retention variable" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
show_clean_help
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"MOLE_RETENTION_DAYS=N"* ]]
    [[ "$output" != *"MOLE_CLAUDE_VM_ORPHAN_AGE_DAYS"* ]]
    [[ "$output" != *"MOLE_DARWIN_USER_RUNTIME_AGE_DAYS"* ]]
    [[ "$output" != *"MOLE_SUPPORT_CACHE_AGE_DAYS"* ]]
}
