#!/bin/bash
# User Data Cleanup Module

set -euo pipefail

# Clean user essentials (caches, logs, trash, crash reports)
clean_user_essentials() {
    safe_clean ~/Library/Caches/* "User app cache"
    safe_clean ~/Library/Logs/* "User app logs"
    safe_clean ~/.Trash/* "Trash"

    # Empty trash on mounted volumes
    if [[ -d "/Volumes" && "$DRY_RUN" != "true" ]]; then
        if [[ -t 1 ]]; then
            MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning external volumes..."
        fi
        for volume in /Volumes/*; do
            [[ -d "$volume" && -d "$volume/.Trashes" && -w "$volume" ]] || continue

            # Skip network volumes
            local fs_type=$(command df -T "$volume" 2> /dev/null | tail -1 | awk '{print $2}')
            case "$fs_type" in
                nfs | smbfs | afpfs | cifs | webdav) continue ;;
            esac

            # Verify volume is mounted and not a symlink
            mount | grep -q "on $volume " || continue
            [[ -L "$volume/.Trashes" ]] && continue

            # Safely iterate and remove each item
            while IFS= read -r -d '' item; do
                safe_remove "$item" true || true
            done < <(command find "$volume/.Trashes" -mindepth 1 -maxdepth 1 -print0 2> /dev/null || true)
        done
        if [[ -t 1 ]]; then stop_inline_spinner; fi
    fi

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

# Clean Finder metadata (.DS_Store files)
clean_finder_metadata() {
    if [[ "$PROTECT_FINDER_METADATA" == "true" ]]; then
        note_activity
        echo -e "  ${GRAY}${ICON_SUCCESS}${NC} Finder metadata (whitelisted)"
    else
        clean_ds_store_tree "$HOME" "Home directory (.DS_Store)"

        if [[ -d "/Volumes" ]]; then
            for volume in /Volumes/*; do
                [[ -d "$volume" && -w "$volume" ]] || continue

                local fs_type=""
                fs_type=$(command df -T "$volume" 2> /dev/null | tail -1 | awk '{print $2}')
                case "$fs_type" in
                    nfs | smbfs | afpfs | cifs | webdav) continue ;;
                esac

                clean_ds_store_tree "$volume" "$(basename "$volume") volume (.DS_Store)"
            done
        fi
    fi
}

# Clean macOS system caches
clean_macos_system_caches() {
    safe_clean ~/Library/Saved\ Application\ State/* "Saved application states"
    safe_clean ~/Library/Caches/com.apple.spotlight "Spotlight cache"

    # MOVED: Spotlight cache cleanup moved to optimize command

    safe_clean ~/Library/Caches/com.apple.photoanalysisd "Photo analysis cache"
    safe_clean ~/Library/Caches/com.apple.akd "Apple ID cache"
    safe_clean ~/Library/Caches/com.apple.Safari/Webpage\ Previews/* "Safari webpage previews"
    safe_clean ~/Library/Application\ Support/CloudDocs/session/db/* "iCloud session cache"
    safe_clean ~/Library/Caches/com.apple.Safari/fsCachedData/* "Safari cached data"
    safe_clean ~/Library/Caches/com.apple.WebKit.WebContent/* "WebKit content cache"
    safe_clean ~/Library/Caches/com.apple.WebKit.Networking/* "WebKit network cache"
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
        [[ -d "$container_dir" ]] || continue

        # Extract bundle ID and check protection status early
        local bundle_id=$(basename "$container_dir")
        local bundle_id_lower=$(echo "$bundle_id" | tr '[:upper:]' '[:lower:]')

        # Check explicit critical system components (case-insensitive regex)
        if [[ "$bundle_id_lower" =~ backgroundtaskmanagement || "$bundle_id_lower" =~ loginitems ]]; then
            continue
        fi

        if should_protect_data "$bundle_id"; then
            continue
        elif should_protect_data "$bundle_id_lower"; then
            continue
        fi

        local cache_dir="$container_dir/Data/Library/Caches"
        # Check if dir exists and has content
        if [[ -d "$cache_dir" ]]; then
            # Fast check if empty (avoid expensive size calc on empty dirs)
            if [[ -n "$(ls -A "$cache_dir" 2> /dev/null)" ]]; then
                # Get size
                local size=$(get_path_size_kb "$cache_dir")
                ((total_size += size))
                found_any=true
                ((cleaned_count++))

                if [[ "$DRY_RUN" != "true" ]]; then
                    # Clean contents safely
                    # We know this is a user cache path, so rm -rf is acceptable here
                    # provided we keep the Cache directory itself
                    for item in "${cache_dir:?}"/*; do
                        safe_remove "$item" true || true
                    done
                fi
            fi
        fi
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

    # DISABLED: Service Worker CacheStorage scanning (find can hang on large browser profiles)
    # Browser caches are already cleaned by the safe_clean calls above
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

        if [[ "$app_name" =~ backgroundtaskmanagement || "$app_name" =~ loginitems ]]; then
            continue
        fi

        local -a start_candidates=("$app_dir/log" "$app_dir/logs" "$app_dir/activitylog" "$app_dir/Cache/Cache_Data" "$app_dir/Crashpad/completed")

        for candidate in "${start_candidates[@]}"; do
            if [[ -d "$candidate" ]]; then
                if [[ -n "$(ls -A "$candidate" 2> /dev/null)" ]]; then
                    local size=$(get_path_size_kb "$candidate")
                    ((total_size += size))
                    ((cleaned_count++))
                    found_any=true

                    if [[ "$DRY_RUN" != "true" ]]; then
                        safe_remove "$candidate"/* true > /dev/null 2>&1 || true
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
                if [[ -n "$(ls -A "$candidate" 2> /dev/null)" ]]; then
                    local size=$(get_path_size_kb "$candidate")
                    ((total_size += size))
                    ((cleaned_count++))
                    found_any=true

                    if [[ "$DRY_RUN" != "true" ]]; then
                        safe_remove "$candidate"/* true > /dev/null 2>&1 || true
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
    if [[ "$IS_M_SERIES" != "true" ]]; then
        return 0
    fi

    safe_clean /Library/Apple/usr/share/rosetta/rosetta_update_bundle "Rosetta 2 cache"
    safe_clean ~/Library/Caches/com.apple.rosetta.update "Rosetta 2 user cache"
    safe_clean ~/Library/Caches/com.apple.amp.mediasevicesd "Apple Silicon media service cache"
}
