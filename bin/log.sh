#!/bin/bash
# Mole - Operations Log Viewer
# Query and analyze operation logs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib"

# shellcheck source=lib/core/base.sh
source "$LIB_DIR/core/base.sh"
# shellcheck source=lib/core/log.sh
source "$LIB_DIR/core/log.sh"

show_help() {
    cat <<EOF
Usage: mo log [OPTIONS]

View and analyze Mole operation logs.

OPTIONS:
  --tail <n>        Show last N entries (default: 50)
  --search <term>   Search for specific pattern
  --stats           Show operation statistics
  --today           Show only today's operations
  --command <cmd>   Filter by command (clean/uninstall/optimize/purge)
  --help            Show this help message

EXAMPLES:
  mo log                        # Show last 50 operations
  mo log --tail 100             # Show last 100 operations
  mo log --search node_modules  # Search for node_modules operations
  mo log --stats                # Show statistics
  mo log --today                # Show today's operations only
  mo log --command clean        # Show only clean operations

LOG LOCATION:
  ${OPERATIONS_LOG_FILE}

EOF
}

show_tail() {
    local count="${1:-50}"

    if [[ ! -f "$OPERATIONS_LOG_FILE" ]]; then
        echo -e "${YELLOW}No operation log found.${NC}"
        echo "Run some commands (e.g., mo clean) to generate logs."
        return 0
    fi

    echo -e "${BLUE}Last ${count} operations:${NC}"
    echo "────────────────────────────────────────────────────────────────"
    tail -n "$count" "$OPERATIONS_LOG_FILE"
}

search_log() {
    local term="$1"

    if [[ -z "$term" ]]; then
        echo -e "${RED}Error: Search term required${NC}"
        echo "Usage: mo log --search <term>"
        return 1
    fi

    if [[ ! -f "$OPERATIONS_LOG_FILE" ]]; then
        echo -e "${YELLOW}No operation log found.${NC}"
        return 0
    fi

    echo -e "${BLUE}Searching for: ${term}${NC}"
    echo "────────────────────────────────────────────────────────────────"

    local results
    results=$(grep -iF -- "$term" "$OPERATIONS_LOG_FILE" 2>/dev/null || true)

    if [[ -z "$results" ]]; then
        echo -e "${YELLOW}No matches found.${NC}"
    else
        echo "$results"
    fi
}

show_stats() {
    if [[ ! -f "$OPERATIONS_LOG_FILE" ]]; then
        echo -e "${YELLOW}No operation log found.${NC}"
        return 0
    fi

    echo -e "${BLUE}Operation Statistics${NC}"
    echo "────────────────────────────────────────────────────────────────"

    local total_lines
    total_lines=$(grep -c '^\[' "$OPERATIONS_LOG_FILE" 2>/dev/null || echo 0)
    echo -e "${GREEN}Total operations:${NC} $total_lines"
    echo ""

    echo -e "${GREEN}By command:${NC}"
    grep -o '\[clean\]\|\[uninstall\]\|\[optimize\]\|\[purge\]' "$OPERATIONS_LOG_FILE" 2>/dev/null |
        sort | uniq -c | sort -rn | sed 's/\[//g; s/\]//g' |
        awk '{printf "  %-15s %s\n", $2":", $1}' || echo "  No command data"
    echo ""

    echo -e "${GREEN}By action:${NC}"
    grep -o 'REMOVED\|SKIPPED\|FAILED\|REBUILT' "$OPERATIONS_LOG_FILE" 2>/dev/null |
        sort | uniq -c | sort -rn |
        awk '{printf "  %-15s %s\n", $2":", $1}' || echo "  No action data"
    echo ""

    echo -e "${GREEN}Recent sessions:${NC}"
    grep 'session started' "$OPERATIONS_LOG_FILE" 2>/dev/null | tail -n 5 || echo "  No session data"
}

show_today() {
    if [[ ! -f "$OPERATIONS_LOG_FILE" ]]; then
        echo -e "${YELLOW}No operation log found.${NC}"
        return 0
    fi

    local today
    today=$(date '+%Y-%m-%d')

    echo -e "${BLUE}Today's operations (${today}):${NC}"
    echo "────────────────────────────────────────────────────────────────"

    local results
    results=$(grep "^\[$today" "$OPERATIONS_LOG_FILE" 2>/dev/null || true)

    if [[ -z "$results" ]]; then
        echo -e "${YELLOW}No operations today.${NC}"
    else
        echo "$results"
    fi
}

filter_by_command() {
    local cmd="$1"

    if [[ -z "$cmd" ]]; then
        echo -e "${RED}Error: Command name required${NC}"
        echo "Usage: mo log --command <name>"
        echo "Available commands: clean, uninstall, optimize, purge"
        return 1
    fi

    if [[ ! -f "$OPERATIONS_LOG_FILE" ]]; then
        echo -e "${YELLOW}No operation log found.${NC}"
        return 0
    fi

    echo -e "${BLUE}Operations for command: ${cmd}${NC}"
    echo "────────────────────────────────────────────────────────────────"

    local results
    results=$(grep -F -- "[$cmd]" "$OPERATIONS_LOG_FILE" 2>/dev/null || true)

    if [[ -z "$results" ]]; then
        echo -e "${YELLOW}No operations found for ${cmd}.${NC}"
    else
        echo "$results"
    fi
}

main() {
    if [[ "${MO_NO_OPLOG:-}" == "1" ]]; then
        echo -e "${YELLOW}Operation logging is disabled (MO_NO_OPLOG=1).${NC}"
        echo "Enable it by unsetting the MO_NO_OPLOG environment variable."
        exit 0
    fi

    if [[ $# -eq 0 ]]; then
        show_tail 50
        exit 0
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --tail)
            shift
            show_tail "${1:-50}"
            exit 0
            ;;
        --search)
            shift
            if [[ -z "${1:-}" ]]; then
                echo -e "${RED}Error: --search requires an argument${NC}"
                exit 1
            fi
            search_log "$1"
            exit 0
            ;;
        --stats)
            show_stats
            exit 0
            ;;
        --today)
            show_today
            exit 0
            ;;
        --command)
            shift
            if [[ -z "${1:-}" ]]; then
                echo -e "${RED}Error: --command requires an argument${NC}"
                exit 1
            fi
            filter_by_command "$1"
            exit 0
            ;;
        --help | -h)
            show_help
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use 'mo log --help' for usage information."
            exit 1
            ;;
        esac
        # shellcheck disable=SC2317
        shift
    done
}

main "$@"
