#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-dev-extended.XXXXXX")"
    export HOME

    mkdir -p "$HOME"
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

@test "clean_dev_elixir cleans mix and hex caches" {
    mkdir -p "$HOME/.mix" "$HOME/.hex"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2"; }
clean_dev_elixir
EOF

    [ "$status" -eq 0 ]

    [[ "$output" == *"Hex cache"* ]]
}

@test "clean_dev_haskell cleans cabal install and stack caches" {
    mkdir -p "$HOME/.cabal" "$HOME/.stack"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2"; }
clean_dev_haskell
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Cabal install cache"* ]]

}

@test "clean_dev_ocaml cleans opam cache" {
    mkdir -p "$HOME/.opam"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2"; }
clean_dev_ocaml
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Opam cache"* ]]
}

@test "clean_dev_editors cleans VS Code and Zed caches" {
    mkdir -p "$HOME/Library/Caches/com.microsoft.VSCode" "$HOME/Library/Application Support/Code" "$HOME/Library/Caches/Zed"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2"; }
clean_dev_editors
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"VS Code cached data"* ]]

    [[ "$output" == *"Zed cache"* ]]
}
