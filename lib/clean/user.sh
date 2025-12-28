#!/bin/bash
# User Data Cleanup Module

set -euo pipefail

# Clean user essentials (caches, logs, trash)
clean_user_essentials() {
    start_section_spinner "Scanning caches..."

    safe_clean ~/Library/Caches/* "User app cache"

    stop_section_spinner

    safe_clean ~/Library/Logs/* "User app logs"

    # Check if Trash directory is whitelisted
    if is_path_whitelisted "$HOME/.Trash"; then
        note_activity
        echo -e "  ${GREEN}${ICON_EMPTY}${NC} Trash · whitelist protected"
    else
        safe_clean ~/.Trash/* "Trash"
    fi
}

# Helper: Scan external volumes for cleanup (Trash & DS_Store)
scan_external_volumes() {
    [[ -d "/Volumes" ]] || return 0

    # Fast pre-check: collect non-system external volumes and detect network volumes
    local -a candidate_volumes=()
    local -a network_volumes=()
    for volume in /Volumes/*; do
        # Basic checks (directory, writable, not a symlink)
        [[ -d "$volume" && -w "$volume" && ! -L "$volume" ]] || continue

        # Skip system root if it appears in /Volumes
        [[ "$volume" == "/" || "$volume" == "/Volumes/Macintosh HD" ]] && continue

        # Use diskutil to intelligently detect network volumes (SMB/NFS/AFP)
        # Timeout protection: 1s per volume to avoid slow network responses
        local protocol=""
        protocol=$(run_with_timeout 1 command diskutil info "$volume" 2> /dev/null | grep -i "Protocol:" | awk '{print $2}' || echo "")

        case "$protocol" in
            SMB | NFS | AFP | CIFS | WebDAV)
                network_volumes+=("$volume")
                continue
                ;;
        esac

        # Fallback: Check filesystem type via df if diskutil didn't identify protocol
        local fs_type=""
        fs_type=$(run_with_timeout 1 command df -T "$volume" 2> /dev/null | tail -1 | awk '{print $2}' || echo "")
        case "$fs_type" in
            nfs | smbfs | afpfs | cifs | webdav)
                network_volumes+=("$volume")
                continue
                ;;
        esac

        candidate_volumes+=("$volume")
    done

    # If no external volumes found, return immediately (zero overhead)
    local volume_count=${#candidate_volumes[@]}
    local network_count=${#network_volumes[@]}

    if [[ $volume_count -eq 0 ]]; then
        # Show info if network volumes were skipped
        if [[ $network_count -gt 0 ]]; then
            echo -e "  ${GRAY}${ICON_LIST}${NC} External volumes (${network_count} network volume(s) skipped)"
            note_activity
        fi
        return 0
    fi

    # We have local external volumes, now perform full scan
    start_section_spinner "Scanning $volume_count external volume(s)..."

    for volume in "${candidate_volumes[@]}"; do
        # Verify volume is actually mounted (reduced timeout from 2s to 1s)
        run_with_timeout 1 mount | grep -q "on $volume " || continue

        # 1. Clean Trash on volume
        local volume_trash="$volume/.Trashes"

        # Check if external volume Trash is whitelisted
        if [[ -d "$volume_trash" && "$DRY_RUN" != "true" ]] && ! is_path_whitelisted "$volume_trash"; then
            # Safely iterate and remove each item
            while IFS= read -r -d '' item; do
                safe_remove "$item" true || true
            done < <(command find "$volume_trash" -mindepth 1 -maxdepth 1 -print0 2> /dev/null || true)
        fi

        # 2. Clean .DS_Store
        if [[ "$PROTECT_FINDER_METADATA" != "true" ]]; then
            clean_ds_store_tree "$volume" "$(basename "$volume") volume (.DS_Store)"
        fi
    done

    stop_section_spinner
}

# Clean Finder metadata (.DS_Store files)
clean_finder_metadata() {
    stop_section_spinner

    if [[ "$PROTECT_FINDER_METADATA" == "true" ]]; then
        note_activity
        echo -e "  ${GREEN}${ICON_EMPTY}${NC} Finder metadata · whitelist protected"
        return
    fi

    clean_ds_store_tree "$HOME" "Home directory (.DS_Store)"
}

# Clean macOS system caches
clean_macos_system_caches() {
    stop_section_spinner

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
    safe_clean ~/Downloads/*.download "Safari incomplete downloads"
    safe_clean ~/Downloads/*.crdownload "Chrome incomplete downloads"
    safe_clean ~/Downloads/*.part "Partial incomplete downloads"

    # Additional user-level caches
    safe_clean ~/Library/Autosave\ Information/* "Autosave information"
    safe_clean ~/Library/IdentityCaches/* "Identity caches"
    safe_clean ~/Library/Suggestions/* "Siri suggestions cache"
    safe_clean ~/Library/Calendars/Calendar\ Cache "Calendar cache"
    safe_clean ~/Library/Application\ Support/AddressBook/Sources/*/Photos.cache "Address Book photo cache"
}

