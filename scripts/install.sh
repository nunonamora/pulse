#!/bin/sh
# One-command install (and reinstall) for Pulse.
#
#   ./scripts/install.sh
#
# Builds the app, replaces any previous copy in /Applications, wires the
# agent hooks, relaunches the app, and verifies the result with
# `pulse doctor`. Safe to re-run at any time.
set -eu

cd "$(dirname "$0")/.."

step() { /usr/bin/printf '\n==> %s\n' "$1"; }

step "Building Pulse (release)"
./scripts/build-app.sh

app_destination="/Applications/Pulse.app"
if [ ! -w "/Applications" ]; then
    app_destination="$HOME/Applications/Pulse.app"
    /bin/mkdir -p "$HOME/Applications"
fi

step "Stopping the running instance (if any)"
if /usr/bin/pgrep -x Pulse >/dev/null 2>&1; then
    /usr/bin/pkill -x Pulse
    attempts=0
    while /usr/bin/pgrep -x Pulse >/dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 20 ]; then
            /usr/bin/printf 'error: Pulse did not exit; close it and re-run.\n' >&2
            exit 1
        fi
        /bin/sleep 0.25
    done
    /usr/bin/printf 'stopped.\n'
else
    /usr/bin/printf 'not running.\n'
fi

step "Installing app to $app_destination"
/bin/rm -rf "$app_destination"
/usr/bin/ditto .build/Pulse.app "$app_destination"

# Reregistar no LaunchServices.
#
# Sem isto o sistema continua a servir o ícone antigo de cache, e neste projeto
# isso foi difícil de diagnosticar: o mesmo caminho em /Applications já teve
# três nomes diferentes. O .icns no pacote estava certo e o que aparecia era
# outro — cheguei a acusar o invólucro de compatibilidade do macOS 26 antes de
# perceber que era cache.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$app_destination" 2>/dev/null || true

step "Wiring agent hooks (Claude Code / OpenCode / Codex / Pi)"
"$app_destination/Contents/Resources/bin/pulse" install

step "Launching Pulse"
/usr/bin/open "$app_destination"
attempts=0
until /usr/bin/pgrep -x Pulse >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 20 ]; then
        /usr/bin/printf 'error: Pulse did not appear after launch.\n' >&2
        exit 1
    fi
    /bin/sleep 0.25
done
/usr/bin/printf '✓ app running (pid %s)\n' "$(/usr/bin/pgrep -x Pulse)"

step "Verifying installation (pulse doctor)"
"$app_destination/Contents/Resources/bin/pulse" doctor

/usr/bin/printf '\nAll good. Agents already running must be restarted to pick up the hooks.\n'
/usr/bin/printf 'OpenCode loads plugins in its background service: also run\n'
/usr/bin/printf '  pkill -f "opencode2 serve" (a fresh one starts with the next opencode)\n'
