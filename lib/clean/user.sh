#!/bin/bash
# User Data Cleanup Module

set -euo pipefail

# Clean user essentials (caches, logs, trash)
clean_user_essentials() {
    safe_clean ~/Library/Caches/* "User app cache"
    safe_clean ~/Library/Logs/* "User app logs"
    safe_clean ~/.Trash/* "Trash"
}

# Helper: Scan external volumes for cleanup (Trash & DS_Store)
scan_external_volumes() {
    [[ -d "/Volumes" ]] || return 0

    # Fast pre-check: count non-system external volumes without expensive operations
    local -a candidate_volumes=()
    for volume in /Volumes/*; do
        # Basic checks (directory, writable, not a symlink)
        [[ -d "$volume" && -w "$volume" && ! -L "$volume" ]] || continue

        # Skip system root if it appears in /Volumes
        [[ "$volume" == "/" || "$volume" == "/Volumes/Macintosh HD" ]] && continue

        candidate_volumes+=("$volume")
    done

    # If no external volumes found, return immediately (zero overhead)
    local volume_count=${#candidate_volumes[@]}
    [[ $volume_count -eq 0 ]] && return 0

    # We have external volumes, now perform full scan
    if [[ -t 1 ]]; then
        MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning $volume_count external volume(s)..."
    fi

    for volume in "${candidate_volumes[@]}"; do
        # Skip network volumes with short timeout (reduced from 2s to 1s)
        local fs_type=""
        fs_type=$(run_with_timeout 1 command df -T "$volume" 2> /dev/null | tail -1 | awk '{print $2}' || echo "unknown")
        case "$fs_type" in
            nfs | smbfs | afpfs | cifs | webdav | unknown) continue ;;
        esac

        # Verify volume is actually mounted (reduced timeout from 2s to 1s)
        run_with_timeout 1 mount | grep -q "on $volume " || continue

        # 1. Clean Trash on volume
        if [[ -d "$volume/.Trashes" && "$DRY_RUN" != "true" ]]; then
            # Safely iterate and remove each item
            while IFS= read -r -d '' item; do
                safe_remove "$item" true || true
            done < <(command find "$volume/.Trashes" -mindepth 1 -maxdepth 1 -print0 2> /dev/null || true)
        fi

        # 2. Clean .DS_Store
        if [[ "$PROTECT_FINDER_METADATA" != "true" ]]; then
            clean_ds_store_tree "$volume" "$(basename "$volume") volume (.DS_Store)"
        fi
    done

    if [[ -t 1 ]]; then stop_inline_spinner; fi
}

# Clean Finder metadata (.DS_Store files)
clean_finder_metadata() {
    if [[ "$PROTECT_FINDER_METADATA" == "true" ]]; then
        note_activity
        echo -e "  ${GRAY}⊘${NC} Finder metadata (protected)"
        return
    fi

    clean_ds_store_tree "$HOME" "Home directory (.DS_Store)"
}

# Clean macOS system caches
clean_macos_system_caches() {
    # Clean saved application states with protection for System Settings
    # Note: safe_clean already calls should_protect_path for each file
    safe_clean ~/Library/Saved\ Application\ State/* "Saved application states"

    # REMOVED: Spotlight cache cleanup can cause system UI issues
    # Spotlight indexes should be managed by macOS automatically
    # safe_clean ~/Library/Caches/com.apple.spotlight "Spotlight cache"

    safe_clean ~/Library/Caches/com.apple.photoanalysisd "Photo analysis cache"
    safe_clean ~/Library/Caches/com.apple.akd "Apple ID cache"
    safe_clean ~/Library/Caches/com.apple.WebKit.Networking/* "WebKit network cache"

    # Extra user items
    safe_clean ~/Library/DiagnosticReports/* "Diagnostic reports"
    safe_clean ~/Library/Caches/com.apple.QuickLook.thumbnailcache "QuickLook thumbnails"
    safe_clean ~/Library/Caches/Quick\ Look/* "QuickLook cache"
    safe_clean ~/Library/Caches/com.apple.iconservices* "Icon services cache"
    safe_clean ~/Library/Caches/CloudKit/* "CloudKit cache"

    # Clean incomplete downloads
    safe_clean ~/Downloads/*.download "Incomplete downloads (Safari)"
    safe_clean ~/Downloads/*.crdownload "Incomplete downloads (Chrome)"
    safe_clean ~/Downloads/*.part "Incomplete downloads (partial)"

    # Additional user-level caches
    safe_clean ~/Library/Autosave\ Information/* "Autosave information"
    safe_clean ~/Library/IdentityCaches/* "Identity caches"
    safe_clean ~/Library/Suggestions/* "Suggestions cache (Siri)"
    safe_clean ~/Library/Calendars/Calendar\ Cache "Calendar cache"
    safe_clean ~/Library/Application\ Support/AddressBook/Sources/*/Photos.cache "Address Book photo cache"
}

