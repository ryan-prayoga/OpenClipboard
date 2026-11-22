#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
bundle=dist/OpenClipboard.app
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle/Contents/Info.plist")
asset="OpenClipboard-$version-arm64.dmg"
binary="$bundle/Contents/MacOS/OpenClipboard"
test "$(lipo -archs "$binary")" = arm64
codesign --verify --strict --deep "$bundle"

stage=$(mktemp -d "$PWD/dist/.dmg.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/volume"
ditto "$bundle" "$stage/volume/OpenClipboard.app"
ln -s /Applications "$stage/volume/Applications"

hdiutil create -fs HFS+ -format UDZO -volname OpenClipboard \
    -srcfolder "$stage/volume" "$stage/$asset"
hdiutil verify "$stage/$asset"
(
    cd "$stage"
    shasum -a 256 "$asset" > "$asset.sha256"
)
mv "$stage/$asset" "$stage/$asset.sha256" dist/
