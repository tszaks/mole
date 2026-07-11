#!/bin/bash
# Format files changed by Claude Code or Codex with the project's configured
# formatters. Stdin is the tool hook payload (JSON). Failures must not block
# the edit.

set -u

if ! command -v jq > /dev/null 2>&1; then
    exit 0
fi

PAYLOAD=$(cat)
HOOK_CWD=$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty' 2> /dev/null || true)
[[ -n "$HOOK_CWD" ]] || HOOK_CWD="$PWD"

PROJECT_ROOT=$(git -C "$HOOK_CWD" rev-parse --show-toplevel 2> /dev/null || true)
[[ -n "$PROJECT_ROOT" ]] || exit 0
PROJECT_ROOT=$(cd -P "$PROJECT_ROOT" 2> /dev/null && pwd) || exit 0

format_repo_file() {
    local input_path="$1"
    local candidate=""
    local candidate_dir=""
    local resolved=""

    case "$input_path" in
        /*) candidate="$input_path" ;;
        *) candidate="$HOOK_CWD/$input_path" ;;
    esac

    # Never follow an edited symlink outside the repository.
    [[ -f "$candidate" && ! -L "$candidate" ]] || return 0
    candidate_dir=$(cd -P "$(dirname "$candidate")" 2> /dev/null && pwd) || return 0
    resolved="$candidate_dir/$(basename "$candidate")"
    case "$resolved" in
        "$PROJECT_ROOT"/*) ;;
        *) return 0 ;;
    esac

    case "$resolved" in
        *.sh | "$PROJECT_ROOT/mole")
            if command -v shfmt > /dev/null 2>&1; then
                shfmt -i 4 -ci -sr -w "$resolved" > /dev/null 2>&1 || true
            fi
            ;;
        *.go)
            if command -v goimports > /dev/null 2>&1; then
                goimports -w -local github.com/tw93/mole "$resolved" > /dev/null 2>&1 || true
            elif command -v gofmt > /dev/null 2>&1; then
                gofmt -w "$resolved" > /dev/null 2>&1 || true
            fi
            ;;
    esac
}

# Claude Edit/Write/MultiEdit sends one file_path. Codex apply_patch sends the
# whole patch in tool_input.command, so collect every added, updated, or moved
# destination from the patch header.
FILE=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // empty' 2> /dev/null || true)
if [[ -n "$FILE" ]]; then
    format_repo_file "$FILE"
    exit 0
fi

PATCH=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2> /dev/null || true)
[[ -n "$PATCH" ]] || exit 0
while IFS= read -r line; do
    case "$line" in
        '*** Update File: '*) FILE="${line#'*** Update File: '}" ;;
        '*** Add File: '*) FILE="${line#'*** Add File: '}" ;;
        '*** Move to: '*) FILE="${line#'*** Move to: '}" ;;
        *) continue ;;
    esac
    format_repo_file "$FILE"
done <<EOF
$PATCH
EOF

exit 0
