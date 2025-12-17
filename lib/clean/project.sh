#!/bin/bash
# Project Purge Module (mo purge)
# Removes heavy project build artifacts and dependencies

set -euo pipefail

# Targets to look for (heavy build artifacts)
readonly PURGE_TARGETS=(
    "node_modules"
    "target"       # Rust, Maven
    "build"        # Gradle, various
    "dist"         # JS builds
    "venv"         # Python
    ".venv"        # Python
    ".gradle"      # Gradle local
    "__pycache__"  # Python
    ".next"        # Next.js
    ".nuxt"        # Nuxt.js
    ".output"      # Nuxt.js
    "vendor"       # PHP Composer
    "obj"          # C# / Unity
    ".turbo"       # Turborepo cache
    ".parcel-cache" # Parcel bundler
)

# Minimum age in days before considering for cleanup
readonly MIN_AGE_DAYS=7

# Search paths (only project directories)
readonly PURGE_SEARCH_PATHS=(
    "$HOME/www"
    "$HOME/dev"
    "$HOME/Projects"
    "$HOME/GitHub"
    "$HOME/Code"
    "$HOME/Workspace"
    "$HOME/Repos"
    "$HOME/Development"
)

# Check if path is safe to clean (must be inside a project directory)
# Args: $1 - path to check
is_safe_project_artifact() {
    local path="$1"
    local search_path="$2"

    # Path must be absolute
    if [[ "$path" != /* ]]; then
        return 1
    fi

    # Must not be a direct child of HOME directory
    # e.g., ~/.gradle is NOT safe, but ~/Projects/foo/.gradle IS safe
    local relative_path="${path#$search_path/}"
    local depth=$(echo "$relative_path" | tr -cd '/' | wc -c)

    # Require at least 1 level deep (inside a project folder)
    # e.g., ~/www/MyProject/node_modules is OK (depth >= 1)
    # but ~/www/node_modules is NOT OK (depth = 0)
    if [[ $depth -lt 1 ]]; then
        return 1
    fi

    return 0
}

# Fast scan using fd or optimized find
# Args: $1 - search path, $2 - output file
# Scan for purge targets using strict project boundary checks
# Args: $1 - search path, $2 - output file
scan_purge_targets() {
    local search_path="$1"
    local output_file="$2"

    if [[ ! -d "$search_path" ]]; then
        return
    fi

    # Use fd for fast parallel search if available
    if command -v fd > /dev/null 2>&1; then
        local fd_args=(
            "--absolute-path"
            "--hidden"
            "--no-ignore"
            "--type" "d"
            "--min-depth" "2"
            "--max-depth" "5"
            "--threads" "4"
            "--exclude" ".git"
            "--exclude" "Library"
            "--exclude" ".Trash"
            "--exclude" "Applications"
        )

        for target in "${PURGE_TARGETS[@]}"; do
            fd_args+=("-g" "$target")
        done

        # Run fd command
        fd "${fd_args[@]}" . "$search_path" 2>/dev/null | while IFS= read -r item; do
            if is_safe_project_artifact "$item" "$search_path"; then
                 echo "$item"
            fi
        done | filter_nested_artifacts > "$output_file"
    else
        # Fallback to optimized find with pruning
        # This prevents descending into heavily nested dirs like node_modules once found,
        # providing a massive speedup (O(project_dirs) vs O(files)).

        local prune_args=()

        # 1. Directories to prune (ignore completely)
        local prune_dirs=(".git" "Library" ".Trash" "Applications")
        for dir in "${prune_dirs[@]}"; do
             # -name "DIR" -prune -o
             prune_args+=("-name" "$dir" "-prune" "-o")
        done

        # 2. Targets to find (print AND prune)
        # If we find node_modules, we print it and STOP looking inside it
        for target in "${PURGE_TARGETS[@]}"; do
            # -name "TARGET" -print -prune -o
            prune_args+=("-name" "$target" "-print" "-prune" "-o")
        done

        # Run find command
        # Logic: ( prune_pattern -prune -o target_pattern -print -prune )
        # Note: We rely on implicit recursion for directories that don't match any pattern.
        # -print is only called explicitly on targets.

        # Removing the trailing -o from loop construction if necessary?
        # Actually my loop adds -o at the end. I need to handle that.
        # Let's verify the array construction.

        # Re-building args cleanly:
        local find_expr=()

        # Excludes
        for dir in "${prune_dirs[@]}"; do
             find_expr+=("-name" "$dir" "-prune" "-o")
        done

        # Targets
        local i=0
        for target in "${PURGE_TARGETS[@]}"; do
            find_expr+=("-name" "$target" "-print" "-prune")

            # Add -o unless it's the very last item of targets
            if [[ $i -lt $((${#PURGE_TARGETS[@]} - 1)) ]]; then
                find_expr+=("-o")
            fi
            ((i++))
        done

        command find "$search_path" -mindepth 2 -maxdepth 5 -type d \
            \( "${find_expr[@]}" \) 2>/dev/null | while IFS= read -r item; do

            if is_safe_project_artifact "$item" "$search_path"; then
                echo "$item"
            fi
        done | filter_nested_artifacts > "$output_file"
    fi
}

# Filter out nested artifacts (e.g. node_modules inside node_modules)
filter_nested_artifacts() {
    while IFS= read -r item; do
        local parent_dir=$(dirname "$item")
        local is_nested=false

        for target in "${PURGE_TARGETS[@]}"; do
            # Check if parent directory IS a target or IS INSIDE a target
            # e.g. .../node_modules/foo/node_modules -> parent has node_modules
            if [[ "$parent_dir" == *"/$target"* || "$parent_dir" == *"/$target" ]]; then
                is_nested=true
                break
            fi
        done

        if [[ "$is_nested" == "false" ]]; then
            echo "$item"
        fi
    done
}

# Check if a path was modified recently (safety check)
# Args: $1 - path
is_recently_modified() {
    local path="$1"
    local age_days=$MIN_AGE_DAYS

    if [[ ! -e "$path" ]]; then
        return 1
    fi

    # Check modification time (macOS compatible)
    local mod_time
    mod_time=$(stat -f "%m" "$path" 2>/dev/null || stat -c "%Y" "$path" 2>/dev/null || echo "0")
    local current_time=$(date +%s)
    local age_seconds=$((current_time - mod_time))
    local age_in_days=$((age_seconds / 86400))

    if [[ $age_in_days -lt $age_days ]]; then
        return 0  # Recently modified
    else
        return 1  # Old enough to clean
    fi
}

# Get human-readable size of directory
# Args: $1 - path
get_dir_size_kb() {
    local path="$1"
    if [[ -d "$path" ]]; then
        du -sk "$path" 2>/dev/null | awk '{print $1}' || echo "0"
    else
        echo "0"
    fi
}

# Simplified clean function for project artifacts
# Args: $1 - path, $2 - description
safe_clean() {
    local path="$1"
    local description="$2"

    if [[ ! -e "$path" ]]; then
        return 0
    fi

    # Get size before deletion
    local size_kb=$(get_dir_size_kb "$path")

    if [[ "$DRY_RUN" == "true" ]]; then
        if [[ $size_kb -gt 0 ]]; then
            local size_mb=$((size_kb / 1024))
            echo -e "${GRAY}Would remove:${NC} $description (~${size_mb}MB)"
        fi
    else
        if [[ $size_kb -gt 0 ]]; then
            local size_mb=$((size_kb / 1024))

            # Show cleaning status (transient) with spinner
            if [[ -t 1 ]]; then
                # Use standard spinner prefix or none as requested?
                # User asked for "no indentation". MOLE_SPINNER_PREFIX controls indentation in ui.sh.
                # But ui.sh often adds "  |".
                # Let's use start_inline_spinner which uses MOLE_SPINNER_PREFIX.
                # We can temporarily clear prefix to avoid indentation if needed,
                # but standard UI guidelines might suggest some alignment.
                # The user specifically said "不要缩进".
                local original_prefix="${MOLE_SPINNER_PREFIX:-}"
                MOLE_SPINNER_PREFIX="" start_inline_spinner "Cleaning $description (~${size_mb}MB)..."

                rm -rf "$path" 2>/dev/null || true

                stop_inline_spinner
                MOLE_SPINNER_PREFIX="$original_prefix"
            else
                rm -rf "$path" 2>/dev/null || true
            fi

            if [[ ! -e "$path" ]]; then
                echo -e "${GREEN}${ICON_SUCCESS}${NC} Removed $description (~${size_mb}MB)"

                # Update stats file
                if [[ -f "$SCRIPT_DIR/../.mole_cleanup_stats" ]]; then
                    local current_total=$(cat "$SCRIPT_DIR/../.mole_cleanup_stats")
                    local new_total=$((current_total + size_kb))
                    echo "$new_total" > "$SCRIPT_DIR/../.mole_cleanup_stats"
                fi

                # Update count file
                local count_file="$SCRIPT_DIR/../.mole_cleanup_count"
                local current_count=0
                if [[ -f "$count_file" ]]; then
                    current_count=$(cat "$count_file")
                fi
                echo $((current_count + 1)) > "$count_file"
            else
                echo -e "${RED}${ICON_CROSS}${NC} Failed to remove $description"
            fi
        fi
    fi
}

# Main cleanup function
# Env: DRY_RUN
clean_project_artifacts() {
    local -a all_found_items=()
    local -a safe_to_clean=()
    local -a recently_modified=()
    local total_found_size=0 # in KB

    # Show warning and ask for confirmation (not in dry-run mode)
    if [[ "$DRY_RUN" != "true" && -t 0 ]]; then
        echo -e "${GRAY}${ICON_SOLID}${NC} Will remove old project build artifacts, use --dry-run to preview"
        echo -ne "${PURPLE}${ICON_ARROW}${NC} Press ${GREEN}Enter${NC} to continue, ${GRAY}ESC${NC} to cancel: "

        # Read single key
        IFS= read -r -s -n1 key || key=""
        drain_pending_input
        case "$key" in
            $'\e')
                echo ""
                echo -e "${GRAY}Cancelled${NC}"
                printf '\n'
                exit 0
                ;;
            "" | $'\n' | $'\r')
                printf "\r\033[K"
                # Continue with scan
                ;;
            *)
                echo ""
                echo -e "${GRAY}Cancelled${NC}"
                printf '\n'
                exit 0
                ;;
        esac
    fi

    # Set up cleanup on interrupt
    local scan_pids=()
    local scan_temps=()
    cleanup_scan() {
        # Kill all background scans
        for pid in "${scan_pids[@]}"; do
            kill "$pid" 2>/dev/null || true
        done
        # Clean up temp files
        for temp in "${scan_temps[@]}"; do
            rm -f "$temp" 2>/dev/null || true
        done
        if [[ -t 1 ]]; then
            stop_inline_spinner
        fi
        printf '\n'
        echo -e "${GRAY}Interrupted${NC}"
        printf '\n'
        exit 130
    }
    trap cleanup_scan INT TERM

    # Start parallel scanning of all paths at once
    if [[ -t 1 ]]; then
        start_inline_spinner "Scanning project directories (please wait)..."
    fi

    # Launch all scans in parallel
    for path in "${PURGE_SEARCH_PATHS[@]}"; do
        if [[ -d "$path" ]]; then
            local scan_output
            scan_output=$(mktemp)
            scan_temps+=("$scan_output")

            # Launch scan in background for true parallelism
            scan_purge_targets "$path" "$scan_output" &
            local scan_pid=$!
            scan_pids+=("$scan_pid")
        fi
    done

    # Wait for all scans to complete
    for pid in "${scan_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    # Collect all results
    for scan_output in "${scan_temps[@]}"; do
        if [[ -f "$scan_output" ]]; then
            while IFS= read -r item; do
                if [[ -n "$item" ]]; then
                    all_found_items+=("$item")
                fi
            done < "$scan_output"
            rm -f "$scan_output"
        fi
    done

    # Clean up trap
    trap - INT TERM

    if [[ ${#all_found_items[@]} -eq 0 ]]; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} No project artifacts found."
        note_activity
        return
    fi

    # Filter items based on modification time
    if [[ -t 1 ]]; then
        start_inline_spinner "Analyzing artifacts..."
    fi

    for item in "${all_found_items[@]}"; do
        if is_recently_modified "$item"; then
            recently_modified+=("$item")
        else
            safe_to_clean+=("$item")
            local item_size=$(get_dir_size_kb "$item")
            total_found_size=$((total_found_size + item_size))
        fi
    done

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    echo -e "${BLUE}●${NC} Found ${#all_found_items[@]} artifacts (${#safe_to_clean[@]} older than $MIN_AGE_DAYS days)"

    if [[ ${#recently_modified[@]} -gt 0 ]]; then
        echo -e "${YELLOW}${ICON_WARNING}${NC} Skipping ${#recently_modified[@]} recently modified items (active projects)"
    fi

    if [[ ${#safe_to_clean[@]} -eq 0 ]]; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} No old artifacts to clean."
        note_activity
        return
    fi

    # Show total size estimate
    local total_size_mb=$((total_found_size / 1024))
    if [[ $total_size_mb -gt 0 ]]; then
        echo -e "${GRAY}Estimated space to reclaim: ~${total_size_mb} MB${NC}"
    fi

    # Clean safe items
    for item in "${safe_to_clean[@]}"; do
        safe_clean "$item" "$(basename "$(dirname "$item")")/$(basename "$item")"
    done
}
