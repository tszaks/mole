#!/bin/bash
# System Configuration Maintenance Module
# Fix broken preferences and broken login items

set -euo pipefail

# ============================================================================
# Broken Preferences Detection and Cleanup
# Find and remove corrupted .plist files
# ============================================================================

# Clean corrupted preference files
fix_broken_preferences() {
    local prefs_dir="$HOME/Library/Preferences"
    [[ -d "$prefs_dir" ]] || return 0

    local broken_count=0

    # Check main preferences directory
    while IFS= read -r plist_file; do
        [[ -f "$plist_file" ]] || continue

        # Skip system preferences
        local filename
        filename=$(basename "$plist_file")
        case "$filename" in
            com.apple.* | .GlobalPreferences* | loginwindow.plist)
                continue
                ;;
        esac

        # Validate plist using plutil
        plutil -lint "$plist_file" > /dev/null 2>&1 && continue

        # Remove broken plist
        safe_remove "$plist_file" true > /dev/null 2>&1 || true
        ((broken_count++))
    done < <(command find "$prefs_dir" -maxdepth 1 -name "*.plist" -type f 2> /dev/null || true)

    # Check ByHost preferences with timeout protection
    local byhost_dir="$prefs_dir/ByHost"
    if [[ -d "$byhost_dir" ]]; then
        while IFS= read -r plist_file; do
            [[ -f "$plist_file" ]] || continue

            local filename
            filename=$(basename "$plist_file")
            case "$filename" in
                com.apple.* | .GlobalPreferences*)
                    continue
                    ;;
            esac

            plutil -lint "$plist_file" > /dev/null 2>&1 && continue

            safe_remove "$plist_file" true > /dev/null 2>&1 || true
            ((broken_count++))
        done < <(command find "$byhost_dir" -name "*.plist" -type f 2> /dev/null || true)
    fi

    echo "$broken_count"
}


