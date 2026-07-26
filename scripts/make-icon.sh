#!/bin/sh
# Regenera config/AppIcon.icns.
#
# O desenho vive em scripts/make-icon.swift e não num SVG: cada tamanho é
# desenhado para esse tamanho, com o detalhe fino a sair em miniatura. Correr
# depois de mexer no desenho e fazer commit do .icns; o build copia-o tal e qual.
set -eu
cd "$(dirname "$0")/.."
iconset="$(/usr/bin/mktemp -d)/AppIcon.iconset"
/usr/bin/swift scripts/make-icon.swift "$iconset"
/usr/bin/iconutil -c icns "$iconset" -o config/AppIcon.icns
echo "Wrote config/AppIcon.icns"
