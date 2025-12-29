#!/bin/bash
# Application Data Cleanup Module
set -euo pipefail
# Args: $1=target_dir, $2=label
# Clean .DS_Store (Finder metadata), home uses maxdepth 5, excludes slow paths, max 500 files
clean_ds_store_tree() {
    local target="$1"
    local label="$2"
    [[ -d "$target" ]] || return 0
    local file_count=0
    local total_bytes=0
    local spinner_active="false"
    if [[ -t 1 ]]; then
        MOLE_SPINNER_PREFIX="  "
        start_inline_spinner "Cleaning Finder metadata..."
        spinner_active="true"
    fi
    # Build exclusion paths for find (skip common slow/large directories)
    local -a exclude_paths=(
        -path "*/Library/Application Support/MobileSync" -prune -o
        -path "*/Library/Developer" -prune -o
        -path "*/.Trash" -prune -o
        -path "*/node_modules" -prune -o
        -path "*/.git" -prune -o
        -path "*/Library/Caches" -prune -o
    )
    # Build find command to avoid unbound array expansion with set -u
    local -a find_cmd=("command" "find" "$target")
    if [[ "$target" == "$HOME" ]]; then
        find_cmd+=("-maxdepth" "5")
    fi
    find_cmd+=("${exclude_paths[@]}" "-type" "f" "-name" ".DS_Store" "-print0")
    # Find .DS_Store files with exclusions and depth limit
    while IFS= read -r -d '' ds_file; do
        local size
        size=$(get_file_size "$ds_file")
        total_bytes=$((total_bytes + size))
        ((file_count++))
        if [[ "$DRY_RUN" != "true" ]]; then
            rm -f "$ds_file" 2> /dev/null || true
        fi
        if [[ $file_count -ge $MOLE_MAX_DS_STORE_FILES ]]; then
            break
        fi
    done < <("${find_cmd[@]}" 2> /dev/null || true)
    if [[ "$spinner_active" == "true" ]]; then
        stop_section_spinner
    fi
    if [[ $file_count -gt 0 ]]; then
        local size_human
        size_human=$(bytes_to_human "$total_bytes")
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} $label ${YELLOW}($file_count files, $size_human dry)${NC}"
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $label ${GREEN}($file_count files, $size_human)${NC}"
        fi
        local size_kb=$(((total_bytes + 1023) / 1024))
        ((files_cleaned += file_count))
        ((total_size_cleaned += size_kb))
        ((total_items++))
        note_activity
    fi
}
# Clean data for uninstalled apps (caches/logs/states older than 60 days)
# Protects system apps, major vendors, scans /Applications+running processes
# Max 100 items/pattern, 2s du timeout. Env: ORPHAN_AGE_THRESHOLD, DRY_RUN
# Usage: scan_installed_apps "output_file"
# Scan system for installed application bundle IDs
scan_installed_apps() {
    local installed_bundles="$1"
    # Performance optimization: cache results for 5 minutes
    local cache_file="$HOME/.cache/mole/installed_apps_cache"
    local cache_age_seconds=300 # 5 minutes
    if [[ -f "$cache_file" ]]; then
        local cache_mtime=$(get_file_mtime "$cache_file")
        local current_time=$(date +%s)
        local age=$((current_time - cache_mtime))
        if [[ $age -lt $cache_age_seconds ]]; then
            debug_log "Using cached app list (age: ${age}s)"
            # Verify cache file is readable and not empty
            if [[ -r "$cache_file" ]] && [[ -s "$cache_file" ]]; then
                if cat "$cache_file" > "$installed_bundles" 2> /dev/null; then
                    return 0
                else
                    debug_log "Warning: Failed to read cache, rebuilding"
                fi
            else
                debug_log "Warning: Cache file empty or unreadable, rebuilding"
            fi
        fi
    fi
    debug_log "Scanning installed applications (cache expired or missing)"
    # Scan all Applications directories
    local -a app_dirs=(
        "/Applications"
        "/System/Applications"
        "$HOME/Applications"
    )
    # Create a temp dir for parallel results to avoid write contention
    local scan_tmp_dir=$(create_temp_dir)
    # Parallel scan for applications
    local pids=()
    local dir_idx=0
    for app_dir in "${app_dirs[@]}"; do
        [[ -d "$app_dir" ]] || continue
        (
            # Quickly find all .app bundles first
            local -a app_paths=()
            while IFS= read -r app_path; do
                [[ -n "$app_path" ]] && app_paths+=("$app_path")
            done < <(find "$app_dir" -name '*.app' -maxdepth 3 -type d 2> /dev/null)
            # Read bundle IDs with PlistBuddy
            local count=0
            for app_path in "${app_paths[@]:-}"; do
                local plist_path="$app_path/Contents/Info.plist"
                [[ ! -f "$plist_path" ]] && continue
                local bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist_path" 2> /dev/null || echo "")
                if [[ -n "$bundle_id" ]]; then
                    echo "$bundle_id"
                    ((count++))
                fi
            done
        ) > "$scan_tmp_dir/apps_${dir_idx}.txt" &
        pids+=($!)
        ((dir_idx++))
    done
    # Get running applications and LaunchAgents in parallel
    (
        local running_apps=$(run_with_timeout 5 osascript -e 'tell application "System Events" to get bundle identifier of every application process' 2> /dev/null || echo "")
        echo "$running_apps" | tr ',' '\n' | sed -e 's/^ *//;s/ *$//' -e '/^$/d' > "$scan_tmp_dir/running.txt"
    ) &
    pids+=($!)
    (
        run_with_timeout 5 find ~/Library/LaunchAgents /Library/LaunchAgents \
            -name "*.plist" -type f 2> /dev/null |
            xargs -I {} basename {} .plist > "$scan_tmp_dir/agents.txt" 2> /dev/null || true
    ) &
    pids+=($!)
    # Wait for all background scans to complete
    debug_log "Waiting for ${#pids[@]} background processes: ${pids[*]}"
    for pid in "${pids[@]}"; do
        wait "$pid" 2> /dev/null || true
    done
    debug_log "All background processes completed"
    cat "$scan_tmp_dir"/*.txt >> "$installed_bundles" 2> /dev/null || true
    safe_remove "$scan_tmp_dir" true
    sort -u "$installed_bundles" -o "$installed_bundles"
    # Cache the results
    ensure_user_dir "$(dirname "$cache_file")"
    cp "$installed_bundles" "$cache_file" 2> /dev/null || true
    local app_count=$(wc -l < "$installed_bundles" 2> /dev/null | tr -d ' ')
    debug_log "Scanned $app_count unique applications"
}
# Usage: is_bundle_orphaned "bundle_id" "directory_path" "installed_bundles_file"
# Check if bundle is orphaned
is_bundle_orphaned() {
    local bundle_id="$1"
    local directory_path="$2"
    local installed_bundles="$3"
    # Skip system-critical and protected apps
    if should_protect_data "$bundle_id"; then
        return 1
    fi
    # Check if app exists in our scan
    if grep -Fxq "$bundle_id" "$installed_bundles" 2> /dev/null; then
        return 1
    fi
    # Check against centralized protected patterns (app_protection.sh)
    if should_protect_data "$bundle_id"; then
        return 1
    fi
    # Extra check for specific system bundles not covered by patterns
    case "$bundle_id" in
        loginwindow | dock | systempreferences | systemsettings | settings | controlcenter | finder | safari)
            return 1
            ;;
    esac
    # Check file age - only clean if 60+ days inactive
    if [[ -e "$directory_path" ]]; then
        local last_modified_epoch=$(get_file_mtime "$directory_path")
        local current_epoch=$(date +%s)
        local days_since_modified=$(((current_epoch - last_modified_epoch) / 86400))
        if [[ $days_since_modified -lt ${ORPHAN_AGE_THRESHOLD:-60} ]]; then
            return 1
        fi
    fi
    return 0
}
# Clean data for uninstalled apps (caches/logs/states older than 60 days)
# Max 100 items/pattern, 2s du timeout. Env: ORPHAN_AGE_THRESHOLD, DRY_RUN
# Protects system apps, major vendors, scans /Applications+running processes
clean_orphaned_app_data() {
    # Quick permission check - if we can't access Library folders, skip
    if ! ls "$HOME/Library/Caches" > /dev/null 2>&1; then
        stop_section_spinner
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Skipped: No permission to access Library folders"
        return 0
    fi
    # Build list of installed/active apps
    start_section_spinner "Scanning installed apps..."
    local installed_bundles=$(create_temp_file)
    scan_installed_apps "$installed_bundles"
    stop_section_spinner
    # Display scan results
    local app_count=$(wc -l < "$installed_bundles" 2> /dev/null | tr -d ' ')
    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Found $app_count active/installed apps"
    # Track statistics
    local orphaned_count=0
    local total_orphaned_kb=0
    # Unified orphaned resource scanner (caches, logs, states, webkit, HTTP, cookies)
    start_section_spinner "Scanning orphaned app resources..."
    # Define resource types to scan
    # CRITICAL: NEVER add LaunchAgents or LaunchDaemons (breaks login items/startup apps)
    local -a resource_types=(
        "$HOME/Library/Caches|Caches|com.*:org.*:net.*:io.*"
        "$HOME/Library/Logs|Logs|com.*:org.*:net.*:io.*"
        "$HOME/Library/Saved Application State|States|*.savedState"
        "$HOME/Library/WebKit|WebKit|com.*:org.*:net.*:io.*"
        "$HOME/Library/HTTPStorages|HTTP|com.*:org.*:net.*:io.*"
        "$HOME/Library/Cookies|Cookies|*.binarycookies"
    )
    orphaned_count=0
    for resource_type in "${resource_types[@]}"; do
        IFS='|' read -r base_path label patterns <<< "$resource_type"
        # Check both existence and permission to avoid hanging
        if [[ ! -d "$base_path" ]]; then
            continue
        fi
        # Quick permission check - if we can't ls the directory, skip it
        if ! ls "$base_path" > /dev/null 2>&1; then
            continue
        fi
        # Build file pattern array
        local -a file_patterns=()
        IFS=':' read -ra pattern_arr <<< "$patterns"
        for pat in "${pattern_arr[@]}"; do
            file_patterns+=("$base_path/$pat")
        done
        # Scan and clean orphaned items
        for item_path in "${file_patterns[@]}"; do
            # Use shell glob (no ls needed)
            # Limit iterations to prevent hanging on directories with too many files
            local iteration_count=0
            for match in $item_path; do
                [[ -e "$match" ]] || continue
                # Safety: limit iterations to prevent infinite loops on massive directories
                ((iteration_count++))
                if [[ $iteration_count -gt $MOLE_MAX_ORPHAN_ITERATIONS ]]; then
                    break
                fi
                # Extract bundle ID from filename
                local bundle_id=$(basename "$match")
                bundle_id="${bundle_id%.savedState}"
                bundle_id="${bundle_id%.binarycookies}"
                if is_bundle_orphaned "$bundle_id" "$match" "$installed_bundles"; then
                    # Use timeout to prevent du from hanging on network mounts or problematic paths
                    local size_kb
                    size_kb=$(get_path_size_kb "$match")
                    if [[ -z "$size_kb" || "$size_kb" == "0" ]]; then
                        continue
                    fi
                    safe_clean "$match" "Orphaned $label: $bundle_id"
                    ((orphaned_count++))
                    ((total_orphaned_kb += size_kb))
                fi
            done
        done
    done
    stop_section_spinner
    if [[ $orphaned_count -gt 0 ]]; then
        local orphaned_mb=$(echo "$total_orphaned_kb" | awk '{printf "%.1f", $1/1024}')
        echo "  ${GREEN}${ICON_SUCCESS}${NC} Cleaned $orphaned_count items (~${orphaned_mb}MB)"
        note_activity
    fi
    rm -f "$installed_bundles"
}
