#!/bin/bash
# LaunchServices cleanup helpers for `mo clean`.

set -euo pipefail

# shellcheck disable=SC2329
launch_services_extract_app_path_from_line() {
    local line="$1"
    [[ "$line" == */*".app"* ]] || return 1

    local path="/${line#*/}"
    path="${path%%.app*}.app"
    path="${path%/}"

    [[ "$path" == /* && "$path" == *.app ]] || return 1
    printf '%s\n' "$path"
}

# shellcheck disable=SC2329
launch_services_stale_app_path_is_safe() {
    local path="$1"

    [[ -n "$path" ]] || return 1
    [[ "$path" == /* ]] || return 1
    [[ "$path" == *.app ]] || return 1
    [[ "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 1

    case "$path" in
        *"/../"* | *"/.." | "../"* | "/System/"* | "/Library/Apple/"*)
            return 1
            ;;
    esac

    [[ ! -e "$path" ]]
}

# shellcheck disable=SC2329
launch_services_emit_missing_record_paths() {
    local -a record_paths=()
    local missing_record=false
    local line app_path

    _flush_launch_services_record() {
        if [[ "$missing_record" == "true" && ${#record_paths[@]} -gt 0 ]]; then
            local record_path
            for record_path in "${record_paths[@]}"; do
                if launch_services_stale_app_path_is_safe "$record_path"; then
                    printf '%s\n' "$record_path"
                fi
            done
        fi
        record_paths=()
        missing_record=false
    }

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "$line" ]]; then
            _flush_launch_services_record
            continue
        fi
        if [[ "$line" =~ ^[[:space:]]*bundle[[:space:]] ]]; then
            _flush_launch_services_record
        fi

        if [[ "$line" == *"Bundle node not found on disk"* ]]; then
            missing_record=true
        fi

        if app_path=$(launch_services_extract_app_path_from_line "$line"); then
            record_paths+=("$app_path")
        fi
    done

    _flush_launch_services_record
}

# shellcheck disable=SC2329
collect_stale_launch_services_app_paths() {
    local lsregister="$1"
    local dump_timeout="${2:-$MOLE_TIMEOUT_PKG_LIST_SEC}"

    [[ -x "$lsregister" ]] || return 0

    run_with_timeout "$dump_timeout" "$lsregister" -dump 2> /dev/null |
        launch_services_emit_missing_record_paths |
        LC_ALL=C sort -u
}

# The lsregister dump takes ten seconds and more on machines with a large
# LaunchServices database; a field machine blew even a 30s bound, so an
# in-run prefetch alone can never catch up there. The dump therefore runs in
# the background against a stable cache file that survives the run: even
# when it finishes after the clean ends, the next run consumes it. The
# cache only ever appears through an atomic rename, so a partial dump can
# never be consumed, and staleness is bounded by a TTL. A stale entry is
# harmless by construction: every candidate is re-verified against the disk
# at use time, so a reinstalled app is rejected and the worst case is a
# newly stale registration waiting one TTL to be noticed.
MOLE_LS_STALE_CACHE_FILE="$HOME/.cache/mole/ls_stale_candidates"
MOLE_LS_STALE_CACHE_TTL_SECONDS=86400
MOLE_LS_PREFETCH_PID=""

ls_stale_cache_is_fresh() {
    [[ -f "$MOLE_LS_STALE_CACHE_FILE" ]] || return 1
    local cache_mtime="" now="" age=""
    cache_mtime=$(get_file_mtime "$MOLE_LS_STALE_CACHE_FILE" 2> /dev/null || true)
    now=$(get_epoch_seconds)
    [[ "$cache_mtime" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] || return 1
    age=$((now - cache_mtime))
    [[ $age -ge 0 && $age -lt $MOLE_LS_STALE_CACHE_TTL_SECONDS ]]
}

prefetch_stale_launch_services_scan() {
    ls_stale_cache_is_fresh && return 0
    local lsregister
    lsregister=$(get_lsregister_path)
    [[ -x "$lsregister" ]] || return 0
    mkdir -p "$(dirname "$MOLE_LS_STALE_CACHE_FILE")" 2> /dev/null || return 0
    (
        local partial="$MOLE_LS_STALE_CACHE_FILE.partial.$$"
        if collect_stale_launch_services_app_paths "$lsregister" \
            "$((MOLE_TIMEOUT_DISK_VERIFY_SEC * 2))" > "$partial"; then
            mv -f "$partial" "$MOLE_LS_STALE_CACHE_FILE"
        else
            rm -f "$partial" 2> /dev/null || true # SAFE: exact partial file created above
        fi
    ) < /dev/null > /dev/null 2>&1 &
    MOLE_LS_PREFETCH_PID=$!
}

# shellcheck disable=SC2329
clean_stale_launch_services_registrations() {
    local lsregister
    lsregister=$(get_lsregister_path)
    [[ -x "$lsregister" ]] || return 0

    local candidates_file
    candidates_file=$(mktemp_file "launch_services_stale_apps") || return 0

    # The lsregister dump below takes seconds on a large LaunchServices
    # database; without a spinner the section looks hung (per-step loading
    # feedback).
    start_section_spinner "Scanning launch services..."
    local ls_scan_started_at=$SECONDS
    if [[ -n "$MOLE_LS_PREFETCH_PID" ]] || ls_stale_cache_is_fresh; then
        # A prefetch ran (or a previous run already left a fresh cache).
        # Give a nearly finished dump a short grace, then either consume the
        # cache or skip quietly; never fall back to a second inline dump.
        local grace_left=5
        while ! ls_stale_cache_is_fresh && [[ $grace_left -gt 0 ]] &&
            kill -0 "$MOLE_LS_PREFETCH_PID" 2> /dev/null; do
            sleep 1
            grace_left=$((grace_left - 1))
        done
        if ls_stale_cache_is_fresh; then
            if ! cp "$MOLE_LS_STALE_CACHE_FILE" "$candidates_file"; then
                stop_section_spinner
                debug_log "LaunchServices stale cache unreadable, skipping"
                return 0
            fi
            debug_log "PERF [LaunchServices stale scan] cached, waited $((SECONDS - ls_scan_started_at))s"
        else
            stop_section_spinner
            debug_log "LaunchServices stale scan has no fresh result yet, skipping this run"
            return 0
        fi
    else
        # No prefetch ran (standalone invocation): keep the bounded inline
        # scan so this function stays usable on its own.
        local ls_scan_rc=0
        collect_stale_launch_services_app_paths "$lsregister" > "$candidates_file" || ls_scan_rc=$?
        if [[ $ls_scan_rc -ne 0 ]]; then
            stop_section_spinner
            debug_log "LaunchServices stale app scan failed (rc=$ls_scan_rc after $((SECONDS - ls_scan_started_at))s)"
            return 0
        fi
        debug_log "PERF [LaunchServices stale scan] $((SECONDS - ls_scan_started_at))s"
    fi

    local max_items="${MOLE_LAUNCH_SERVICES_STALE_LIMIT:-50}"
    [[ "$max_items" =~ ^[0-9]+$ ]] || max_items=50
    [[ "$max_items" -gt 0 ]] || max_items=50

    local -a stale_apps=()
    local app_path
    while IFS= read -r app_path; do
        [[ -n "$app_path" ]] || continue
        if launch_services_stale_app_path_is_safe "$app_path"; then
            stale_apps+=("$app_path")
            if [[ ${#stale_apps[@]} -ge "$max_items" ]]; then
                break
            fi
        fi
    done < "$candidates_file"

    stop_section_spinner
    [[ ${#stale_apps[@]} -gt 0 ]] || return 0

    note_activity

    local count="${#stale_apps[@]}"
    local count_label="$count"
    local total_candidates
    total_candidates=$(wc -l < "$candidates_file" | tr -d '[:space:]')
    if [[ "$total_candidates" =~ ^[0-9]+$ && "$total_candidates" -gt "$count" ]]; then
        count_label="${count}+"
    fi

    if [[ "${DRY_RUN:-false}" == "true" || "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} LaunchServices stale app registrations · would unregister ${count_label}"
        echo -e "  ${GRAY}${ICON_SUBLIST}${NC} Example: ${GRAY}${stale_apps[0]/#$HOME/~}${NC}"
        return 0
    fi

    local success_count=0
    local failed_count=0
    start_section_spinner "Cleaning stale launch services..."
    for app_path in "${stale_apps[@]}"; do
        debug_log "Unregistering stale LaunchServices app: $app_path"
        if run_with_timeout "$MOLE_TIMEOUT_SHORT_QUERY_SEC" "$lsregister" -u "$app_path" > /dev/null 2>&1; then
            success_count=$((success_count + 1))
        else
            failed_count=$((failed_count + 1))
            debug_log "Failed to unregister stale LaunchServices app: $app_path"
        fi
    done
    stop_section_spinner

    if [[ $success_count -gt 0 ]]; then
        log_success "LaunchServices stale app registrations, $success_count removed"
    fi
    if [[ $failed_count -gt 0 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} LaunchServices stale app registrations, ${failed_count} failed"
    fi
}
