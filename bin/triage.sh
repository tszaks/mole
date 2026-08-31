#!/bin/bash
# Mole - Triage command.
# Diagnoses why the Mac feels bogged down and applies safe fixes.
# Detection is read-only. --fix authenticates once (password or Touch ID),
# then applies every safe fix and reports what it did.

set -euo pipefail

export LC_ALL=C
export LANG=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/core/common.sh"
source "$SCRIPT_DIR/lib/core/sudo.sh"
source "$SCRIPT_DIR/lib/triage/detect.sh"
source "$SCRIPT_DIR/lib/triage/fix.sh"

trap 'stop_sudo_session 2> /dev/null || true' EXIT INT TERM

TRIAGE_APPLY_FIXES=false
TRIAGE_ASSUME_YES=false

show_triage_help() {
    echo "Usage: mo triage [OPTIONS]"
    echo
    echo "Diagnose why this Mac is slow: swap exhaustion, runaway system daemons,"
    echo "leaked automation browsers, iCloud sync spirals, stale cloud-sync domains."
    echo
    echo "Options:"
    echo "  --fix             Authenticate once, apply all safe fixes, report results"
    echo "  --yes             With --fix: skip the authentication gate (scripting)"
    echo "  -h, --help        Show this help"
    echo
    echo "Detection is always read-only and only reports problems; a healthy check"
    echo "prints nothing. Fixes never touch user data: they restart respawnable"
    echo "daemons, kill orphaned automation browsers, and remove stale browser"
    echo "profiles from the user temp dir. The iCloud spiral gets manual migration"
    echo "steps under --fix instead of an autofix; automating it is not safe."
}

for arg in "$@"; do
    case "$arg" in
        --fix) TRIAGE_APPLY_FIXES=true ;;
        --yes | -y) TRIAGE_ASSUME_YES=true ;;
        -h | --help)
            show_triage_help
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            show_triage_help
            exit 1
            ;;
    esac
done

main() {
    printf '\n'
    echo -e "${PURPLE_BOLD}Triage${NC}"
    echo
    triage_system_line
    echo
    echo -e "${BLUE}DIAGNOSIS${NC}"

    triage_detect_memory || true
    triage_detect_runaway_daemons || true
    triage_detect_leaked_browsers || true
    triage_detect_icloud_spiral || true
    triage_detect_stale_cloud_domains || true

    if [[ "$TRIAGE_FINDING_COUNT" -eq 0 ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No known slowdown causes found"
        echo
        exit 0
    fi

    local fixable=$((${#TRIAGE_RUNAWAY_PIDS[@]} + ${#TRIAGE_ORPHAN_BROWSER_PIDS[@]} + ${#TRIAGE_STALE_PROFILE_DIRS[@]}))

    # Findings but nothing automatable: guidance is all there is to offer.
    if [[ "$fixable" -eq 0 ]]; then
        triage_explain_icloud_spiral
        echo
        exit 0
    fi

    # On a terminal, offer the fix right here (menu launches land in this
    # path); non-interactive runs stay read-only unless --fix was passed.
    if [[ "$TRIAGE_APPLY_FIXES" != "true" ]]; then
        if [[ -t 0 ]]; then
            echo
            echo -ne "${PURPLE}${ICON_ARROW}${NC} Apply safe fixes? ${GREEN}Enter${NC} continue, ${GRAY}Space${NC} skip: "
            local choice
            choice=$(read_key)
            printf '\r\033[2K'
            case "$choice" in
                "ENTER") TRIAGE_APPLY_FIXES=true ;;
                *)
                    echo -e "${GRAY}Skipped. Run ${NC}mo triage --fix${GRAY} anytime${NC}"
                    echo
                    exit 0
                    ;;
            esac
        else
            echo
            echo -e "${GRAY}Run ${NC}mo triage --fix${GRAY} to apply safe fixes${NC}"
            echo
            exit 0
        fi
    else
        echo
    fi

    if triage_request_fix_authority; then
        triage_fix_runaway_daemons
        triage_fix_leaked_browsers
    fi
    triage_explain_icloud_spiral
    triage_fix_summary
    echo
}

main
