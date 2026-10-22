#!/usr/bin/env bash
#
# bookmarks.sh - tiny clipboard-driven bookmark manager for Wayland
#
# Usage:
#   bookmarks.sh add_bookmark     save clipboard content as a bookmark
#   bookmarks.sh open_bookmark    fuzzy-search bookmarks and open the pick
#   bookmarks.sh list_bookmarks   print all bookmarks
#
# You can also `source` this file and call the functions directly.
#
# Storage format (one bookmark per line):
#   2026-10-22 14:03 | tag1-tag2-tag3 | https://example.com/page
#
# Environment:
#   BOOKMARKS_FILE   path to the bookmark file (default: ~/.local/share/bookmarks.txt)
#   BOOKMARKS_UI     "fzf" (terminal) or "menu" (graphical launcher).
#                    Default: fzf when run from a terminal, otherwise menu.
#   BOOKMARKS_MENU   launcher command for menu mode, must read lines on stdin and
#                    print the selection on stdout. Auto-detects fuzzel, wofi,
#                    bemenu, rofi, tofi, wmenu if unset.

BOOKMARKS_FILE="${BOOKMARKS_FILE:-$HOME/.local/share/bookmarks.txt}"

# ---------------------------------------------------------------- helpers ---

_have() { command -v "$1" >/dev/null 2>&1; }

_notify() {
    # Message to terminal, and a desktop notification if available
    printf '%s\n' "$*" >&2
    _have notify-send && notify-send "Bookmarks" "$*" 2>/dev/null
    return 0
}

_need() {
    local missing=0 cmd
    for cmd in "$@"; do
        if ! _have "$cmd"; then
            printf 'Missing dependency: %s\n' "$cmd" >&2
            missing=1
        fi
    done
    return "$missing"
}

_menu_cmd() {
    # Echo the graphical menu command to use (as a string)
    if [[ -n "${BOOKMARKS_MENU:-}" ]]; then
        printf '%s' "$BOOKMARKS_MENU"
    elif _have fuzzel; then printf 'fuzzel --dmenu'
    elif _have wofi;   then printf 'wofi --dmenu -i'
    elif _have bemenu; then printf 'bemenu -i'
    elif _have tofi;   then printf 'tofi'
    elif _have wmenu;  then printf 'wmenu'
    elif _have rofi;   then printf 'rofi -dmenu -i'
    else return 1
    fi
}

_pick() {
    # Read candidate lines on stdin, print the chosen one on stdout
    local ui="${BOOKMARKS_UI:-}"
    if [[ -z "$ui" ]]; then
        if [[ -t 0 || -t 2 ]] && [[ -t 1 || -n "${TERM:-}" ]] && [[ -t 2 ]]; then
            ui=fzf
        else
            ui=menu
        fi
    fi

    if [[ "$ui" == "fzf" ]]; then
        _need fzf || return 1
        fzf --prompt='bookmark> ' --height=60% --reverse \
            --delimiter=' \| ' --tac --no-sort
    else
        local cmd
        cmd="$(_menu_cmd)" || {
            _notify "No graphical menu found (install fuzzel, wofi, bemenu, ...)"
            return 1
        }
        # shellcheck disable=SC2086  # intentional word splitting of the command
        $cmd
    fi
}

# -------------------------------------------------------------- functions ---

add_bookmark() {
    _need wl-paste || return 1

    local content
    content="$(wl-paste --no-newline 2>/dev/null)"

    if [[ -z "${content//[[:space:]]/}" ]]; then
        _notify "Clipboard is empty (or holds non-text data)."
        return 1
    fi

    # Bookmarks are one per line: collapse newlines/tabs/runs of whitespace
    content="$(printf '%s' "$content" | tr '\n\t\r' '   ' | sed -E 's/ +/ /g; s/^ //; s/ $//')"
    # Keep our " | " delimiter unambiguous
    content="${content// | / }"

    printf '\nClipboard content:\n  %s\n' "$content"

    if [[ ! "$content" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*:// ]]; then
        printf '  (note: this does not look like a URL with a scheme, e.g. https://)\n'
    fi

    # Duplicate check
    if [[ -f "$BOOKMARKS_FILE" ]] && grep -qF -- " | $content" "$BOOKMARKS_FILE"; then
        local ans
        read -rp "This is already bookmarked. Add again? [y/N] " ans
        [[ "$ans" =~ ^[Yy]$ ]] || { printf 'Cancelled.\n'; return 0; }
    fi

    local tags
    read -rp "Tags (separated by -, e.g. linux-wayland-howto): " tags

    # Normalise: lowercase, spaces/commas/pipes -> dash, squeeze dashes, trim
    tags="$(printf '%s' "$tags" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -s ' ,|' '-' \
        | sed -E 's/-+/-/g; s/^-//; s/-$//')"
    [[ -z "$tags" ]] && tags="untagged"

    mkdir -p "$(dirname "$BOOKMARKS_FILE")" || return 1
    printf '%s | %s | %s\n' "$(date '+%Y-%m-%d %H:%M')" "$tags" "$content" >> "$BOOKMARKS_FILE"

    _notify "Saved [$tags] $content"
}

list_bookmarks() {
    if [[ ! -s "$BOOKMARKS_FILE" ]]; then
        printf 'No bookmarks yet (%s)\n' "$BOOKMARKS_FILE" >&2
        return 1
    fi
    cat -- "$BOOKMARKS_FILE"
}

open_bookmark() {
    if [[ ! -s "$BOOKMARKS_FILE" ]]; then
        _notify "No bookmarks yet. Add one with: add_bookmark"
        return 1
    fi

    local selection
    selection="$(_pick < "$BOOKMARKS_FILE")" || return 1
    [[ -z "$selection" ]] && return 0   # cancelled

    # Target is everything after the second " | "
    local target="${selection#* | }"
    target="${target#* | }"

    if [[ -z "$target" ]]; then
        _notify "Could not parse bookmark: $selection"
        return 1
    fi

    # Bare domains (example.com/foo) -> assume https
    if [[ ! "$target" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*:// ]] && [[ "$target" =~ ^[^[:space:]]+\.[a-zA-Z]{2,}(/.*)?$ ]]; then
        target="https://$target"
    fi

    _need xdg-open || return 1
    nohup xdg-open "$target" >/dev/null 2>&1 &
    disown 2>/dev/null
}

# ------------------------------------------------------------------- main ---

# Only dispatch when executed, not when sourced
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        add_bookmark|add)     add_bookmark ;;
        open_bookmark|open)   open_bookmark ;;
        list_bookmarks|list)  list_bookmarks ;;
        *)
            cat >&2 <<EOF
Usage: ${0##*/} {add_bookmark|open_bookmark|list_bookmarks}

  add_bookmark     save clipboard content (via wl-paste) with tags
  open_bookmark    fuzzy-search bookmarks (fzf or graphical menu) and open in default browser
  list_bookmarks   print all bookmarks

File: $BOOKMARKS_FILE
EOF
            exit 1
            ;;
    esac
fi
