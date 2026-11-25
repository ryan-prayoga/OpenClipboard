#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
app="$HOME/Applications/OpenClipboard.app"
executable="$app/Contents/MacOS/OpenClipboard"
identity=$(security find-identity -v -p codesigning |
    awk '/"OpenClipboard Local Code Signing"/ { print $2; exit }')
: "${identity:?Create or import the OpenClipboard Local Code Signing identity first}"

# Keep the release page available through the app's existing check, while
# leaving installation to this script so a public DMG cannot replace the signer.
unset OPENCLIPBOARD_SPARKLE_DIR OPENCLIPBOARD_UPDATE_PUBLIC_KEY OPENCLIPBOARD_NOTARY_PROFILE
OPENCLIPBOARD_LOCAL_SIGNING=1 OPENCLIPBOARD_SIGNING_IDENTITY="$identity" ./scripts/build-app.sh

requirement="identifier \"dev.ryanprayoga.openclipboard\" and certificate leaf = H\"$identity\""
mkdir -p "$HOME/Applications"
stage=$(mktemp -d "$HOME/Applications/.openclipboard-local-update.XXXXXXXX")
staged="$stage/OpenClipboard.app"
ditto dist/OpenClipboard.app "$staged"
codesign --verify --strict -R="$requirement" "$staged"

pid=$(pgrep -fx "$executable" || true)
if [ -n "$pid" ]; then
    kill -TERM "$pid"
    remaining=30
    while kill -0 "$pid" 2>/dev/null; do
        [ "$remaining" -gt 0 ] || exit 1
        remaining=$((remaining - 1))
        sleep 0.1
    done
fi

if [ -d "$app" ]; then
    mv "$app" "$stage/previous.app"
fi
if ! mv "$staged" "$app" || ! open "$app"; then
    if [ -d "$app" ]; then mv "$app" "$staged"; fi
    if [ -d "$stage/previous.app" ]; then
        mv "$stage/previous.app" "$app"
        open "$app"
    fi
    exit 1
fi
codesign --verify --strict -R="$requirement" "$app"
