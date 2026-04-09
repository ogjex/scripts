#!/usr/bin/env bash
# main repo: https://github.com/dzervas/fzf-command-bookmarks

# the following two hashes do not work on nixos
# hash fzf 2> /dev/null || echo "[fzf-command-bookmarks] fzf binary not found!"
# hash highlight 2> /dev/null || echo "[fzf-command-bookmarks] highlight binary not found!"

export FZF_COMMAND_BOOKMARKS_FILE="${HOME}/scripts/.fzf-command-bookmarks.txt"
export FZF_COMMAND_BOOKMARKS_ADD="\C-b"
export FZF_COMMAND_BOOKMARKS_SHOW="\C-@"

check_dependencies() {
    local dependencies=("fzf" "highlight")  # Accept all arguments as an array
    local missing=()

    for dep in "${dependencies[@]}"; do
        if ! type -a "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo "Error: The following dependencies are missing:"
        for m in "${missing[@]}"; do
            echo "  - $m"
        done
        exit 1
    fi
    }

function get_shell() {
    if [ -n "$BASH_VERSION" ]; then
	current_shell="bash"
    elif [ -n "$ZSH_VERSION" ]; then
	current_shell="zsh"
    else
	current_shell="unknown"
    fi
}
# Readline magic helper for bash
# Found here: https://github.com/junegunn/fzf/wiki/examples#with-write-to-terminal-capabilities
function __ehc() {
	if [[ -n $1 ]]; then
		bind '"\er": redraw-rurrent-line'
		bind '"\e^": magic-space'
		READLINE_LINE=${READLINE_LINE:+${READLINE_LINE:0:READLINE_POINT}}${1}${READLINE_LINE:+${READLINE_LINE:READLINE_POINT}}
		READLINE_POINT=$(( READLINE_POINT + ${#1} ))
	else
		bind '"\er":'
		bind '"\e^":'
	fi
}

function _fzf_command_bookmark_show() {
	local result=$(cat $FZF_COMMAND_BOOKMARKS_FILE | \
		fzf --delimiter "##" --print0 --height 40% --header Bookmarks --with-nth -1 \
		--preview 'echo -e {-1}; echo; echo -E {..-2} | highlight -S bash -O ansi' \
		--preview-window=wrap --tac | sed 's/\(.*\)##.*/\1/')

	case "$current_shell" in
	    "bash")
		__ehc "$result";;
	    "zsh")
		LBUFFER="$LBUFFER$result"
		zle reset-prompt;;
	esac
}

function _fzf_command_bookmark_add() {
	local CMD="$1"
	local TITLE="$2"
	local REPLY

	if [ -z "$CMD" ]; then
	    case "$current_shell" in
		"bash")
		    autoload -Uz read-from-minibuffer
		    read-from-minibuffer "Command to add: " $LBUFFER $RBUFFER
		    CMD="$REPLY";;
		"zsh")
		    echo -en "\nCommand to add: "
		    read -er CMD;;
	    esac
	fi

	if [ -z "$TITLE" ]; then
	    case "$current_shell" in
		"zsh")
		    echo -n "Command title: "
		    read -er TITLE;;
		"bash")
		    zle -I
		    read -r "TITLE?Command title: " < /dev/tty;;
	    esac
	fi

	echo -E "${CMD}##${TITLE}" >> $FZF_COMMAND_BOOKMARKS_FILE
}

check_dependencies
get_shell
case "$current_shell" in
    "bash")
	bind -x "\"$FZF_COMMAND_BOOKMARKS_ADD\":_fzf_command_bookmark_add"
	bind -x "\"$FZF_COMMAND_BOOKMARKS_SHOW\":_fzf_command_bookmark_show";;
    "zsh")
	zle -N fzf-command-bookmark-add-widget _fzf_command_bookmark_add
	zle -N fzf-command-bookmark-show-widget _fzf_command_bookmark_show
	bindkey "$FZF_COMMAND_BOOKMARKS_ADD" fzf-command-bookmark-add-widget
	bindkey "$FZF_COMMAND_BOOKMARKS_SHOW" fzf-command-bookmark-show-widget;;
esac
