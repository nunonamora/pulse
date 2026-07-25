#!/bin/sh
set -eu

swift build -c release
bundle=".build/Atalaia.app"
/bin/rm -rf "$bundle"
/bin/mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources/bin"
/bin/cp config/Info.plist "$bundle/Contents/Info.plist"
/bin/cp config/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
/bin/cp .build/release/AtalaiaApp "$bundle/Contents/MacOS/Atalaia"
/bin/cp .build/release/atalaia "$bundle/Contents/Resources/bin/atalaia"
/bin/cp -R .build/release/Atalaia_AtalaiaCore.bundle "$bundle/Contents/Resources/"
/bin/chmod 755 "$bundle/Contents/MacOS/Atalaia" "$bundle/Contents/Resources/bin/atalaia"
# Identidade estável em vez de ad-hoc.
#
# `codesign -s -` produz um requisito de designação que é o cdhash desta
# compilação exata, por isso cada reinstalação é, para o sistema, uma
# aplicação diferente — e as autorizações de privacidade (Gravação de Ecrã,
# Automação) são revogadas de cada vez. Um certificado self-signed dá um
# requisito estável e as autorizações sobrevivem.
#
# Cria-se uma vez com ./scripts/sign-identity.sh; sem ela, cai no ad-hoc.
sign_identity="Atalaia Local Signing"
sign_keychain="$HOME/Library/Keychains/atalaia-signing.keychain-db"
if /usr/bin/security find-certificate -c "$sign_identity" "$sign_keychain" >/dev/null 2>&1; then
    /usr/bin/codesign --force --deep --timestamp=none \
        --keychain "$sign_keychain" --sign "$sign_identity" "$bundle"
else
    /usr/bin/printf 'aviso: sem identidade estavel; a assinar ad-hoc (as permissoes serao revogadas a cada build)\n' >&2
    /usr/bin/codesign --force --deep --sign - "$bundle"
fi
/usr/bin/printf 'Built %s\n' "$bundle"
