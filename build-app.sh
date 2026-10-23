#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
APP_OUTPUT="${1:-$PWD/dist}"
mkdir -p "$APP_OUTPUT" .build/icon.iconset
APP_OUTPUT="$(cd "$APP_OUTPUT" && pwd)"
# SwiftPM embeds its resource bundle build path. Keep release scratch paths
# independent of the developer's home directory, and remove them on exit.
STAGING_DIR="$(mktemp -d /private/tmp/restoredock-release.XXXXXX)"
trap 'rm -rf "$STAGING_DIR"' EXIT
for architecture in arm64 x86_64; do
    swift build --disable-sandbox --build-system native --cache-path "$PWD/.build/cache" --configuration release --triple "$architecture-apple-macosx14.0" --scratch-path "$STAGING_DIR/$architecture" --product RestoreDock
done
APP="$STAGING_DIR/RestoreDock.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$STAGING_DIR/arm64/arm64-apple-macosx/release/RestoreDock" "$STAGING_DIR/x86_64/x86_64-apple-macosx/release/RestoreDock" -output "$APP/Contents/MacOS/RestoreDock"
# Debug information includes absolute source paths and is not needed at runtime.
strip -S "$APP/Contents/MacOS/RestoreDock"
cp Resources/Info.plist "$APP/Contents/Info.plist"
ditto Sources/RestoreDock/Resources/DevicePhotos "$APP/Contents/Resources/DevicePhotos"
swift Resources/MakeIcon.swift "$PWD/.build/icon.iconset" "$APP/Contents/Resources/AppIcon.icns"
xattr -cr "$APP"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGING_DIR/RestoreDock-macOS.zip"
# Sign and archive outside cloud-synced folders, whose file-provider metadata can
# change between removing extended attributes and the codesign operation.
rm -rf "$APP_OUTPUT/RestoreDock.app"
ditto "$APP" "$APP_OUTPUT/RestoreDock.app"
cp "$STAGING_DIR/RestoreDock-macOS.zip" "$APP_OUTPUT/RestoreDock-macOS.zip"
printf 'Built %s\n' "$APP_OUTPUT/RestoreDock.app"
