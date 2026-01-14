#!/bin/bash
# Mole - Homebrew Cask Uninstallation Support
# Detects Homebrew-managed casks via Caskroom linkage and uninstalls them via brew

set -euo pipefail

# Prevent multiple sourcing
if [[ -n "${MOLE_BREW_UNINSTALL_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_BREW_UNINSTALL_LOADED=1

# Resolve a path to its absolute real path (follows symlinks)
# Args: $1 - path to resolve
# Returns: Absolute resolved path, or empty string on failure
resolve_path() {
    local p="$1"

    # Prefer realpath if available (GNU coreutils)
    if command -v realpath > /dev/null 2>&1; then
        realpath "$p" 2> /dev/null && return 0
    fi

    # macOS fallback: use python3 (almost always available)
    if command -v python3 > /dev/null 2>&1; then
        python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$p" 2> /dev/null && return 0
    fi

    # Last resort: perl (available on macOS)
    if command -v perl > /dev/null 2>&1; then
        perl -MCwd -e 'print Cwd::realpath($ARGV[0])' "$p" 2> /dev/null && return 0
    fi

    # Final fallback: if symlink, try to make readlink output absolute
    if [[ -L "$p" ]]; then
        local target
        target=$(readlink "$p" 2>/dev/null) || return 1
        # If target is relative, prepend the directory of the symlink
        if [[ "$target" != /* ]]; then
            local dir
            dir=$(cd -P "$(dirname "$p")" 2>/dev/null && pwd) || return 1
            target="$dir/$target"
        fi
        # Normalize by resolving the directory component
        local target_dir target_base
        target_dir=$(cd -P "$(dirname "$target")" 2>/dev/null && pwd) || {
            echo "$target"
            return 0
        }
        target_base=$(basename "$target")
        echo "$target_dir/$target_base"
        return 0
    fi

    # Not a symlink, return as-is if it exists
    if [[ -e "$p" ]]; then
        echo "$p"
        return 0
    fi
    return 1
}

# Check if Homebrew is installed and accessible
# Returns: 0 if brew is available, 1 otherwise
is_homebrew_available() {
    command -v brew > /dev/null 2>&1
}

# Extract cask token from a Caskroom path
# Args: $1 - path (must be inside Caskroom)
# Prints: cask token to stdout
# Returns: 0 if valid token extracted, 1 otherwise
_extract_cask_token_from_path() {
    local path="$1"

    # Check if path is inside Caskroom
    case "$path" in
        /opt/homebrew/Caskroom/* | /usr/local/Caskroom/*) ;;
        *) return 1 ;;
    esac

    # Extract token from path: /opt/homebrew/Caskroom/<token>/<version>/...
    local token
    token="${path#*/Caskroom/}" # Remove everything up to and including Caskroom/
    token="${token%%/*}"        # Take only the first path component

    # Validate token looks like a valid cask name (lowercase alphanumeric with hyphens)
    if [[ -n "$token" && "$token" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        echo "$token"
        return 0
    fi

    return 1
}

# Stage 1: Deterministic detection via fully resolved path
# Fast, no false positives - follows all symlinks
_detect_cask_via_resolved_path() {
    local app_path="$1"
    local resolved
    if resolved=$(resolve_path "$app_path") && [[ -n "$resolved" ]]; then
        _extract_cask_token_from_path "$resolved" && return 0
    fi
    return 1
}

# Stage 2: Search Caskroom by app bundle name using find
# Catches apps where the .app in /Applications doesn't link to Caskroom
# Only succeeds if exactly one cask matches (avoids wrong uninstall)
_detect_cask_via_caskroom_search() {
    local app_bundle_name="$1"
    [[ -z "$app_bundle_name" ]] && return 1

    local -a tokens=()
    local -a uniq=()
    local room match token t u seen

    for room in "/opt/homebrew/Caskroom" "/usr/local/Caskroom"; do
        [[ -d "$room" ]] || continue
        while IFS= read -r match; do
            [[ -n "$match" ]] || continue
            token=$(_extract_cask_token_from_path "$match" 2>/dev/null) || continue
            [[ -n "$token" ]] || continue
            tokens+=("$token")
        done < <(find "$room" -maxdepth 3 -name "$app_bundle_name" 2>/dev/null)
    done

    # Deduplicate tokens
    for t in "${tokens[@]+"${tokens[@]}"}"; do
        seen=false
        for u in "${uniq[@]+"${uniq[@]}"}"; do
            [[ "$u" == "$t" ]] && { seen=true; break; }
        done
        [[ "$seen" == "false" ]] && uniq+=("$t")
    done

    # Only succeed if exactly one unique token found and it's installed
    if ((${#uniq[@]} == 1)); then
        local candidate="${uniq[0]}"
        HOMEBREW_NO_ENV_HINTS=1 brew list --cask 2>/dev/null | grep -qxF "$candidate" || return 1
        echo "$candidate"
        return 0
    fi

    return 1
}

# Stage 3: Check if app_path is a direct symlink to Caskroom (simpler readlink check)
# Redundant with stage 1 in most cases, but kept as fallback
_detect_cask_via_symlink_check() {
    local app_path="$1"
    [[ -L "$app_path" ]] || return 1

    local target
    target=$(readlink "$app_path" 2>/dev/null) || return 1

    for room in "/opt/homebrew/Caskroom" "/usr/local/Caskroom"; do
        if [[ "$target" == "$room/"* ]]; then
            local relative="${target#"$room"/}"
            local token="${relative%%/*}"
            if [[ -n "$token" && "$token" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
                echo "$token"
                return 0
            fi
        fi
    done

    return 1
}

# Stage 4: Query brew list --cask and verify with brew info
# Slowest but catches edge cases where app was moved/renamed
_detect_cask_via_brew_list() {
    local app_path="$1"
    local app_bundle_name="$2"

    local app_name_only="${app_bundle_name%.app}"
    local cask_name
    cask_name=$(HOMEBREW_NO_ENV_HINTS=1 brew list --cask 2> /dev/null | grep -Fix "$(echo "$app_name_only" | LC_ALL=C tr '[:upper:]' '[:lower:]')" || echo "")

    if [[ -n "$cask_name" ]]; then
        # Verify this cask actually owns this app path
        if HOMEBREW_NO_ENV_HINTS=1 brew info --cask "$cask_name" 2> /dev/null | grep -qF "$app_path"; then
            echo "$cask_name"
            return 0
        fi
    fi

    return 1
}

# Get Homebrew cask name for an app
# Uses multi-stage detection (fast to slow, deterministic to heuristic):
#   1. Resolve symlinks fully, check if path is in Caskroom (fast, deterministic)
#   2. Search Caskroom by app bundle name using find
#   3. Check if app is a direct symlink to Caskroom
#   4. Query brew list --cask and verify with brew info (slowest)
#
# Args: $1 - app_path
# Prints: cask token to stdout if brew-managed
# Returns: 0 if Homebrew-managed, 1 otherwise
get_brew_cask_name() {
    local app_path="$1"
    [[ -z "$app_path" || ! -e "$app_path" ]] && return 1
    is_homebrew_available || return 1

    local app_bundle_name
    app_bundle_name=$(basename "$app_path")

    # Try each detection method in order (fast to slow)
    _detect_cask_via_resolved_path "$app_path" && return 0
    _detect_cask_via_caskroom_search "$app_bundle_name" && return 0
    _detect_cask_via_symlink_check "$app_path" && return 0
    _detect_cask_via_brew_list "$app_path" "$app_bundle_name" && return 0

    return 1
}

# Uninstall a Homebrew cask and verify removal
# Args: $1 - cask_name, $2 - app_path (optional, for verification)
# Returns: 0 on success, 1 on failure
brew_uninstall_cask() {
    local cask_name="$1"
    local app_path="${2:-}"

    is_homebrew_available || return 1
    [[ -z "$cask_name" ]] && return 1

    debug_log "Attempting brew uninstall --cask $cask_name"

    # Suppress hints, auto-update, and ensure non-interactive
    export HOMEBREW_NO_ENV_HINTS=1
    export HOMEBREW_NO_AUTO_UPDATE=1
    export NONINTERACTIVE=1

    # Run uninstall with timeout (cask uninstalls can hang on prompts)
    local output
    local uninstall_succeeded=false
    if output=$(run_with_timeout 120 brew uninstall --cask "$cask_name" 2>&1); then
        debug_log "brew uninstall --cask $cask_name completed successfully"
        uninstall_succeeded=true
    else
        local exit_code=$?
        debug_log "brew uninstall --cask $cask_name exited with code $exit_code: $output"
    fi

    # Check current state
    local cask_still_installed=false
    if HOMEBREW_NO_ENV_HINTS=1 brew list --cask 2>/dev/null | grep -qxF "$cask_name"; then
        cask_still_installed=true
    fi

    local app_still_exists=false
    if [[ -n "$app_path" && -e "$app_path" ]]; then
        app_still_exists=true
    fi

    # Success cases:
    # 1. Uninstall succeeded and cask/app are gone
    # 2. Uninstall failed but cask wasn't installed anyway (idempotent)
    if [[ "$uninstall_succeeded" == "true" ]]; then
        if [[ "$cask_still_installed" == "true" ]]; then
            debug_log "Cask '$cask_name' still in brew list after successful uninstall"
            return 1
        fi
        if [[ "$app_still_exists" == "true" ]]; then
            debug_log "App still exists at '$app_path' after brew uninstall"
            return 1
        fi
        debug_log "Successfully uninstalled cask '$cask_name'"
        return 0
    else
        # Uninstall command failed - only succeed if already fully uninstalled
        if [[ "$cask_still_installed" == "false" && "$app_still_exists" == "false" ]]; then
            debug_log "Cask '$cask_name' was already uninstalled"
            return 0
        fi
        debug_log "brew uninstall failed and cask/app still present"
        return 1
    fi
}
