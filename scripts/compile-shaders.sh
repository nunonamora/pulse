#!/bin/sh
# Recompiles the SwiftUI layer-effect shaders into the prebuilt metallib the
# package ships as a resource. swift build cannot compile Metal sources, so
# run this after editing Sources/AtalaiaApp/Ripple.metal and commit the
# regenerated default.metallib alongside it.
#
# Requires the Metal toolchain: xcodebuild -downloadComponent MetalToolchain
set -eu

cd "$(dirname "$0")/.."
mkdir -p Sources/AtalaiaApp/Resources
xcrun -sdk macosx metal \
    Sources/AtalaiaApp/Ripple.metal \
    -o Sources/AtalaiaApp/Resources/default.metallib
echo "Wrote Sources/AtalaiaApp/Resources/default.metallib"
