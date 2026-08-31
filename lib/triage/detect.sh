#!/bin/bash
# Triage detectors.
# Read-only checks that explain why a Mac feels bogged down.
# House grammar: silence means healthy. Detectors print findings only
# (short label + optional gray sub-hints) and return 0 on a finding.

set -euo pipefail

readonly MOLE_TRIAGE_SWAP_WARN_PCT_DEFAULT=60
readonly MOLE_TRIAGE_SWAP_CRIT_PCT_DEFAULT=85
readonly MOLE_TRIAGE_DAEMON_CPU_PCT_DEFAULT=50
readonly MOLE_TRIAGE_STALE_PROFILE_MIN_AGE_HOURS=2

# Daemons that are safe to restart because launchd respawns them clean.
readonly -a MOLE_TRIAGE_RESTARTABLE_DAEMONS=(
    "ControlCenter"
    "fileproviderd"
    "bird"
    "CursorUIViewService"
    "NotificationCenter"
)

# Populated by detectors, consumed by bin/triage.sh and lib/triage/fix.sh.
TRIAGE_RUNAWAY_PIDS=()
TRIAGE_RUNAWAY_NAMES=()
TRIAGE_ORPHAN_BROWSER_PIDS=()
TRIAGE_STALE_PROFILE_DIRS=()
TRIAGE_ICLOUD_SPIRAL=false
TRIAGE_FINDING_COUNT=0

triage_swap_warn_pct() {
    local v="${MOLE_TRIAGE_SWAP_WARN_PCT:-$MOLE_TRIAGE_SWAP_WARN_PCT_DEFAULT}"
    [[ "$v" =~ ^[0-9]+$ ]] || v="$MOLE_TRIAGE_SWAP_WARN_PCT_DEFAULT"
    printf '%s\n' "$v"
}

triage_swap_crit_pct() {
    local v="${MOLE_TRIAGE_SWAP_CRIT_PCT:-$MOLE_TRIAGE_SWAP_CRIT_PCT_DEFAULT}"
    [[ "$v" =~ ^[0-9]+$ ]] || v="$MOLE_TRIAGE_SWAP_CRIT_PCT_DEFAULT"
    printf '%s\n' "$v"
}

triage_daemon_cpu_pct() {
    local v="${MOLE_TRIAGE_DAEMON_CPU_PCT:-$MOLE_TRIAGE_DAEMON_CPU_PCT_DEFAULT}"
    [[ "$v" =~ ^[0-9]+$ ]] || v="$MOLE_TRIAGE_DAEMON_CPU_PCT_DEFAULT"
    printf '%s\n' "$v"
}

_triage_note_finding() {
    TRIAGE_FINDING_COUNT=$((TRIAGE_FINDING_COUNT + 1))
}

# One dense stat line, same shape as optimize's system summary.
triage_system_line() {
    local load cores procs swap_line swap_used swap_total
    load=$(sysctl -n vm.loadavg 2> /dev/null | awk '{print $2}')
    cores=$(sysctl -n hw.ncpu 2> /dev/null)
    procs=$(ps -A | wc -l | tr -d ' ')
    swap_line=$(sysctl -n vm.swapusage 2> /dev/null)
    swap_used=$(echo "$swap_line" | awk '{print $6}' | cut -d. -f1)
    swap_total=$(echo "$swap_line" | awk '{print $3}' | cut -d. -f1)
    echo -e "${ICON_ADMIN} System  Load ${load:-?} (${cores:-?} cores) | Swap ${swap_used:-?}/${swap_total:-?} MB | ${procs} processes"
}

# --- Memory and swap pressure ------------------------------------------------