# Clean recent items lists
clean_recent_items() {
    stop_section_spinner

    local shared_dir="$HOME/Library/Application Support/com.apple.sharedfilelist"

    # Target only the global recent item lists to avoid touching per-app/System Settings SFL files
    local -a recent_lists=(
        "$shared_dir/com.apple.LSSharedFileList.RecentApplications.sfl2"
        "$shared_dir/com.apple.LSSharedFileList.RecentDocuments.sfl2"
        "$shared_dir/com.apple.LSSharedFileList.RecentServers.sfl2"
        "$shared_dir/com.apple.LSSharedFileList.RecentHosts.sfl2"
        "$shared_dir/com.apple.LSSharedFileList.RecentApplications.sfl"
        "$shared_dir/com.apple.LSSharedFileList.RecentDocuments.sfl"
        "$shared_dir/com.apple.LSSharedFileList.RecentServers.sfl"
        "$shared_dir/com.apple.LSSharedFileList.RecentHosts.sfl"
    )

    if [[ -d "$shared_dir" ]]; then
        for sfl_file in "${recent_lists[@]}"; do
            [[ -e "$sfl_file" ]] && safe_clean "$sfl_file" "Recent items list"
        done
    fi

    # Clean recent items preferences
    safe_clean ~/Library/Preferences/com.apple.recentitems.plist "Recent items preferences"
}

# Clean old mail downloads
clean_mail_downloads() {
    stop_section_spinner

    local mail_age_days=${MOLE_MAIL_AGE_DAYS:-30}
    if ! [[ "$mail_age_days" =~ ^[0-9]+$ ]]; then
        mail_age_days=30
    fi

    local -a mail_dirs=(
        "$HOME/Library/Mail Downloads"
        "$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
    )

    local count=0
    local cleaned_kb=0

    for target_path in "${mail_dirs[@]}"; do
        if [[ -d "$target_path" ]]; then
            # Check directory size threshold
            local dir_size_kb=0
            if command -v du > /dev/null 2>&1; then
                dir_size_kb=$(du -sk "$target_path" 2> /dev/null | awk '{print $1}' || echo "0")
            fi

            # Skip if below threshold
            if [[ $dir_size_kb -lt ${MOLE_MAIL_DOWNLOADS_MIN_KB:-5120} ]]; then
                continue
            fi

            # Find and remove files older than specified days
            while IFS= read -r -d '' file_path; do
                if [[ -f "$file_path" ]]; then
                    local file_size_kb=$(du -sk "$file_path" 2> /dev/null | awk '{print $1}' || echo "0")
                    if safe_remove "$file_path" true; then
                        ((count++))
                        ((cleaned_kb += file_size_kb))
                    fi
                fi
            done < <(command find "$target_path" -type f -mtime +"$mail_age_days" -print0 2> /dev/null || true)
        fi
    done

    if [[ $count -gt 0 ]]; then
        local cleaned_mb=$(echo "$cleaned_kb" | awk '{printf "%.1f", $1/1024}')
        echo "  ${GREEN}${ICON_SUCCESS}${NC} Cleaned $count mail attachments (~${cleaned_mb}MB)"
        note_activity
    fi
}

