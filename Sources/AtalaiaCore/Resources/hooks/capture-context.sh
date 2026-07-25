#!/bin/sh

cwd=${1:-"$PWD"}
tool=${2:-agent}
process_id=${3:-"$PPID"}
term_program=${TERM_PROGRAM:-}
iterm_session_id=${ITERM_SESSION_ID:-}
tmux_pane=${TMUX_PANE:-}
# O cmux embute o Ghostty e anuncia-se TERM_PROGRAM=ghostty, por isso o
# programa não o identifica. Estes ids identificam, e ainda apontam para o
# painel exato — dois splits do mesmo repositório têm a mesma diretoria.
cmux_surface_id=${CMUX_SURFACE_ID:-${CMUX_PANEL_ID:-}}
cmux_tab_id=${CMUX_TAB_ID:-${CMUX_WORKSPACE_ID:-}}
tty_name=$(/bin/ps -o tty= -p "$process_id" 2>/dev/null | /usr/bin/tr -d ' ')
case "$tty_name" in
    ""|"??") tty_path="" ;;
    /dev/*) tty_path=$tty_name ;;
    *) tty_path="/dev/$tty_name" ;;
esac
project_name=${cwd##*/}

/usr/bin/osascript -l JavaScript - \
    "$term_program" \
    "$iterm_session_id" \
    "$tmux_pane" \
    "$tty_path" \
    "$cmux_surface_id" \
    "$cmux_tab_id" \
    "$project_name — $tool" <<'JAVASCRIPT' 2>/dev/null || true
function optional(value) {
    return value === "" ? null : value;
}

function run(arguments) {
    return JSON.stringify({
        term_program: optional(arguments[0]),
        iterm_session_id: optional(arguments[1]),
        tmux_pane: optional(arguments[2]),
        tty: optional(arguments[3]),
        cmux_surface_id: optional(arguments[4]),
        cmux_tab_id: optional(arguments[5]),
        window_title_hint: optional(arguments[6])
    });
}
JAVASCRIPT

exit 0
