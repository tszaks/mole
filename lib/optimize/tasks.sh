#!/bin/bash
# Optimization Tasks

set -euo pipefail

# Configuration constants
# MOLE_TM_THIN_TIMEOUT: Max seconds to wait for tmutil thinning (default: 180)
# MOLE_TM_THIN_VALUE: Bytes to thin for local snapshots (default: 9999999999)
# MOLE_MAIL_DOWNLOADS_MIN_KB: Minimum size in KB before cleaning Mail attachments (default: 5120)
# MOLE_MAIL_AGE_DAYS: Minimum age in days for Mail attachments to be cleaned (default: 30)
readonly MOLE_TM_THIN_TIMEOUT=180
readonly MOLE_TM_THIN_VALUE=9999999999

flush_dns_cache() {
    if sudo dscacheutil -flushcache 2> /dev/null && sudo killall -HUP mDNSResponder 2> /dev/null; then
        MOLE_DNS_FLUSHED=1
        return 0
    fi
    return 1
}

# Rebuild databases and flush caches
opt_system_maintenance() {
    local -a results=()
    local darwin_major
    darwin_major=$(get_darwin_major)

    if flush_dns_cache; then
        results+=("${GREEN}✓${NC} DNS cache flushed")
    fi

    local spotlight_status
    spotlight_status=$(mdutil -s / 2> /dev/null || echo "")
    if echo "$spotlight_status" | grep -qi "Indexing disabled"; then
        results+=("${GRAY}${ICON_EMPTY}${NC} Spotlight indexing disabled")
    else
        results+=("${GREEN}✓${NC} Spotlight index verified")
    fi

    for result in "${results[@]}"; do
        echo -e "  $result"
    done
}

# Refresh Finder caches (QuickLook and icon services)
# Note: Safari caches are cleaned separately in clean/user.sh, so excluded here
opt_cache_refresh() {
    qlmanage -r cache > /dev/null 2>&1 || true
    qlmanage -r > /dev/null 2>&1 || true

    local refreshed=0
    local -a cache_targets=(
        "$HOME/Library/Caches/com.apple.QuickLook.thumbnailcache"
        "$HOME/Library/Caches/com.apple.iconservices.store"
        "$HOME/Library/Caches/com.apple.iconservices"
    )

    for target_path in "${cache_targets[@]}"; do
        if [[ -e "$target_path" ]]; then
            if ! should_protect_path "$target_path"; then
                if safe_remove "$target_path" true; then
                    ((refreshed++))
                fi
            fi
        fi
    done

    echo -e "  ${GREEN}✓${NC} QuickLook thumbnails refreshed"
    echo -e "  ${GREEN}✓${NC} Icon services cache rebuilt"
}

# Removed: opt_maintenance_scripts - macOS handles log rotation automatically via launchd

# Removed: opt_radio_refresh - Interrupts active user connections (WiFi, Bluetooth), degrading UX

# Saved state: remove OLD app saved states (7+ days)
opt_saved_state_cleanup() {
    local state_dir="$HOME/Library/Saved Application State"

    if [[ -d "$state_dir" ]]; then
        while IFS= read -r -d '' state_path; do
            if should_protect_path "$state_path"; then
                continue
            fi
            safe_remove "$state_path" true > /dev/null 2>&1
        done < <(command find "$state_dir" -type d -name "*.savedState" -mtime "+$MOLE_SAVED_STATE_AGE_DAYS" -print0 2> /dev/null)
    fi

    echo -e "  ${GREEN}✓${NC} App saved states optimized"
}

# Removed: opt_swap_cleanup - Direct virtual memory operations pose system crash risk

# Removed: opt_startup_cache - Modern macOS has no such mechanism

# Removed: opt_local_snapshots - Deletes user Time Machine recovery points, breaks backup continuity

opt_fix_broken_configs() {
    local broken_prefs=$(fix_broken_preferences)

    if [[ $broken_prefs -gt 0 ]]; then
        echo -e "  ${GREEN}✓${NC} Repaired $broken_prefs corrupted preference files"
    else
        echo -e "  ${GREEN}✓${NC} All preference files valid"
    fi
}

