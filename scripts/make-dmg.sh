#!/bin/sh
# Empacota a Pulse num instalador .dmg com cara de produto.
#
# O caminho é o clássico dos DMGs bonitos, e não há atalho para ele: cria-se
# uma imagem de LEITURA-ESCRITA, monta-se, pede-se ao Finder para arrumar a
# janela (é o Finder quem escreve o .DS_Store com o layout — nenhuma outra
# ferramenta escreve esse formato de forma fiável), desmonta-se, e só então se
# converte para UDZO comprimido e só-de-leitura. Quem abrir o dmg final vê a
# janela exatamente como o Finder a deixou aqui.
#
# Uso: ./scripts/make-dmg.sh          →  dist/Pulse-<versão>.dmg
set -eu
cd "$(dirname "$0")/.."

volume_name="Pulse"
background="assets/dmg-background.png"
sign_identity="Pulse Local Signing"
sign_keychain="$HOME/Library/Keychains/pulse-signing.keychain-db"

step() { /usr/bin/printf '\033[1m==> %s\033[0m\n' "$1"; }

# A versão vem do Info.plist e de mais lado nenhum: o nome do ficheiro tem de
# dizer a verdade sobre o que está lá dentro, e a única verdade é a do bundle.
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' config/Info.plist)
out_dmg="dist/Pulse-$version.dmg"

# -- limpeza defensiva ------------------------------------------------------
# Uma execução anterior que falhou a meio pode ter deixado o volume montado, e
# um "Pulse" já montado faria o hdiutil montar este como "Pulse 1" — com o
# AppleScript a arrumar a janela do volume errado. Desmonta-se tudo o que se
# pareça connosco antes de começar.
step "A limpar montagens anteriores"
for vol in "/Volumes/$volume_name" "/Volumes/$volume_name "*; do
    if [ -d "$vol" ]; then
        /usr/bin/hdiutil detach "$vol" -force -quiet 2>/dev/null || true
    fi
done

step "A construir a app"
./scripts/build-app.sh

# O fundo está commitado (assets/dmg-background.png) para o empacotamento não
# depender de um passo de desenho; só se regenera se faltar. Para o refazer
# de propósito: swift scripts/make-dmg-background.swift assets/dmg-background.png
if [ ! -f "$background" ]; then
    step "Fundo em falta; a desenhar"
    /usr/bin/swift scripts/make-dmg-background.swift "$background"
fi

# -- staging ----------------------------------------------------------------
# O staging é a raiz do volume, tal e qual: a app, o atalho, e o fundo numa
# pasta escondida (o .DS_Store que o Finder vai escrever aponta lá para
# dentro). O ícone do volume NÃO entra aqui — ver mais abaixo porquê.
step "A preparar o conteúdo do volume"
work=$(/usr/bin/mktemp -d)
mount_point=""   # preenchido no attach; o trap corre mesmo que se falhe antes
trap '{ [ -n "$mount_point" ] && /usr/bin/hdiutil detach "$mount_point" -force -quiet 2>/dev/null; } || true; /bin/rm -rf "$work"' EXIT
staging="$work/staging"
/bin/mkdir -p "$staging/.background"
/bin/cp -R .build/Pulse.app "$staging/Pulse.app"
/bin/ln -s /Applications "$staging/Applications"
/bin/cp "$background" "$staging/.background/dmg-background.png"

# -- imagem de escrita ------------------------------------------------------
# Tamanho a mão em vez do automático: o hdiutil dimensiona a imagem à justa
# para o srcfolder, e ainda vai ser preciso espaço para o .DS_Store do layout
# e para o .VolumeIcon.icns que se escreve depois. 24 MB de folga não pesam
# nada — o convert final só guarda os blocos usados.
step "A criar a imagem temporária"
size_mb=$(( $(/usr/bin/du -sm "$staging" | /usr/bin/cut -f1) + 24 ))
rw_dmg="$work/Pulse-rw.dmg"
/usr/bin/hdiutil create -srcfolder "$staging" -volname "$volume_name" \
    -fs HFS+ -format UDRW -size "${size_mb}m" -ov -quiet "$rw_dmg"

