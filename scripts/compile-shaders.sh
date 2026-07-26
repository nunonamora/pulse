#!/bin/sh
# Recompiles the SwiftUI layer-effect shaders into the prebuilt metallib the
# package ships as a resource. swift build cannot compile Metal sources, so
# run this after editing Sources/PulseApp/Ripple.metal and commit the
# regenerated default.metallib alongside it.
#
# Requires the Metal toolchain: xcodebuild -downloadComponent MetalToolchain
set -eu

cd "$(dirname "$0")/.."
mkdir -p Sources/PulseApp/Resources
xcrun -sdk macosx metal \
    Sources/PulseApp/Ripple.metal \
    -o Sources/PulseApp/Resources/default.metallib
echo "Wrote Sources/PulseApp/Resources/default.metallib"