# Network cache optimization
opt_network_optimization() {
    if [[ "${MOLE_DNS_FLUSHED:-0}" == "1" ]]; then
        echo -e "  ${GREEN}✓${NC} DNS cache already refreshed"
        echo -e "  ${GREEN}✓${NC} mDNSResponder already restarted"
        return 0
    fi

    if flush_dns_cache; then
        echo -e "  ${GREEN}✓${NC} DNS cache refreshed"
        echo -e "  ${GREEN}✓${NC} mDNSResponder restarted"
    else
        echo -e "  ${YELLOW}!${NC} Failed to refresh DNS cache"
    fi
}

# SQLite database vacuum optimization
# Compresses and optimizes SQLite databases for Mail, Messages, Safari
opt_sqlite_vacuum() {
    if ! command -v sqlite3 > /dev/null 2>&1; then
        echo -e "  ${GRAY}-${NC} sqlite3 not available, skipping database optimization"
        return 0
    fi

    local -a busy_apps=()
    local -a check_apps=("Mail" "Safari" "Messages")
    local app
    for app in "${check_apps[@]}"; do
        if pgrep -x "$app" > /dev/null 2>&1; then
            busy_apps+=("$app")
        fi
    done

    if [[ ${#busy_apps[@]} -gt 0 ]]; then
        echo -e "  ${YELLOW}!${NC} Close these apps before database optimization: ${busy_apps[*]}"
        return 0
    fi

    local -a db_paths=(
        "$HOME/Library/Mail/V*/MailData/Envelope Index*"
        "$HOME/Library/Messages/chat.db"
        "$HOME/Library/Safari/History.db"
        "$HOME/Library/Safari/TopSites.db"
    )

    local vacuumed=0
    local timed_out=0
    local failed=0

    for pattern in "${db_paths[@]}"; do
        while IFS= read -r db_file; do
            [[ ! -f "$db_file" ]] && continue
            [[ "$db_file" == *"-wal" || "$db_file" == *"-shm" ]] && continue

            # Skip if protected
            should_protect_path "$db_file" && continue

            # Verify it's a SQLite database
            if ! file "$db_file" 2>/dev/null | grep -q "SQLite"; then
                continue
            fi

            # Try to vacuum
            local exit_code=0
            set +e
            run_with_timeout 20 sqlite3 "$db_file" "VACUUM;" 2>/dev/null
            exit_code=$?
            set -e

            if [[ $exit_code -eq 0 ]]; then
                ((vacuumed++))
            elif [[ $exit_code -eq 124 ]]; then
                ((timed_out++))
            else
                ((failed++))
            fi
        done < <(compgen -G "$pattern" || true)
    done

    if [[ $vacuumed -gt 0 ]]; then
        echo -e "  ${GREEN}✓${NC} Optimized $vacuumed databases for Mail, Safari, Messages"
    elif [[ $timed_out -eq 0 && $failed -eq 0 ]]; then
        echo -e "  ${GREEN}✓${NC} All databases already optimized"
    else
        echo -e "  ${YELLOW}!${NC} Database optimization incomplete"
    fi

    if [[ $timed_out -gt 0 ]]; then
        echo -e "  ${YELLOW}!${NC} Timed out on $timed_out databases"
    fi

    if [[ $failed -gt 0 ]]; then
        echo -e "  ${YELLOW}!${NC} Failed on $failed databases"
    fi
}

# LaunchServices database rebuild
# Fixes "Open with" menu issues, duplicate apps, broken file associations
opt_launch_services_rebuild() {
    if [[ -t 1 ]]; then
        start_inline_spinner ""
    fi

    local lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    if [[ -f "$lsregister" ]]; then
        local success=0
        set +e
        "$lsregister" -r -domain local -domain user -domain system > /dev/null 2>&1
        success=$?
        if [[ $success -ne 0 ]]; then
            "$lsregister" -r -domain local -domain user > /dev/null 2>&1
            success=$?
        fi
        set -e

        if [[ -t 1 ]]; then
            stop_inline_spinner
        fi

        if [[ $success -eq 0 ]]; then
            echo -e "  ${GREEN}✓${NC} LaunchServices repaired"
            echo -e "  ${GREEN}✓${NC} File associations refreshed"
        else
            echo -e "  ${YELLOW}!${NC} Failed to rebuild LaunchServices"
        fi
    else
        if [[ -t 1 ]]; then
            stop_inline_spinner
        fi
        echo -e "  ${YELLOW}!${NC} lsregister not found"
    fi
}

# Font cache rebuild
# Fixes font rendering issues, missing fonts, and character display problems
opt_font_cache_rebuild() {
    local success=false

    if sudo atsutil databases -remove > /dev/null 2>&1; then
        success=true
    fi

    if [[ "$success" == "true" ]]; then
        echo -e "  ${GREEN}✓${NC} Font cache cleared"
        echo -e "  ${GREEN}✓${NC} System will rebuild font database automatically"
    else
        echo -e "  ${YELLOW}!${NC} Failed to clear font cache"
    fi
}

# Startup items cleanup
# Removes broken LaunchAgents and analyzes startup performance impact
opt_startup_items_cleanup() {
    # Check whitelist (respects 'Login items check' setting)
    if command -v is_whitelisted > /dev/null && is_whitelisted "check_login_items"; then
        return 0
    fi

    local -a scan_dirs=(
        "$HOME/Library/LaunchAgents"
        "$HOME/Library/LaunchDaemons"
        "/Library/LaunchAgents"
        "/Library/LaunchDaemons"
    )

    local broken_count=0
    local total_count=0
    local processed_files=0

    for dir in "${scan_dirs[@]}"; do
        [[ ! -d "$dir" ]] && continue

        # Check if we need sudo for this directory
        local need_sudo=false
        if [[ "$dir" == "/Library"* ]]; then
            need_sudo=true
        fi

        # Process plists
        local find_cmd=(find)
        if [[ "$need_sudo" == "true" ]]; then
            find_cmd=(sudo find)
        fi

        while IFS= read -r plist_file; do
            # Verify file exists (unless in test mode)
            if [[ -z "${MO_TEST_MODE:-}" && ! -f "$plist_file" ]]; then
                continue
            fi
            ((total_count++))

            # Skip system items (com.apple.*)
            local filename=$(basename "$plist_file")
            [[ "$filename" == com.apple.* ]] && continue

            # Check if plist is valid (use sudo for system dirs)
            local lint_output=""
            local lint_status=0
            local errexit_was_set=0
            [[ $- == *e* ]] && errexit_was_set=1
            set +e
            if [[ "$need_sudo" == "true" ]]; then
                lint_output=$(sudo plutil -lint "$plist_file" 2>&1)
                lint_status=$?
            else
                lint_output=$(plutil -lint "$plist_file" 2>&1)
                lint_status=$?
            fi
            if [[ $errexit_was_set -eq 1 ]]; then
                set -e
            fi

            if [[ $lint_status -ne 0 ]]; then
                # Skip if lint failed due to permissions or transient read errors
                if echo "$lint_output" | grep -qi "permission\\|operation not permitted\\|not permitted"; then
                    continue
                fi

                # Invalid plist - remove it
                if command -v should_protect_path > /dev/null && should_protect_path "$plist_file"; then
                    continue
                fi

                if [[ "$need_sudo" == "true" ]]; then
                    sudo launchctl unload "$plist_file" 2>/dev/null || true
                    if safe_sudo_remove "$plist_file"; then
                        ((broken_count++))
                    else
                        echo -e "  ${YELLOW}!${NC} Failed to remove (sudo) $plist_file"
                    fi
                else
                    launchctl unload "$plist_file" 2>/dev/null || true
                    if safe_remove "$plist_file" true; then
                        ((broken_count++))
                    else
                        echo -e "  ${YELLOW}!${NC} Failed to remove $plist_file"
                    fi
                fi
                continue
            fi

            # Extract program path
            local program=""
            program=$(plutil -extract Program raw "$plist_file" 2>/dev/null || echo "")

            if [[ -z "$program" ]]; then
                program=$(plutil -extract ProgramArguments.0 raw "$plist_file" 2>/dev/null || echo "")
            fi

            program="${program/#\~/$HOME}"

            # Skip paths with variables or non-absolute program definitions
            if [[ "$program" == *'$'* || "$program" != /* ]]; then
                continue
            fi
            # Check for orphaned privileged helpers (app uninstalled but helper remains)
            local associated_bundle=""
            associated_bundle=$(plutil -extract AssociatedBundleIdentifiers.0 raw "$plist_file" 2>/dev/null || echo "")

            if [[ -n "$associated_bundle" ]]; then
                # Check if the associated app exists
                local app_path=""
                # First check standard locations
                if [[ -d "/Applications/$associated_bundle.app" ]]; then
                    app_path="/Applications/$associated_bundle.app"
                elif [[ -d "$HOME/Applications/$associated_bundle.app" ]]; then
                    app_path="$HOME/Applications/$associated_bundle.app"
                else
                    # Fallback to mdfind (slower but comprehensive, with 10s timeout)
                    app_path=$(run_with_timeout 10 mdfind "kMDItemCFBundleIdentifier == '$associated_bundle'" 2>/dev/null | head -1 || echo "")
                fi

                # If associated app is MISSING, this is an orphan
                if [[ -z "$app_path" ]]; then
                     if command -v should_protect_path > /dev/null && should_protect_path "$plist_file"; then
                        continue
                    fi

                    # Get the helper tool path
                    local program=""
                    program=$(plutil -extract Program raw "$plist_file" 2>/dev/null || echo "")
                    if [[ -z "$program" ]]; then
                         program=$(plutil -extract ProgramArguments.0 raw "$plist_file" 2>/dev/null || echo "")
                    fi
                    program="${program/#\~/$HOME}"

                    # Double check we are not deleting system files
                    if [[ "$program" == /System/* ||
                          "$program" == /usr/lib/* ||
                          "$program" == /usr/bin/* ||
                          "$program" == /usr/sbin/* ||
                          "$program" == /Library/Apple/* ]]; then
                        continue
                    fi

                    if [[ "$need_sudo" == "true" ]]; then
                        sudo launchctl unload "$plist_file" 2>/dev/null || true
                        # remove the plist
                        safe_sudo_remove "$plist_file"

                        # AND remove the helper binary if it exists and is not protected
                        if [[ -n "$program" && -f "$program" ]]; then
                             safe_sudo_remove "$program"
                        fi
                        ((broken_count++))
                        echo -e "  ${GREEN}✓${NC} Removed orphaned helper: $(basename "$program")"
                    else
                         launchctl unload "$plist_file" 2>/dev/null || true
                         safe_remove "$plist_file" true
                         if [[ -n "$program" && -f "$program" ]]; then
                             safe_remove "$program" true
                         fi
                         ((broken_count++))
                         echo -e "  ${GREEN}✓${NC} Removed orphaned helper: $(basename "$program")"
                    fi
                    continue
                fi
            fi

            # If program doesn't exist, remove the launch agent/daemon
            if [[ -n "$program" && ! -e "$program" ]]; then
                if command -v should_protect_path > /dev/null && should_protect_path "$plist_file"; then
                    continue
                fi

                if [[ "$need_sudo" == "true" ]]; then
                    sudo launchctl unload "$plist_file" 2>/dev/null || true
                    if safe_sudo_remove "$plist_file"; then
                        ((broken_count++))
                    else
                        echo -e "  ${YELLOW}!${NC} Failed to remove (sudo) $plist_file"
                    fi
                else
                    launchctl unload "$plist_file" 2>/dev/null || true
                    if safe_remove "$plist_file" true; then
                        ((broken_count++))
                    else
                        echo -e "  ${YELLOW}!${NC} Failed to remove $plist_file"
                    fi
                fi
            fi
        done < <("${find_cmd[@]}" "$dir" -maxdepth 1 -name "*.plist" -type f 2>/dev/null || true)
    done

    if [[ $broken_count -gt 0 ]]; then
        echo -e "  ${GREEN}✓${NC} Removed $broken_count broken startup items"
    fi

    if [[ $total_count -gt 0 ]]; then
        echo -e "  ${GREEN}✓${NC} Verified $total_count startup items"
    else
        echo -e "  ${GREEN}✓${NC} No startup items found"
    fi
}

# dyld shared cache update
# Rebuilds dynamic linker shared cache to improve app launch speed
# Only beneficial after new app installations or system updates
opt_dyld_cache_update() {
    # Check if command exists
    if ! command -v update_dyld_shared_cache > /dev/null 2>&1; then
        echo -e "  ${GRAY}-${NC} dyld cache (automatically managed by macOS)"
        return 0
    fi

    # Skip if dyld cache was already rebuilt recently (within 24 hours)
    local dyld_cache_path="/var/db/dyld/dyld_shared_cache_$(uname -m)"
    if [[ -e "$dyld_cache_path" ]]; then
        local cache_mtime
        cache_mtime=$(stat -f "%m" "$dyld_cache_path" 2>/dev/null || echo "0")
        local current_time
        current_time=$(date +%s)
        local time_diff=$((current_time - cache_mtime))
        local one_day_seconds=$((24 * 3600))

        if [[ $time_diff -lt $one_day_seconds ]]; then
            echo -e "  ${GREEN}✓${NC} dyld shared cache already up-to-date"
            return 0
        fi
    fi

    if [[ -t 1 ]]; then
        start_inline_spinner "Rebuilding dyld cache..."
    fi

    local success=false
    local exit_code=0
    # This can take 1-2 minutes on some systems (180 second timeout)
    set +e
    run_with_timeout 180 sudo update_dyld_shared_cache -force > /dev/null 2>&1
    exit_code=$?
    set -e
    if [[ $exit_code -eq 0 ]]; then
        success=true
    fi

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    if [[ "$success" == "true" ]]; then
        echo -e "  ${GREEN}✓${NC} dyld shared cache rebuilt"
        echo -e "  ${GREEN}✓${NC} App launch speed improved"
    elif [[ $exit_code -eq 124 ]]; then
        echo -e "  ${YELLOW}!${NC} dyld cache update timed out"
    else
        echo -e "  ${GRAY}-${NC} dyld cache update skipped (automatically managed)"
    fi
}

# System services refresh
# Restarts system services to apply cache and configuration changes
opt_system_services_refresh() {
    local -a restarted_services=()

    # cfprefsd - Preferences cache daemon (ensures fixed preferences take effect)
    if killall -HUP cfprefsd 2>/dev/null; then
        restarted_services+=("Preferences")
    fi

    # lsd - LaunchServices daemon (ensures rebuild takes effect)
    if killall lsd 2>/dev/null; then
        restarted_services+=("LaunchServices")
    fi

    # iconservicesagent - Icon services (ensures cache refresh takes effect)
    if killall iconservicesagent 2>/dev/null; then
        restarted_services+=("Icon Services")
    fi

    # fontd - Font server (ensures font cache refresh takes effect)
    if killall fontd 2>/dev/null; then
        restarted_services+=("Font Server")
    fi

    if [[ ${#restarted_services[@]} -gt 0 ]]; then
        echo -e "  ${GREEN}✓${NC} Refreshed ${#restarted_services[@]} system services"
        for service in "${restarted_services[@]}"; do
            echo -e "    • $service"
        done
    else
        echo -e "  ${GREEN}✓${NC} System services already optimal"
    fi
}

# Dock cache refresh
# Fixes broken icons, duplicate items, and visual glitches in the Dock
opt_dock_refresh() {
    local dock_support="$HOME/Library/Application Support/Dock"
    local refreshed=false

    # Remove Dock database files (icons, positions, etc.)
    if [[ -d "$dock_support" ]]; then
        while IFS= read -r db_file; do
            if [[ -f "$db_file" ]]; then
                safe_remove "$db_file" true > /dev/null 2>&1 && refreshed=true
            fi
        done < <(find "$dock_support" -name "*.db" -type f 2>/dev/null || true)
    fi

    # Also clear Dock plist cache
    local dock_plist="$HOME/Library/Preferences/com.apple.dock.plist"
    if [[ -f "$dock_plist" ]]; then
        # Just touch to invalidate cache, don't delete (preserves user settings)
        touch "$dock_plist" 2>/dev/null || true
    fi

    # Restart Dock to apply changes
    killall Dock 2>/dev/null || true

    if [[ "$refreshed" == "true" ]]; then
        echo -e "  ${GREEN}✓${NC} Dock cache cleared"
    fi
    echo -e "  ${GREEN}✓${NC} Dock refreshed"
}


# Execute optimization by action name
execute_optimization() {
    local action="$1"
    local path="${2:-}"

    case "$action" in
        system_maintenance) opt_system_maintenance ;;
        cache_refresh) opt_cache_refresh ;;
        saved_state_cleanup) opt_saved_state_cleanup ;;
        fix_broken_configs) opt_fix_broken_configs ;;
        network_optimization) opt_network_optimization ;;
        sqlite_vacuum) opt_sqlite_vacuum ;;
        launch_services_rebuild) opt_launch_services_rebuild ;;
        font_cache_rebuild) opt_font_cache_rebuild ;;
        startup_items_cleanup) opt_startup_items_cleanup ;;
        dyld_cache_update) opt_dyld_cache_update ;;
        system_services_refresh) opt_system_services_refresh ;;
        dock_refresh) opt_dock_refresh ;;
        *)
            echo -e "${YELLOW}${ICON_ERROR}${NC} Unknown action: $action"
            return 1
            ;;
    esac
}
