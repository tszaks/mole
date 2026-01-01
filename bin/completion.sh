#!/bin/bash

case "$1" in
    bash)
        cat << 'EOF'
_mole_completions()
{
    local cur_word prev_word
    cur_word="${COMP_WORDS[COMP_CWORD]}"
    prev_word="${COMP_WORDS[COMP_CWORD-1]}"

    if [ "$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=( $(compgen -W "optimize clean uninstall analyze status purge touchid update remove help version completion" -- "$cur_word") )
    else
        case "$prev_word" in
            completion)
                COMPREPLY=( $(compgen -W "bash zsh fish" -- "$cur_word") )
                ;;
            *)
                COMPREPLY=()
                ;;
        esac
    fi
}

complete -F _mole_completions mole
EOF
        ;;
    zsh)
        cat << 'EOF'
#compdef mole

_mole() {
    local -a subcommands
    subcommands=(
        'optimize:Free up disk space'
        'clean:Remove apps completely'
        'uninstall:Check and maintain system'
        'analyze:Explore disk usage'
        'status:Monitor system health'
        'purge:Remove old project artifacts'
        'touchid:Configure Touch ID for sudo'
        'update:Update to latest version'
        'remove:Remove Mole from system'
        'help:Show help'
        'version:Show version'
        'completion:Generate shell completions'
    )
    _describe 'subcommand' subcommands
}

_mole
EOF
        ;;
    fish)
        cat << 'EOF'
complete -c mole -n "__fish_mole_no_subcommand" -a optimize -d "Free up disk space"
complete -c mole -n "__fish_mole_no_subcommand" -a clean -d "Remove apps completely"
complete -c mole -n "__fish_mole_no_subcommand" -a uninstall -d "Check and maintain system"
complete -c mole -n "__fish_mole_no_subcommand" -a analyze -d "Explore disk usage"
complete -c mole -n "__fish_mole_no_subcommand" -a status -d "Monitor system health"
complete -c mole -n "__fish_mole_no_subcommand" -a purge -d "Remove old project artifacts"
complete -c mole -n "__fish_mole_no_subcommand" -a touchid -d "Configure Touch ID for sudo"
complete -c mole -n "__fish_mole_no_subcommand" -a update -d "Update to latest version"
complete -c mole -n "__fish_mole_no_subcommand" -a remove -d "Remove Mole from system"
complete -c mole -n "__fish_mole_no_subcommand" -a help -d "Show help"
complete -c mole -n "__fish_mole_no_subcommand" -a version -d "Show version"
complete -c mole -n "__fish_mole_no_subcommand" -a completion -d "Generate shell completions"

complete -c mole -n "not __fish_mole_no_subcommand" -a bash -d "generate bash completion" -n "__fish_see_subcommand_path completion"
complete -c mole -n "not __fish_mole_no_subcommand" -a zsh -d "generate zsh completion" -n "__fish_see_subcommand_path completion"
complete -c mole -n "not __fish_mole_no_subcommand" -a fish -d "generate fish completion" -n "__fish_see_subcommand_path completion"

function __fish_mole_no_subcommand
    for i in (commandline -opc)
        if contains -- $i optimize clean uninstall analyze status purge touchid update remove help version completion
            return 1
        end
    end
    return 0
end

function __fish_see_subcommand_path
    string match -q -- "completion" (commandline -opc)[1]
end
EOF
        ;;
    *)
        echo "Usage: mole completion [bash|zsh|fish]"
        exit 1
        ;;
esac
