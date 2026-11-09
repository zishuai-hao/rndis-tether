#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
gui_build="$PWD/build/gui"
gui_app="$gui_build/RNDIS Tether.app"
mkdir -p "$gui_build"
rm -rf "$gui_app"
mkdir -p "$gui_app/Contents/MacOS" "$gui_app/Contents/Resources"
gui_sdk="$(xcrun --show-sdk-path)"

for gui_arch in arm64 x86_64; do
    xcrun swiftc -swift-version 5 -warnings-as-errors -parse-as-library -O \
        -sdk "$gui_sdk" -target "$gui_arch-apple-macosx13.0" \
        gui/Shared.swift gui/DemandPreferences.swift gui/ClashControl.swift gui/TrustedPaths.swift gui/PhoneStatus.swift gui/HTTPSProbe.swift gui/Helper.swift \
        -o "$gui_build/helper-$gui_arch"
    xcrun swiftc -swift-version 5 -warnings-as-errors -parse-as-library -O \
        -sdk "$gui_sdk" -target "$gui_arch-apple-macosx13.0" \
        gui/Shared.swift gui/DemandPreferences.swift gui/ClashControl.swift gui/DemandModel.swift gui/App.swift -o "$gui_build/app-$gui_arch"
done
lipo -create "$gui_build/helper-arm64" "$gui_build/helper-x86_64" -output "$gui_app/Contents/Resources/rndis-tether-gui-helper"
lipo -create "$gui_build/app-arm64" "$gui_build/app-x86_64" -output "$gui_app/Contents/MacOS/RNDISTetherGUI"

# Build the same C sources without debug records containing local source paths.
make dist
cp dist/pkg/rndis-tether "$gui_app/Contents/Resources/rndis-tether"
codesign --remove-signature "$gui_app/Contents/Resources/rndis-tether"
strip -S "$gui_app/Contents/Resources/rndis-tether"
cp gui/Info.plist "$gui_app/Contents/Info.plist"
cp LICENSE "$gui_app/Contents/Resources/LICENSE.txt"
cp gui/README.md "$gui_app/Contents/Resources/README.md"

xcrun swiftc -swift-version 5 gui/Icon.swift -o "$gui_build/draw-icon"
"$gui_build/draw-icon" "$gui_build/icon.png"
mkdir -p "$gui_build/AppIcon.iconset"
for gui_size in 16 32 128 256 512; do
    sips -z "$gui_size" "$gui_size" "$gui_build/icon.png" --out "$gui_build/AppIcon.iconset/icon_${gui_size}x${gui_size}.png" >/dev/null
    gui_double="$((gui_size * 2))"
    sips -z "$gui_double" "$gui_double" "$gui_build/icon.png" --out "$gui_build/AppIcon.iconset/icon_${gui_size}x${gui_size}@2x.png" >/dev/null
done
iconutil -c icns "$gui_build/AppIcon.iconset" -o "$gui_app/Contents/Resources/AppIcon.icns"
for gui_binary in "$gui_app/Contents/Resources/rndis-tether" "$gui_app/Contents/Resources/rndis-tether-gui-helper" "$gui_app/Contents/MacOS/RNDISTetherGUI"; do
    codesign --force --sign - --timestamp=none "$gui_binary"
done
codesign --force --sign - --timestamp=none "$gui_app"
codesign --verify --deep --strict "$gui_app"
plutil -lint "$gui_app/Contents/Info.plist"
"$gui_app/Contents/MacOS/RNDISTetherGUI" --smoke-test
"$gui_app/Contents/Resources/rndis-tether-gui-helper" check-system-paths
ditto -c -k --sequesterRsrc --keepParent "$gui_app" "$gui_build/RNDIS-Tether-macOS.zip"
gui_check="$(mktemp -d "$gui_build/archive-check.XXXXXX")"
trap 'rm -rf "$gui_check"' EXIT
ditto -x -k "$gui_build/RNDIS-Tether-macOS.zip" "$gui_check"
codesign --verify --deep --strict "$gui_check/RNDIS Tether.app"
"$gui_check/RNDIS Tether.app/Contents/MacOS/RNDISTetherGUI" --smoke-test
"$gui_check/RNDIS Tether.app/Contents/Resources/rndis-tether-gui-helper" check-system-paths
printf '%s\n' "$gui_app" "$gui_build/RNDIS-Tether-macOS.zip"