# Clean sandboxed app caches
clean_sandboxed_app_caches() {
    stop_section_spinner

    safe_clean ~/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/* "Wallpaper agent cache"
    safe_clean ~/Library/Containers/com.apple.mediaanalysisd/Data/Library/Caches/* "Media analysis cache"
    safe_clean ~/Library/Containers/com.apple.AppStore/Data/Library/Caches/* "App Store cache"
    safe_clean ~/Library/Containers/com.apple.configurator.xpc.InternetService/Data/tmp/* "Apple Configurator temp files"

    # Clean sandboxed app caches - iterate quietly to avoid UI flashing
    local containers_dir="$HOME/Library/Containers"
    [[ ! -d "$containers_dir" ]] && return 0

    start_section_spinner "Scanning sandboxed apps..."

    local total_size=0
    local cleaned_count=0
    local found_any=false

    # Enable nullglob for safe globbing; restore afterwards
    local _ng_state
    _ng_state=$(shopt -p nullglob || true)
    shopt -s nullglob

    for container_dir in "$containers_dir"/*; do
        process_container_cache "$container_dir"
    done

    # Restore nullglob to previous state
    eval "$_ng_state"

    stop_section_spinner

    if [[ "$found_any" == "true" ]]; then
        local size_human=$(bytes_to_human "$((total_size * 1024))")
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Sandboxed app caches ${YELLOW}($size_human dry)${NC}"
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Sandboxed app caches ${GREEN}($size_human)${NC}"
        fi
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
    if is_critical_system_component "$bundle_id"; then
        return 0
    fi
    if should_protect_data "$bundle_id" || should_protect_data "$(echo "$bundle_id" | tr '[:upper:]' '[:lower:]')"; then
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
            # Clean contents safely with local nullglob management
            local _ng_state
            _ng_state=$(shopt -p nullglob || true)
            shopt -s nullglob

            for item in "$cache_dir"/*; do
                [[ -e "$item" ]] || continue
                safe_remove "$item" true || true
            done

            eval "$_ng_state"
        fi
    fi
}

# Clean browser caches (Safari, Chrome, Edge, Firefox, etc.)
clean_browsers() {
    stop_section_spinner

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
    stop_section_spinner

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
    stop_section_spinner

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
    stop_section_spinner

    safe_clean ~/Library/Caches/com.vmware.fusion "VMware Fusion cache"
    safe_clean ~/Library/Caches/com.parallels.* "Parallels cache"
    safe_clean ~/VirtualBox\ VMs/.cache "VirtualBox cache"
    safe_clean ~/.vagrant.d/tmp/* "Vagrant temporary files"
}

# Clean Application Support logs and caches
clean_application_support_logs() {
    stop_section_spinner

    if [[ ! -d "$HOME/Library/Application Support" ]] || ! ls "$HOME/Library/Application Support" > /dev/null 2>&1; then
        note_activity
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Skipped: No permission to access Application Support"
        return 0
    fi

    start_section_spinner "Scanning Application Support..."

    local total_size=0
    local cleaned_count=0
    local found_any=false

    # Enable nullglob for safe globbing
    local _ng_state
    _ng_state=$(shopt -p nullglob || true)
    shopt -s nullglob

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

        if is_critical_system_component "$app_name"; then
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

    # Restore nullglob to previous state
    eval "$_ng_state"

    stop_section_spinner

    if [[ "$found_any" == "true" ]]; then
        local size_human=$(bytes_to_human "$((total_size * 1024))")
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Application Support logs/caches ${YELLOW}($size_human dry)${NC}"
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Application Support logs/caches ${GREEN}($size_human)${NC}"
        fi
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
