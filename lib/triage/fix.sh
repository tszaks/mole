#!/bin/bash
# Triage fixes.
# One authentication is the consent for the whole run: mo triage --fix
# authenticates once (password, or Touch ID via mo touchid), applies every
# safe fix without further prompts, and reports what it did. Nothing here
# deletes user data: process kills target orphans and respawnable daemons,
# and the only removal targets ephemeral automation profiles in the user
# temp dir.

set -euo pipefail

TRIAGE_FIXES_APPLIED=0

# Gate for the whole fix run. Password or Touch ID grants it; --yes (and
# therefore scripting/test mode) bypasses it. Returns 1 when the user
# declined or authentication failed, and the caller skips all fixes.
triage_request_fix_authority() {
    [[ "${TRIAGE_ASSUME_YES:-false}" == "true" ]] && return 0
    if ensure_sudo_session "Applying triage fixes"; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Admin access granted"
        return 0
    fi
    echo -e "${GRAY}No admin access; fixes skipped. Re-run and authenticate, or use --yes${NC}"
    return 1
}

# Restart runaway daemons. launchd respawns each of these clean; the stuck
# state (a wedged run loop, a corrupted in-memory queue) dies with the process.
triage_fix_runaway_daemons() {
    [[ ${#TRIAGE_RUNAWAY_PIDS[@]} -gt 0 ]] || return 0
    echo
    echo -e "${PURPLE_BOLD}${ICON_ARROW} Daemon Restart${NC}"
    local i pid name
    for i in "${!TRIAGE_RUNAWAY_PIDS[@]}"; do
        pid="${TRIAGE_RUNAWAY_PIDS[$i]}"
        name="${TRIAGE_RUNAWAY_NAMES[$i]}"
        if kill -TERM "$pid" 2> /dev/null; then
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} ${name} restarted"
            TRIAGE_FIXES_APPLIED=$((TRIAGE_FIXES_APPLIED + 1))
        else
            echo -e "  ${RED}${ICON_ERROR}${NC} Could not signal ${name} (pid ${pid})"
        fi
    done
}

# Kill leaked automation browser trees one PID at a time so failures are
# visible; a bulk kill of a long list can silently no-op.
triage_fix_leaked_browsers() {
    [[ ${#TRIAGE_ORPHAN_BROWSER_PIDS[@]} -gt 0 || ${#TRIAGE_STALE_PROFILE_DIRS[@]} -gt 0 ]] || return 0
    echo
    echo -e "${PURPLE_BOLD}${ICON_ARROW} Browser Cleanup${NC}"

    if [[ ${#TRIAGE_ORPHAN_BROWSER_PIDS[@]} -gt 0 ]]; then
        local pid ok=0
        for pid in "${TRIAGE_ORPHAN_BROWSER_PIDS[@]}"; do
            kill -TERM "$pid" 2> /dev/null && ok=$((ok + 1))
        done
        sleep 1
        # Escalate for anything that ignored SIGTERM.
        for pid in "${TRIAGE_ORPHAN_BROWSER_PIDS[@]}"; do
            kill -0 "$pid" 2> /dev/null && kill -9 "$pid" 2> /dev/null && ok=$((ok + 1))
        done
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} ${ok} leaked processes killed"
        TRIAGE_FIXES_APPLIED=$((TRIAGE_FIXES_APPLIED + 1))
    fi

    if [[ ${#TRIAGE_STALE_PROFILE_DIRS[@]} -gt 0 ]]; then
        local d removed=0
        for d in "${TRIAGE_STALE_PROFILE_DIRS[@]}"; do
            # Never touch a profile that a live process is still using.
            if pgrep -qf "$d" 2> /dev/null; then
                continue
            fi
            safe_remove "$d" true && removed=$((removed + 1))
        done
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} ${removed} stale profile dirs removed"
        TRIAGE_FIXES_APPLIED=$((TRIAGE_FIXES_APPLIED + 1))
    fi
}

# The iCloud spiral is guidance-only, shown under --fix because for a
# non-automatable problem the guidance IS the fix. Automating it is
# dangerous: renaming a direct child of the CloudDocs sync root blocks in
# rename(2) forever (full-domain reconciliation), and a corrupted local
# index can require a reboot before any move completes.
triage_explain_icloud_spiral() {
    [[ "${TRIAGE_ICLOUD_SPIRAL:-false}" == "true" ]] || return 0
    echo
    echo -e "${PURPLE_BOLD}${ICON_ARROW} iCloud Migration (manual)${NC}"
    echo -e "  ${GRAY}${ICON_LIST} Move build/agent dirs out of ~/Documents and ~/Desktop to ~/Projects,${NC}"
    echo -e "  ${GRAY}  then symlink the old path back so tools keep working${NC}"
    echo -e "  ${GRAY}${ICON_LIST} Move SUBDIRECTORIES one at a time; renaming the top-level folder itself${NC}"
    echo -e "  ${GRAY}  deadlocks (iCloud sync-root rename). A hung mv is safe to kill -9${NC}"
    echo -e "  ${GRAY}${ICON_LIST} If fileproviderd stays pinned and 'brctl status' shows itemNotFound${NC}"
    echo -e "  ${GRAY}  retries, the local index is corrupted: reboot, then finish the move${NC}"
    echo -e "  ${GRAY}${ICON_LIST} Delete 'name 2' conflict copies only after the move, only when the${NC}"
    echo -e "  ${GRAY}  original sibling exists${NC}"
    echo -e "  ${GRAY}${ICON_LIST} Spotlight reindexes ~1h afterwards; that is convergence, not relapse${NC}"
}

# Closing summary: say what actually happened.
triage_fix_summary() {
    echo
    if [[ "$TRIAGE_FIXES_APPLIED" -gt 0 ]]; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} ${TRIAGE_FIXES_APPLIED} fix(es) applied. Re-run ${GREEN}mo triage${NC} to verify"
    else
        echo -e "${GRAY}Nothing was changed${NC}"
    fi
}
