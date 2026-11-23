#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
export MACOSX_DEPLOYMENT_TARGET=13.0
# Keep Cargo's output at a known path even when the caller has a global target-dir.
export CARGO_TARGET_DIR="$PWD/target"
cargo build --locked --release --target aarch64-apple-darwin

mkdir -p dist
stage=$(mktemp -d "$PWD/dist/.build.XXXXXXXX")
cleanup() {
    if [ -d "$stage/previous.app" ] && [ ! -e dist/OpenClipboard.app ]; then
        mv "$stage/previous.app" dist/OpenClipboard.app || return 1
    fi
    rm -rf "$stage"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

bundle="$stage/OpenClipboard.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp native/Info.plist "$bundle/Contents/Info.plist"
cp native/Resources/OpenClipboard.icns "$bundle/Contents/Resources/"
cp native/AskForPermission/LICENSE "$bundle/Contents/Resources/AskForPermission-LICENSE.txt"
cp target/aarch64-apple-darwin/release/openclipboard "$bundle/Contents/MacOS/OpenClipboard"
identity=${OPENCLIPBOARD_SIGNING_IDENTITY:--}
sign() {
    if [ "$identity" = "-" ]; then
        codesign --force --sign - "$1"
    else
        codesign --force --timestamp --options runtime --sign "$identity" "$1"
    fi
}

if [ -n "${OPENCLIPBOARD_SPARKLE_DIR:-}${OPENCLIPBOARD_UPDATE_PUBLIC_KEY:-}" ]; then
    : "${OPENCLIPBOARD_SPARKLE_DIR:?Set the extracted Sparkle distribution path}"
    : "${OPENCLIPBOARD_UPDATE_PUBLIC_KEY:?Set the Sparkle public EdDSA key}"

    mkdir -p "$bundle/Contents/Frameworks"
    framework="$bundle/Contents/Frameworks/Sparkle.framework"
    ditto "$OPENCLIPBOARD_SPARKLE_DIR/Sparkle.framework" "$framework"
    for component in "$framework"/Versions/B/XPCServices/*.xpc \
        "$framework/Versions/B/Autoupdate" "$framework/Versions/B/Updater.app" "$framework/Versions/B"; do
        [ -e "$component" ] || continue
        sign "$component"
    done

    plist="$bundle/Contents/Info.plist"
    feed_url=${OPENCLIPBOARD_APPCAST_URL:-https://github.com/ryan-prayoga/OpenClipboard/releases/latest/download/appcast.xml}
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $feed_url" "$plist"
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $OPENCLIPBOARD_UPDATE_PUBLIC_KEY" "$plist"
    /usr/libexec/PlistBuddy -c "Add :SUVerifyUpdateBeforeExtraction bool true" "$plist"
    /usr/libexec/PlistBuddy -c "Add :SURequireSignedFeed bool true" "$plist"
    /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool false" "$plist"
    /usr/libexec/PlistBuddy -c "Add :SUAllowsAutomaticUpdates bool false" "$plist"
fi
sign "$bundle"
codesign --verify --strict --deep "$bundle"

if [ -n "${OPENCLIPBOARD_NOTARY_PROFILE:-}" ]; then
    ditto -c -k --keepParent "$bundle" "$stage/notarize.zip"
    xcrun notarytool submit "$stage/notarize.zip" --keychain-profile "$OPENCLIPBOARD_NOTARY_PROFILE" --wait
    xcrun stapler staple "$bundle"
    xcrun stapler validate "$bundle"
fi

# Update the existing bundle only after a complete, verified build.
if [ -d dist/OpenClipboard.app ]; then
    mv dist/OpenClipboard.app "$stage/previous.app"
fi
mv "$bundle" dist/OpenClipboard.app
printf '%s\n' "$PWD/dist/OpenClipboard.app"