step "A montar para arrumar a janela"
mount_point=$(/usr/bin/hdiutil attach "$rw_dmg" -noautoopen | /usr/bin/grep -o '/Volumes/.*')
# O nome real do disco vem do ponto de montagem, não do que pedimos: se apesar
# da limpeza houver colisão, o AppleScript fala com o volume certo na mesma.
disk_name=$(/usr/bin/basename "$mount_point")

# -- layout via Finder ------------------------------------------------------
# As posições são centros de ícone em coordenadas da janela (origem no canto
# superior esquerdo) e têm de casar com o desenho do fundo: 660×420, app a
# (165,185), Applications a (495,185) — os mesmos números que o
# make-dmg-background.swift usa para pôr os halos, a seta e o texto.
# Esconder a toolbar esconde também a barra lateral: uma janela de Finder sem
# toolbar é só o conteúdo, que é o que um instalador deve ser.
step "A arrumar a janela no Finder"
/usr/bin/osascript <<EOF
tell application "Finder"
    tell disk "$disk_name"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 540}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 12
        set background picture of opts to file ".background:dmg-background.png"
        set position of item "Pulse.app" of container window to {165, 185}
        set position of item "Applications" of container window to {495, 185}
        -- Fechar e reabrir força o Finder a gravar já o .DS_Store; sem isto o
        -- layout ainda vivia em memória quando o volume fosse desmontado.
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF

# -- ícone do volume --------------------------------------------------------
# SÓ DEPOIS do Finder: verificado nesta máquina (macOS 26) que o passo de
# layout apaga um .VolumeIcon.icns existente e limpa o bit de ícone próprio
# ao escrever o .DS_Store. Escrito agora, sobrevive ao detach e ao convert.
# O .icns é o da app (produto do scripts/make-icon.swift): o dmg pousado na
# Secretária deve ler-se como a app que traz dentro.
step "A pôr o ícone do volume"
/bin/cp config/AppIcon.icns "$mount_point/.VolumeIcon.icns"
# O ficheiro sozinho não chega — o Finder só olha para ele se o atributo
# de "ícone próprio" estiver ligado na raiz do volume.
if command -v SetFile >/dev/null 2>&1; then
    SetFile -a C "$mount_point"
else
    # Sem as Command Line Tools não há SetFile; escreve-se o FinderInfo à mão
    # (0x0400 = kHasCustomIcon, no par de bytes 8–9 dos 32 do atributo).
    /usr/bin/xattr -wx com.apple.FinderInfo \
        "0000000000000000040000000000000000000000000000000000000000000000" \
        "$mount_point"
fi
/bin/sync
/bin/sleep 1

# O detach falha se o Finder ainda tiver o volume ocupado; insiste-se com
# calma antes de recorrer à força.
step "A desmontar"
detached=0
for attempt in 1 2 3 4 5; do
    if /usr/bin/hdiutil detach "$mount_point" -quiet 2>/dev/null; then
        detached=1
        break
    fi
    /bin/sleep 1
done
if [ "$detached" -eq 0 ]; then
    /usr/bin/hdiutil detach "$mount_point" -force -quiet
fi

# -- compressão e assinatura ------------------------------------------------
step "A comprimir para $out_dmg"
/bin/mkdir -p dist
/bin/rm -f "$out_dmg"
/usr/bin/hdiutil convert "$rw_dmg" -format UDZO -imagekey zlib-level=9 \
    -o "$out_dmg" -quiet

# A mesma identidade da app (ver build-app.sh): a assinatura do dmg dá-lhe um
# requisito de designação estável. Sem a identidade não se falha — o dmg fica
# por assinar, tal como a app fica ad-hoc.
if /usr/bin/security find-certificate -c "$sign_identity" "$sign_keychain" >/dev/null 2>&1; then
    step "A assinar o dmg"
    /usr/bin/codesign --force --timestamp=none \
        --keychain "$sign_keychain" --sign "$sign_identity" "$out_dmg"
else
    /usr/bin/printf 'aviso: sem identidade "%s"; o dmg segue sem assinatura\n' "$sign_identity" >&2
fi

step "Feito"
size=$(/usr/bin/du -h "$out_dmg" | /usr/bin/cut -f1)
/usr/bin/printf '%s  %s\n' "$out_dmg" "$size"
