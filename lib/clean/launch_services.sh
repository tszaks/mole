#!/bin/bash
# LaunchServices cleanup helpers for `mo clean`.

set -euo pipefail

# shellcheck disable=SC2329
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
    # A full lsregister dump is a million-plus lines on a real machine (macOS
    # 26 measured ~1.65M / ~15s). The original bash loop forked one command
    # substitution per line, which turned a multi-second dump into minutes of
    # parsing and made the scan time out on every run. One awk pass does the
    # record grouping and path extraction; the bash safety filter below then
    # vets only the surviving candidates, so the audited policy check stays
    # in one place.
    #
    # LC_ALL=C is load-bearing: the dump carries arbitrary app-name bytes,
    # including invalid UTF-8. A UTF-8 locale makes some awk builds abort
    # mid-stream with "towc: multibyte conversion failure", which zeroed the
    # whole scan (issue #1395 class). Byte-mode matching is correct here:
    # the marker and path shapes are ASCII.
    local candidate
    LC_ALL=C awk '
        function flush_record(    i) {
            if (missing && n > 0) {
                for (i = 1; i <= n; i++) print paths[i]
            }
            n = 0
            missing = 0
        }
        /^[[:space:]]*bundle[[:space:]]/ { flush_record() }
        $0 == "" {
            flush_record()
            next
        }
        index($0, "Bundle node not found on disk") > 0 { missing = 1 }
        {
            slash = index($0, "/")
            if (slash > 0) {
                p = substr($0, slash)
                ai = index(p, ".app")
                if (ai > 0) {
                    paths[++n] = substr(p, 1, ai + 3)
                }
            }
        }
        END { flush_record() }
    ' | while IFS= read -r candidate || [[ -n "$candidate" ]]; do
        [[ -n "$candidate" ]] || continue
        if launch_services_stale_app_path_is_safe "$candidate"; then
            printf '%s\n' "$candidate"
        fi
    done || true
    # The filter stage never fails the scan closed: a partial or noisy dump
    # still yields every path that survived the safety check. Callers decide
    # whether an empty result is a hard miss.
    return 0
}

# Default bound matches the prefetch budget. The old PKG_LIST (10s) default
# was enough for small databases and timed out on every large one (issue
# #1395: macOS 26 machines with 1M+ line dumps need ~15s just for lsregister).
# shellcheck disable=SC2329
collect_stale_launch_services_app_paths() {
    local lsregister="$1"
    local dump_timeout="${2:-$((MOLE_TIMEOUT_DISK_VERIFY_SEC * 2))}"

    [[ -x "$lsregister" ]] || return 0

    # Capture to a temp file so a mid-dump timeout can still hand back the
    # candidates already parsed. Every path is re-checked against the disk
    # at use time, so a partial list is same-or-safer than skipping entirely.
    local out_file=""
    out_file=$(mktemp "${TMPDIR:-/tmp}/mole-ls-stale.XXXXXX") || return 1
    local pipe_rc=0
    run_with_timeout "$dump_timeout" "$lsregister" -dump 2> /dev/null |
        launch_services_emit_missing_record_paths |
        LC_ALL=C sort -u > "$out_file" || pipe_rc=$?

    if [[ -s "$out_file" ]]; then
        cat "$out_file"
        rm -f -- "$out_file" 2> /dev/null || true # SAFE: exact temp created above
        return 0
    fi
    rm -f -- "$out_file" 2> /dev/null || true # SAFE: exact temp created above
    return "$pipe_rc"
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
# Grace after the App leftovers section starts: give a nearly finished
# background dump time to land the cache before we skip. 15s covers the
# measured macOS 26 dump; longer waits only stall the section. Deliberately a
# constant, not an override: running out of grace degrades to "deferred to next
# clean" rather than failing, so no user has a reason to tune it.
MOLE_LS_STALE_GRACE_SECONDS=15
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
        # mktemp in the destination directory, then verify the path is the
        # regular file we just made: a predictable partial name could be
        # pre-planted as a symlink and turn this background redirect into a
        # write through it. Same-directory keeps the final mv atomic.
        local partial=""
        partial=$(mktemp "$MOLE_LS_STALE_CACHE_FILE.partial.XXXXXX") || exit 0
        [[ -f "$partial" && ! -L "$partial" ]] || exit 0
        # collect_stale already fail-softs: non-empty partial output is a
        # successful cache even when lsregister was killed by the timeout.
        if collect_stale_launch_services_app_paths "$lsregister" \
            "$((MOLE_TIMEOUT_DISK_VERIFY_SEC * 2))" > "$partial" &&
            [[ -s "$partial" ]]; then
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
        local grace_left=$MOLE_LS_STALE_GRACE_SECONDS
        while ! ls_stale_cache_is_fresh && [[ $grace_left -gt 0 ]] &&
            kill -0 "$MOLE_LS_PREFETCH_PID" 2> /dev/null; do
            sleep 1
            grace_left=$((grace_left - 1))
        done
        if ls_stale_cache_is_fresh; then
            if ! cp "$MOLE_LS_STALE_CACHE_FILE" "$candidates_file"; then
                stop_section_spinner
                debug_log "LaunchServices stale cache unreadable, skipping"
                echo -e "  ${GRAY}${ICON_WARNING}${NC} LaunchServices stale registrations · scan skipped (disk cleanup unaffected)"
                note_activity
                return 0
            fi
            debug_log "PERF [LaunchServices stale scan] cached, waited $((SECONDS - ls_scan_started_at))s"
        else
            stop_section_spinner
            debug_log "LaunchServices stale scan has no fresh result yet, skipping this run"
            # Visible so users do not read a silent App leftovers section as
            # "leftovers are broken"; this step only unregisters dead records
            # and frees no disk (issue #1395).
            echo -e "  ${GRAY}${ICON_WARNING}${NC} LaunchServices stale registrations · deferred to next clean"
            note_activity
            return 0
        fi
    else
        # No prefetch ran (standalone invocation): keep the bounded inline
        # scan so this function stays usable on its own. Default timeout is
        # 60s (2x DISK_VERIFY), not the old 10s PKG_LIST bound.
        local ls_scan_rc=0
        collect_stale_launch_services_app_paths "$lsregister" > "$candidates_file" || ls_scan_rc=$?
        if [[ $ls_scan_rc -ne 0 ]]; then
            stop_section_spinner
            debug_log "LaunchServices stale app scan failed (rc=$ls_scan_rc after $((SECONDS - ls_scan_started_at))s)"
            echo -e "  ${GRAY}${ICON_WARNING}${NC} LaunchServices stale registrations · scan skipped (disk cleanup unaffected)"
            note_activity
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
