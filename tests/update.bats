#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    CURRENT_VERSION="$(grep '^VERSION=' "$PROJECT_ROOT/mole" | head -1 | sed 's/VERSION=\"\\(.*\\)\"/\\1/')"
    export CURRENT_VERSION

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-update-manager.XXXXXX")"
    export HOME

    mkdir -p "${HOME}/.cache/mole"
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

setup() {
    BREW_OUTDATED_COUNT=0
    BREW_FORMULA_OUTDATED_COUNT=0
    BREW_CASK_OUTDATED_COUNT=0
    APPSTORE_UPDATE_COUNT=0
    MACOS_UPDATE_AVAILABLE=false
    MOLE_UPDATE_AVAILABLE=false

    export MOCK_BIN_DIR="$BATS_TMPDIR/mole-mocks-$$"
    mkdir -p "$MOCK_BIN_DIR"
    export PATH="$MOCK_BIN_DIR:$PATH"
}

teardown() {
    rm -rf "$MOCK_BIN_DIR"
}

read_key() {
    echo "ESC"
    return 0
}

@test "ask_for_updates returns 1 when no updates available" {
    run bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/manage/update.sh"
BREW_OUTDATED_COUNT=0
APPSTORE_UPDATE_COUNT=0
MACOS_UPDATE_AVAILABLE=false
MOLE_UPDATE_AVAILABLE=false
ask_for_updates
EOF

    [ "$status" -eq 1 ]
}

@test "ask_for_updates shows updates and waits for input" {
    run bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/manage/update.sh"
BREW_OUTDATED_COUNT=5
BREW_FORMULA_OUTDATED_COUNT=3
BREW_CASK_OUTDATED_COUNT=2
APPSTORE_UPDATE_COUNT=1
MACOS_UPDATE_AVAILABLE=true
MOLE_UPDATE_AVAILABLE=true

read_key() { echo "ESC"; return 0; }

ask_for_updates
EOF

    [ "$status" -eq 1 ]  # ESC cancels
    [[ "$output" == *"Homebrew (5 updates)"* ]]
    [[ "$output" == *"App Store (1 apps)"* ]]
    [[ "$output" == *"macOS system"* ]]
    [[ "$output" == *"Mole"* ]]
}

@test "ask_for_updates accepts Enter when updates exist" {
    run bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/manage/update.sh"
BREW_OUTDATED_COUNT=2
BREW_FORMULA_OUTDATED_COUNT=2
MOLE_UPDATE_AVAILABLE=true
read_key() { echo "ENTER"; return 0; }
ask_for_updates
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"AVAILABLE UPDATES"* ]]
    [[ "$output" == *"yes"* ]]
}

@test "format_brew_update_label lists formula and cask counts" {
    run bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/manage/update.sh"
BREW_OUTDATED_COUNT=5
BREW_FORMULA_OUTDATED_COUNT=3
BREW_CASK_OUTDATED_COUNT=2
format_brew_update_label
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"3 formula"* ]]
    [[ "$output" == *"2 cask"* ]]
}

@test "perform_updates handles Homebrew success and Mole update" {
    run bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/manage/update.sh"

BREW_FORMULA_OUTDATED_COUNT=1
BREW_CASK_OUTDATED_COUNT=0
MOLE_UPDATE_AVAILABLE=true

FAKE_DIR="$HOME/fake-script-dir"
mkdir -p "$FAKE_DIR/lib/manage"
cat > "$FAKE_DIR/mole" <<'SCRIPT'
#!/usr/bin/env bash
echo "Already on latest version"
SCRIPT
chmod +x "$FAKE_DIR/mole"
SCRIPT_DIR="$FAKE_DIR/lib/manage"

brew_has_outdated() { return 0; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
reset_brew_cache() { echo "BREW_CACHE_RESET"; }
reset_mole_cache() { echo "MOLE_CACHE_RESET"; }
has_sudo_session() { return 1; }
ensure_sudo_session() { echo "ensure_sudo_session_called"; return 1; }

brew() {
    if [[ "$1" == "upgrade" ]]; then
        echo "Upgrading formula"
        return 0
    fi
    return 0
}

get_appstore_update_labels() { return 0; }
get_macos_update_labels() { return 0; }

perform_updates
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Updating Mole"* ]]
    [[ "$output" == *"Mole updated"* ]]
    [[ "$output" == *"MOLE_CACHE_RESET"* ]]
    [[ "$output" == *"All updates completed"* ]]
}

@test "update_via_homebrew reports already on latest version" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
MOLE_TEST_BREW_UPDATE_OUTPUT="Updated 0 formulae"
MOLE_TEST_BREW_UPGRADE_OUTPUT="Warning: mole 1.7.9 already installed"
MOLE_TEST_BREW_LIST_OUTPUT="mole 1.7.9"
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
brew() {
  case "$1" in
    update) echo "$MOLE_TEST_BREW_UPDATE_OUTPUT";;
    upgrade) echo "$MOLE_TEST_BREW_UPGRADE_OUTPUT";;
    list) if [[ "$2" == "--versions" ]]; then echo "$MOLE_TEST_BREW_LIST_OUTPUT"; fi ;;
  esac
}
export -f brew start_inline_spinner stop_inline_spinner
source "$PROJECT_ROOT/lib/core/common.sh"
update_via_homebrew "1.7.9"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Already on latest version"* ]]
}

@test "update_mole skips download when already latest" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" CURRENT_VERSION="$CURRENT_VERSION" PATH="$HOME/fake-bin:/usr/bin:/bin" TERM="dumb" bash --noprofile --norc << 'EOF'
set -euo pipefail
curl() {
  local out=""
  local url=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -o)
        out="$2"
        shift 2
        ;;
      http*://*)
        url="$1"
        shift
        ;;
      *)
        shift
        ;;
    esac
  done

  if [[ -n "$out" ]]; then
    echo "Installer executed" > "$out"
    return 0
  fi

  if [[ "$url" == *"api.github.com"* ]]; then
    echo "{\"tag_name\":\"$CURRENT_VERSION\"}"
  else
    echo "VERSION=\"$CURRENT_VERSION\""
  fi
}
export -f curl

brew() { exit 1; }
export -f brew

"$PROJECT_ROOT/mole" update
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Already on latest version"* ]]
}
