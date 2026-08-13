#!/bin/bash
# Mole - Steam launcher detection
#
# Steam's "create desktop shortcut" writes a tiny shell launcher that only
# opens `steam://run/<appid>`. Its bundle size is the launcher's size, not
# the installed game, so Mole labels these apps as Steam-managed instead of
# presenting the shortcut size as the removable application size.

set -euo pipefail

# Prevent multiple sourcing
if [[ -n "${MOLE_STEAM_UNINSTALL_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_STEAM_UNINSTALL_LOADED=1

# Print the Steam app id referenced by a Steam-generated launcher bundle, or
# return 1 when the bundle does not look like one.
uninstall_steam_launcher_appid() {
    local app_path="${1:-}"
    [[ -n "$app_path" && -d "$app_path" ]] || return 1

    local exec_name=""
    local plist="$app_path/Contents/Info.plist"
    if [[ -f "$plist" ]]; then
        exec_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2> /dev/null || true)
    fi
    if [[ -z "$exec_name" ]]; then
        exec_name="${app_path##*/}"
        exec_name="${exec_name%.app}"
    fi

    local script="$app_path/Contents/MacOS/$exec_name"
    [[ -f "$script" && -r "$script" ]] || return 1

    # Steam launchers are generated shell scripts. Requiring a shebang keeps
    # this from matching a Mach-O binary that merely embeds a steam:// URL.
    local shebang
    shebang=$(head -c 64 "$script" 2> /dev/null | LC_ALL=C grep -a '^#!' || true)
    [[ -n "$shebang" ]] || return 1

    local appid
    appid=$(head -c 4096 "$script" 2> /dev/null | LC_ALL=C grep -aoE 'steam://(run|rungameid|launch)/[0-9]+' | head -n 1 | grep -oE '[0-9]+$' || true)
    [[ "$appid" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$appid"
}

# True when app_path is a Steam-generated launcher whose bundle size is not
# the installed game size.
uninstall_app_is_steam_launcher() {
    local app_path="${1:-}"
    uninstall_steam_launcher_appid "$app_path" > /dev/null 2>&1
}
