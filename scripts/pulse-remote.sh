#!/bin/sh
# pulse-remote.sh — vê e aprova agentes num servidor remoto.
#
#   ./scripts/pulse-remote.sh user@servidor
#
# Monta o ~/.pulse/state do servidor num diretório local por SSHFS com
# reconexão automática, e regista-o no Pulse. As sessões remotas aparecem no
# painel com o distintivo "remote"; as aprovações escrevem-se no mesmo
# diretório montado e o hook do lado de lá apanha-as — o protocolo inteiro é
# ficheiros, e ficheiros montam-se.
#
# Requisitos no SERVIDOR: pulse instalado e hooks ligados (o mesmo
# install.sh). Requisito LOCAL: sshfs (brew install --cask macfuse && brew
# install gromgit/fuse/sshfs-mac).
set -eu

remote="${1:?uso: pulse-remote.sh user@host}"
name=$(printf '%s' "$remote" | tr -c 'A-Za-z0-9' '-')
mount_point="$HOME/.pulse/remote/$name"

mkdir -p "$mount_point"

# -o reconnect: a reconexão automática é do transporte, não da app. Os
# restantes flags mantêm o mount são sobre ligações más.
sshfs "$remote:.pulse/state" "$mount_point" \
    -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3 \
    -o volname="pulse-$name" -o defer_permissions

# Regista o diretório no Pulse (idempotente).
/usr/bin/python3 - "$mount_point" <<'PY'
import subprocess, sys
mount = sys.argv[1]
current = subprocess.run(
    ["defaults", "read", "com.pulse.app", "remoteStateDirs"],
    capture_output=True, text=True).stdout
if mount not in current:
    subprocess.run(["defaults", "write", "com.pulse.app", "remoteStateDirs",
                    "-array-add", mount], check=True)
    print(f"registado: {mount}")
else:
    print(f"já registado: {mount}")
PY

echo "Montado. As sessões remotas aparecem no próximo ciclo do Pulse (≤30 s)."
echo "Para desmontar: umount '$mount_point'"
