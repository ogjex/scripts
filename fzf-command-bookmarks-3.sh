#!/usr/bin/env bash
# fzf-command-bookmarks (bash-only rewrite)
# Original: https://github.com/dzervas/fzf-command-bookmarks
#
# Source this from ~/.bashrc:   source ~/scripts/fzf-command-bookmarks.sh
#
#   Ctrl+B      save the command currently on the command line (asks for a title only)
#   Ctrl+Space  pick a bookmark with fzf and insert it at the cursor
#
# File format: one bookmark per line, "command##title"

# Only makes sense in an interactive bash
[[ $- == *i* ]] || return 0
[ -n "$BASH_VERSION" ] || return 0

export FZF_COMMAND_BOOKMARKS_FILE="${FZF_COMMAND_BOOKMARKS_FILE:-${HOME}/scripts/.fzf-command-bookmarks.txt}"
export FZF_COMMAND_BOOKMARKS_ADD="${FZF_COMMAND_BOOKMARKS_ADD:-\C-b}"
export FZF_COMMAND_BOOKMARKS_SHOW="${FZF_COMMAND_BOOKMARKS_SHOW:-\C-@}"

# --- dependency check (uses `return`, never `exit`, because this file is sourced) ---
__fzf_cb_check_dependencies() {
	local missing=() dep
	for dep in fzf; do
		command -v "$dep" > /dev/null 2>&1 || missing+=("$dep")
	done
	if [ ${#missing[@]} -gt 0 ]; then
		echo "[fzf-command-bookmarks] missing dependencies: ${missing[*]}" >&2
		return 1
	fi
}

__fzf_cb_check_dependencies || return 0

# `highlight` is optional: used for the preview if present, plain text otherwise
if command -v highlight > /dev/null 2>&1; then
	__FZF_CB_PREVIEW='echo -e {-1}; echo; echo -E {..-2} | highlight -S bash -O ansi'
else
	__FZF_CB_PREVIEW='echo -e {-1}; echo; echo -E {..-2}'
fi

# Make sure the bookmarks file exists
mkdir -p "$(dirname "$FZF_COMMAND_BOOKMARKS_FILE")" 2> /dev/null
touch "$FZF_COMMAND_BOOKMARKS_FILE" 2> /dev/null

# --- show: pick a bookmark and insert it at the cursor ---
__fzf_cb_show() {
	local selected cmd
	selected=$(fzf --delimiter '##' --height 40% --header Bookmarks --with-nth -1 \
		--preview "$__FZF_CB_PREVIEW" --preview-window=wrap --tac \
		< "$FZF_COMMAND_BOOKMARKS_FILE")

	# Cancelled with Esc / Ctrl+C -> do nothing
	[ -z "$selected" ] && return 0

	# Strip the trailing "##title"
	cmd="${selected%##*}"

	READLINE_LINE="${READLINE_LINE:0:READLINE_POINT}${cmd}${READLINE_LINE:READLINE_POINT}"
	READLINE_POINT=$(( READLINE_POINT + ${#cmd} ))
}

# --- add: save the current command line, ask only for a title ---
__fzf_cb_add() {
	local cmd="$READLINE_LINE" title

	if [ -z "${cmd//[[:space:]]/}" ]; then
		printf '\n[fzf-command-bookmarks] command line is empty, nothing to save\n'
		return 0
	fi

	# Ask for the title with a tiny fzf prompt (no nested readline, so the
	# current command line is never executed). Enter = save, Esc = cancel.
	title=$(fzf --print-query --height 4 --no-info --prompt "Bookmark title: " \
		--header "$cmd" --header-first < /dev/null)
	local rc=$?
	if [ "$rc" -eq 130 ]; then
		printf '\n[fzf-command-bookmarks] cancelled\n'
		return 0
	fi
	title="${title%%$'\n'*}"

	# No title typed -> use the command itself
	[ -z "$title" ] && title="$cmd"
	printf '\n'

	printf '%s##%s\n' "$cmd" "$title" >> "$FZF_COMMAND_BOOKMARKS_FILE"
	printf '[fzf-command-bookmarks] saved\n'
}

# --- key bindings ---
# The add key runs the function, then redraws the prompt (the title prompt moves the cursor).
bind -x '"\C-x9": __fzf_cb_add'
bind    '"\C-x8": redraw-current-line'
bind "\"$FZF_COMMAND_BOOKMARKS_ADD\": \"\\C-x9\\C-x8\""
bind -x "\"$FZF_COMMAND_BOOKMARKS_SHOW\": __fzf_cb_show"