# Clean sandboxed app caches
clean_sandboxed_app_caches() {
    safe_clean ~/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/* "Wallpaper agent cache"
    safe_clean ~/Library/Containers/com.apple.mediaanalysisd/Data/Library/Caches/* "Media analysis cache"
    safe_clean ~/Library/Containers/com.apple.AppStore/Data/Library/Caches/* "App Store cache"
    safe_clean ~/Library/Containers/com.apple.configurator.xpc.InternetService/Data/tmp/* "Apple Configurator temp files"

    # Clean sandboxed app caches - iterate quietly to avoid UI flashing
    local containers_dir="$HOME/Library/Containers"
    [[ ! -d "$containers_dir" ]] && return 0

    if [[ -t 1 ]]; then
        MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning sandboxed apps..."
    fi

    local total_size=0
    local cleaned_count=0
    local found_any=false

    for container_dir in "$containers_dir"/*; do
        process_container_cache "$container_dir"
    done

    if [[ -t 1 ]]; then stop_inline_spinner; fi

    if [[ "$found_any" == "true" ]]; then
        local size_human=$(bytes_to_human "$((total_size * 1024))")
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}→${NC} Sandboxed app caches ${YELLOW}($size_human dry)${NC}"
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Sandboxed app caches ${GREEN}($size_human)${NC}"
        fi
        # Update global counters
        ((files_cleaned += cleaned_count))
        ((total_size_cleaned += total_size))
        ((total_items++))
        note_activity
    fi
}

# Process a single container cache directory (reduces nesting)
process_container_cache() {
    local container_dir="$1"
    [[ -d "$container_dir" ]] || return 0

    # Extract bundle ID and check protection status early
    local bundle_id=$(basename "$container_dir")
    local bundle_id_lower=$(echo "$bundle_id" | tr '[:upper:]' '[:lower:]')

    # Check explicit critical system components (case-insensitive regex)
    if [[ "$bundle_id_lower" =~ backgroundtaskmanagement || "$bundle_id_lower" =~ loginitems || "$bundle_id_lower" =~ systempreferences || "$bundle_id_lower" =~ systemsettings || "$bundle_id_lower" =~ settings || "$bundle_id_lower" =~ preferences || "$bundle_id_lower" =~ controlcenter || "$bundle_id_lower" =~ biometrickit || "$bundle_id_lower" =~ sfl || "$bundle_id_lower" =~ tcc ]]; then
        return 0
    fi

    if should_protect_data "$bundle_id" || should_protect_data "$bundle_id_lower"; then
        return 0
    fi

    local cache_dir="$container_dir/Data/Library/Caches"
    # Check if dir exists and has content
    [[ -d "$cache_dir" ]] || return 0

    # Fast check if empty using find (more efficient than ls)
    if find "$cache_dir" -mindepth 1 -maxdepth 1 -print -quit 2> /dev/null | grep -q .; then
        # Use global variables from caller for tracking
        local size=$(get_path_size_kb "$cache_dir")
        ((total_size += size))
        found_any=true
        ((cleaned_count++))

        if [[ "$DRY_RUN" != "true" ]]; then
            # Clean contents safely (rm -rf is restricted by safe_remove)
            for item in "$cache_dir"/*; do
                [[ -e "$item" ]] || continue
                safe_remove "$item" true || true
            done
        fi
    fi
}

# Clean browser caches (Safari, Chrome, Edge, Firefox, etc.)
clean_browsers() {
    safe_clean ~/Library/Caches/com.apple.Safari/* "Safari cache"

    # Chrome/Chromium
    safe_clean ~/Library/Caches/Google/Chrome/* "Chrome cache"
    safe_clean ~/Library/Application\ Support/Google/Chrome/*/Application\ Cache/* "Chrome app cache"
    safe_clean ~/Library/Application\ Support/Google/Chrome/*/GPUCache/* "Chrome GPU cache"
    safe_clean ~/Library/Caches/Chromium/* "Chromium cache"

    safe_clean ~/Library/Caches/com.microsoft.edgemac/* "Edge cache"
    safe_clean ~/Library/Caches/company.thebrowser.Browser/* "Arc cache"
    safe_clean ~/Library/Caches/company.thebrowser.dia/* "Dia cache"
    safe_clean ~/Library/Caches/BraveSoftware/Brave-Browser/* "Brave cache"
    safe_clean ~/Library/Caches/Firefox/* "Firefox cache"
    safe_clean ~/Library/Caches/com.operasoftware.Opera/* "Opera cache"
    safe_clean ~/Library/Caches/com.vivaldi.Vivaldi/* "Vivaldi cache"
    safe_clean ~/Library/Caches/Comet/* "Comet cache"
    safe_clean ~/Library/Caches/com.kagi.kagimacOS/* "Orion cache"
    safe_clean ~/Library/Caches/zen/* "Zen cache"
    safe_clean ~/Library/Application\ Support/Firefox/Profiles/*/cache2/* "Firefox profile cache"
}

# Clean cloud storage app caches
clean_cloud_storage() {
    safe_clean ~/Library/Caches/com.dropbox.* "Dropbox cache"
    safe_clean ~/Library/Caches/com.getdropbox.dropbox "Dropbox cache"
    safe_clean ~/Library/Caches/com.google.GoogleDrive "Google Drive cache"
    safe_clean ~/Library/Caches/com.baidu.netdisk "Baidu Netdisk cache"
    safe_clean ~/Library/Caches/com.alibaba.teambitiondisk "Alibaba Cloud cache"
    safe_clean ~/Library/Caches/com.box.desktop "Box cache"
    safe_clean ~/Library/Caches/com.microsoft.OneDrive "OneDrive cache"
}

# Clean office application caches
clean_office_applications() {
    safe_clean ~/Library/Caches/com.microsoft.Word "Microsoft Word cache"
    safe_clean ~/Library/Caches/com.microsoft.Excel "Microsoft Excel cache"
    safe_clean ~/Library/Caches/com.microsoft.Powerpoint "Microsoft PowerPoint cache"
    safe_clean ~/Library/Caches/com.microsoft.Outlook/* "Microsoft Outlook cache"
    safe_clean ~/Library/Caches/com.apple.iWork.* "Apple iWork cache"
    safe_clean ~/Library/Caches/com.kingsoft.wpsoffice.mac "WPS Office cache"
    safe_clean ~/Library/Caches/org.mozilla.thunderbird/* "Thunderbird cache"
    safe_clean ~/Library/Caches/com.apple.mail/* "Apple Mail cache"
}

# Clean virtualization tools
clean_virtualization_tools() {
    safe_clean ~/Library/Caches/com.vmware.fusion "VMware Fusion cache"
    safe_clean ~/Library/Caches/com.parallels.* "Parallels cache"
    safe_clean ~/VirtualBox\ VMs/.cache "VirtualBox cache"
    safe_clean ~/.vagrant.d/tmp/* "Vagrant temporary files"
}

# Clean Application Support logs and caches
clean_application_support_logs() {
    if [[ ! -d "$HOME/Library/Application Support" ]] || ! ls "$HOME/Library/Application Support" > /dev/null 2>&1; then
        note_activity
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Skipped: No permission to access Application Support"
        return 0
    fi

    if [[ -t 1 ]]; then
        MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning Application Support..."
    fi

    local total_size=0
    local cleaned_count=0
    local found_any=false

    # Clean log directories and cache patterns
    for app_dir in ~/Library/Application\ Support/*; do
        [[ -d "$app_dir" ]] || continue

        local app_name=$(basename "$app_dir")
        local app_name_lower=$(echo "$app_name" | tr '[:upper:]' '[:lower:]')
        local is_protected=false

        if should_protect_data "$app_name"; then
            is_protected=true
        elif should_protect_data "$app_name_lower"; then
            is_protected=true
        fi

        if [[ "$is_protected" == "true" ]]; then
            continue
        fi

        if [[ "$app_name_lower" =~ backgroundtaskmanagement || "$app_name_lower" =~ loginitems || "$app_name_lower" =~ systempreferences || "$app_name_lower" =~ systemsettings || "$app_name_lower" =~ settings || "$app_name_lower" =~ preferences || "$app_name_lower" =~ controlcenter || "$app_name_lower" =~ biometrickit || "$app_name_lower" =~ sfl || "$app_name_lower" =~ tcc ]]; then
            continue
        fi

        local -a start_candidates=("$app_dir/log" "$app_dir/logs" "$app_dir/activitylog" "$app_dir/Cache/Cache_Data" "$app_dir/Crashpad/completed")

        for candidate in "${start_candidates[@]}"; do
            if [[ -d "$candidate" ]]; then
                if find "$candidate" -mindepth 1 -maxdepth 1 -print -quit 2> /dev/null | grep -q .; then
                    local size=$(get_path_size_kb "$candidate")
                    ((total_size += size))
                    ((cleaned_count++))
                    found_any=true

                    if [[ "$DRY_RUN" != "true" ]]; then
                        for item in "$candidate"/*; do
                            [[ -e "$item" ]] || continue
                            safe_remove "$item" true > /dev/null 2>&1 || true
                        done
                    fi
                fi
            fi
        done
    done

    # Clean Group Containers logs
    local known_group_containers=(
        "group.com.apple.contentdelivery"
    )

    for container in "${known_group_containers[@]}"; do
        local container_path="$HOME/Library/Group Containers/$container"
        local -a gc_candidates=("$container_path/Logs" "$container_path/Library/Logs")

        for candidate in "${gc_candidates[@]}"; do
            if [[ -d "$candidate" ]]; then
                if find "$candidate" -mindepth 1 -maxdepth 1 -print -quit 2> /dev/null | grep -q .; then
                    local size=$(get_path_size_kb "$candidate")
                    ((total_size += size))
                    ((cleaned_count++))
                    found_any=true

                    if [[ "$DRY_RUN" != "true" ]]; then
                        for item in "$candidate"/*; do
                            [[ -e "$item" ]] || continue
                            safe_remove "$item" true > /dev/null 2>&1 || true
                        done
                    fi
                fi
            fi
        done
    done

    if [[ -t 1 ]]; then stop_inline_spinner; fi

    if [[ "$found_any" == "true" ]]; then
        local size_human=$(bytes_to_human "$((total_size * 1024))")
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}→${NC} Application Support logs/caches ${YELLOW}($size_human dry)${NC}"
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Application Support logs/caches ${GREEN}($size_human)${NC}"
        fi
        # Update global counters
        ((files_cleaned += cleaned_count))
        ((total_size_cleaned += total_size))
        ((total_items++))
        note_activity
    fi
}

# Check and show iOS device backup info
check_ios_device_backups() {
    local backup_dir="$HOME/Library/Application Support/MobileSync/Backup"
    # Simplified check without find to avoid hanging
    if [[ -d "$backup_dir" ]]; then
        local backup_kb=$(get_path_size_kb "$backup_dir")
        if [[ -n "${backup_kb:-}" && "$backup_kb" -gt 102400 ]]; then
            local backup_human=$(command du -sh "$backup_dir" 2> /dev/null | awk '{print $1}')
            if [[ -n "$backup_human" ]]; then
                note_activity
                echo -e "  Found ${GREEN}${backup_human}${NC} iOS backups"
                echo -e "  You can delete them manually: ${backup_dir}"
            fi
        fi
    fi
}

# Clean Apple Silicon specific caches
# Env: IS_M_SERIES
clean_apple_silicon_caches() {
    if [[ "${IS_M_SERIES:-false}" != "true" ]]; then
        return 0
    fi

    start_section "Apple Silicon updates"
    safe_clean /Library/Apple/usr/share/rosetta/rosetta_update_bundle "Rosetta 2 cache"
    safe_clean ~/Library/Caches/com.apple.rosetta.update "Rosetta 2 user cache"
    safe_clean ~/Library/Caches/com.apple.amp.mediasevicesd "Apple Silicon media service cache"
    end_section
}
