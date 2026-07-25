#!/bin/sh

event=${1:-}
if [ -z "$event" ]; then
    exit 0
fi

script_directory=$(CDPATH= cd -- "$(/usr/bin/dirname -- "$0")" && /bin/pwd)
tty_name=$(/bin/ps -o tty= -p "$PPID" 2>/dev/null | /usr/bin/tr -d ' ')
case "$tty_name" in
    ""|"??") ATALAIA_TTY="" ;;
    /dev/*) ATALAIA_TTY=$tty_name ;;
    *) ATALAIA_TTY="/dev/$tty_name" ;;
esac
export ATALAIA_TTY

# O PermissionRequest é o único evento que devolve alguma coisa: o processo
# fica a bloquear enquanto esperas, e o que sair no stdout é lido pelo Claude
# Code como a decisão. Todos os outros continuam fire-and-forget, que é mais
# rápido e não tem como atrasar um agente.
if [ "$event" = "PermissionRequest" ]; then
    "$script_directory/atalaia" hook claude "$event" --pid "$PPID" 2>/dev/null || true
    exit 0
fi

"$script_directory/atalaia" hook claude "$event" --pid "$PPID" >/dev/null 2>&1 || true
exit 0