triage_detect_memory() {
    local swap_line swap_total swap_used swap_pct free_pct
    swap_line=$(sysctl -n vm.swapusage 2> /dev/null) || return 1
    swap_total=$(echo "$swap_line" | awk '{print $3}' | sed 's/M$//' | cut -d. -f1)
    swap_used=$(echo "$swap_line" | awk '{print $6}' | sed 's/M$//' | cut -d. -f1)
    [[ -n "$swap_total" && -n "$swap_used" ]] || return 1

    if [[ "$swap_total" -eq 0 ]]; then
        swap_pct=0
    else
        swap_pct=$((swap_used * 100 / swap_total))
    fi

    local warn crit
    warn=$(triage_swap_warn_pct)
    crit=$(triage_swap_crit_pct)

    if [[ "$swap_pct" -ge "$crit" ]]; then
        free_pct=$(memory_pressure 2> /dev/null | awk -F': ' '/free percentage/ {gsub(/%/,"",$2); print int($2)}' | tail -1)
        echo -e "  ${RED}${ICON_ERROR}${NC} Swap nearly full: ${swap_used}M of ${swap_total}M (${swap_pct}%)"
        echo -e "    ${GRAY}${ICON_REVIEW} ${free_pct:-?}% memory free; apps are paging to SSD on every switch${NC}"
        _triage_note_finding
        return 0
    elif [[ "$swap_pct" -ge "$warn" ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Swap elevated: ${swap_used}M of ${swap_total}M (${swap_pct}%)"
        _triage_note_finding
        return 0
    fi
    return 1
}

# --- Runaway system daemons ---------------------------------------------------
# ps %cpu on Darwin is a lifetime average (cputime / elapsed), so a long-lived
# process showing a high value has been stuck the whole time, not spiking now.
# A second instantaneous sample from top confirms it is still burning.

triage_detect_runaway_daemons() {
    local threshold found=1
    threshold=$(triage_daemon_cpu_pct)
    TRIAGE_RUNAWAY_PIDS=()
    TRIAGE_RUNAWAY_NAMES=()

    local live_sample
    live_sample=$(top -l 2 -n 20 -o cpu -stats pid,cpu,command 2> /dev/null | awk '/^PID/{f++} f==2') || true

    local name pid avg rss etime live
    for name in "${MOLE_TRIAGE_RESTARTABLE_DAEMONS[@]}" "WindowServer"; do
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            pid=$(echo "$line" | awk '{print $1}')
            avg=$(echo "$line" | awk '{print int($2)}')
            rss=$(echo "$line" | awk '{print int($3/1024)}')
            etime=$(echo "$line" | awk '{print $4}')
            [[ "$avg" -ge "$threshold" ]] || continue

            live=$(echo "$live_sample" | awk -v p="$pid" '$1==p {print int($2)}')
            [[ -n "$live" ]] || live="$avg"
            [[ "$live" -ge "$threshold" ]] || continue

            echo -e "  ${RED}${ICON_ERROR}${NC} Runaway daemon: ${name} ~${live}% CPU sustained, ${rss}MB, up ${etime}"
            if [[ "$name" == "WindowServer" ]]; then
                echo -e "    ${GRAY}${ICON_REVIEW} usually dragged up by another runaway; restart needs logout${NC}"
            else
                TRIAGE_RUNAWAY_PIDS+=("$pid")
                TRIAGE_RUNAWAY_NAMES+=("$name")
            fi
            _triage_note_finding
            found=0
        done < <(ps -Ao pid,%cpu,rss,etime,comm | awk -v n="$name" '$5 ~ ("(^|/)" n "$")')
    done

    return "$found"
}

# --- Leaked automation browsers ------------------------------------------------
# Playwright/agent sessions leak headless Chrome trees when their MCP servers
# die without cleanup. Orphaned daemons reparent to launchd (ppid 1).

triage_detect_leaked_browsers() {
    TRIAGE_ORPHAN_BROWSER_PIDS=()
    TRIAGE_STALE_PROFILE_DIRS=()

    local orphan_daemons chrome_pids
    orphan_daemons=$(ps -Ao pid,ppid,command | awk '/playwright-core\/lib\/entry\/cliDaemon\.js/ && $2==1 && !/awk/ {print $1}') || true
    # Chrome processes on ephemeral automation profiles, older than one day
    # (etime containing "-" means days). Younger ones may belong to a live session.
    chrome_pids=$(ps -Ao pid,etime,command | awk '/playwright_chromiumdev_profile/ && !/awk/ && $2 ~ /-/ {print $1}') || true

    local tmpdir
    tmpdir=$(getconf DARWIN_USER_TEMP_DIR 2> /dev/null) || tmpdir=""
    if [[ -n "$tmpdir" ]]; then
        local d age_hours now
        now=$(date +%s)
        for d in "$tmpdir"playwright_chromiumdev_profile-*; do
            [[ -d "$d" ]] || continue
            age_hours=$(((now - $(stat -f %m "$d" 2> /dev/null || echo "$now")) / 3600))
            [[ "$age_hours" -ge "$MOLE_TRIAGE_STALE_PROFILE_MIN_AGE_HOURS" ]] && TRIAGE_STALE_PROFILE_DIRS+=("$d")
        done
    fi

    local pid
    for pid in $orphan_daemons $chrome_pids; do
        TRIAGE_ORPHAN_BROWSER_PIDS+=("$pid")
    done

    local proc_count=${#TRIAGE_ORPHAN_BROWSER_PIDS[@]}
    local dir_count=${#TRIAGE_STALE_PROFILE_DIRS[@]}
    [[ "$proc_count" -gt 0 || "$dir_count" -gt 0 ]] || return 1

    if [[ "$proc_count" -gt 0 ]]; then
        local rss_mb
        rss_mb=$(ps -Ao rss,command | awk '/playwright_chromiumdev_profile|cliDaemon\.js/ && !/awk/ {s+=$1} END {print int(s/1024)}')
        echo -e "  ${RED}${ICON_ERROR}${NC} Leaked automation browsers: ${proc_count} orphaned processes, ~${rss_mb:-?}MB"
        echo -e "    ${GRAY}${ICON_REVIEW} left behind by dead Playwright/agent sessions${NC}"
    fi
    [[ "$dir_count" -gt 0 ]] && echo -e "  ${YELLOW}${ICON_WARNING}${NC} Stale browser profiles: ${dir_count} temp dirs"
    _triage_note_finding
    return 0
}

# --- iCloud sync spiral ---------------------------------------------------------
# Build artifacts under iCloud-synced folders (Desktop/Documents) make
# fileproviderd churn forever: rewrites mid-upload spawn "name 2" conflict
# dirs, which create more files to sync, which create more conflicts.

triage_detect_icloud_spiral() {
    TRIAGE_ICLOUD_SPIRAL=false
    local docs_synced
    docs_synced=$(defaults read com.apple.finder FXICloudDriveDocuments 2> /dev/null) || docs_synced=0
    [[ "$docs_synced" == "1" ]] || return 1

    local fp_pid fp_avg
    fp_pid=$(pgrep -x fileproviderd | head -1) || fp_pid=""
    fp_avg=0
    [[ -n "$fp_pid" ]] && fp_avg=$(ps -o %cpu= -p "$fp_pid" 2> /dev/null | awk '{print int($1)}')

    local artifacts=0 conflicts=0 root
    for root in "$HOME/Documents" "$HOME/Desktop"; do
        [[ -d "$root" ]] || continue
        artifacts=$((artifacts + $(find "$root" -maxdepth 6 -type d \( -name node_modules -o -name dist -o -name .next -o -name .vercel -o -name .turbo \) -not -path '*/node_modules/*/*' 2> /dev/null | head -500 | wc -l | tr -d ' ')))
        conflicts=$((conflicts + $(find "$root" -maxdepth 8 -type d \( -name "* 2" -o -name "* 3" \) 2> /dev/null | head -200 | wc -l | tr -d ' ')))
    done

    if [[ "$artifacts" -gt 0 && ("$fp_avg" -ge 25 || "$conflicts" -gt 5) ]]; then
        TRIAGE_ICLOUD_SPIRAL=true
        echo -e "  ${RED}${ICON_ERROR}${NC} iCloud syncing build artifacts: ${artifacts} dirs, ${conflicts} conflict copies"
        echo -e "    ${GRAY}${ICON_REVIEW} node_modules/dist under ~/Documents or ~/Desktop keep fileproviderd churning${NC}"
        echo -e "    ${GRAY}${ICON_REVIEW} run ${NC}mo triage --fix${GRAY} for the safe migration steps${NC}"
        _triage_note_finding
        return 0
    elif [[ "$artifacts" -gt 0 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Build artifacts in iCloud folders: ${artifacts} dirs"
        echo -e "    ${GRAY}${ICON_REVIEW} not spiraling yet, but every build re-syncs them${NC}"
        _triage_note_finding
        return 0
    fi
    return 1
}

# --- Stale cloud-sync provider domains ------------------------------------------

triage_detect_stale_cloud_domains() {
    local found=1 d
    for d in "$HOME/Library/CloudStorage"/*" ("*")"*; do
        [[ -d "$d" ]] || continue
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Stale sync domain: $(basename "$d")"
        echo -e "    ${GRAY}${ICON_REVIEW} leftover duplicate; quit the provider app, then remove it in Finder${NC}"
        _triage_note_finding
        found=0
    done
    return "$found"
}
