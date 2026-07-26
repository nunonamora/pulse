#!/bin/sh
set -eu

swift build -c release
bundle=".build/Pulse.app"
/bin/rm -rf "$bundle"
/bin/mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources/bin"
/bin/cp config/Info.plist "$bundle/Contents/Info.plist"
/bin/cp config/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
/bin/cp .build/release/PulseApp "$bundle/Contents/MacOS/Pulse"
/bin/cp .build/release/pulse "$bundle/Contents/Resources/bin/pulse"
/bin/cp -R .build/release/Pulse_PulseCore.bundle "$bundle/Contents/Resources/"
/bin/chmod 755 "$bundle/Contents/MacOS/Pulse" "$bundle/Contents/Resources/bin/pulse"
# Identidade estável em vez de ad-hoc.
#
# `codesign -s -` produz um requisito de designação que é o cdhash desta
# compilação exata, por isso cada reinstalação é, para o sistema, uma
# aplicação diferente — e as autorizações de privacidade (Gravação de Ecrã,
# Automação) são revogadas de cada vez. Um certificado self-signed dá um
# requisito estável e as autorizações sobrevivem.
#
# Cria-se uma vez com ./scripts/sign-identity.sh; sem ela, cai no ad-hoc.
sign_identity="Pulse Local Signing"
sign_keychain="$HOME/Library/Keychains/pulse-signing.keychain-db"
if /usr/bin/security find-certificate -c "$sign_identity" "$sign_keychain" >/dev/null 2>&1; then
    /usr/bin/codesign --force --deep --timestamp=none \
        --keychain "$sign_keychain" --sign "$sign_identity" "$bundle"
else
    /usr/bin/printf 'aviso: sem identidade estavel; a assinar ad-hoc (as permissoes serao revogadas a cada build)\n' >&2
    /usr/bin/codesign --force --deep --sign - "$bundle"
fi
/usr/bin/printf 'Built %s\n' "$bundle"
