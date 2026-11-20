#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
export MACOSX_DEPLOYMENT_TARGET=27.0
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
mkdir -p "$bundle/Contents/MacOS"
cp native/Info.plist "$bundle/Contents/Info.plist"
cp target/aarch64-apple-darwin/release/openclipboard "$bundle/Contents/MacOS/OpenClipboard"
codesign --force --sign "${OPENCLIPBOARD_SIGNING_IDENTITY:--}" "$bundle"
codesign --verify --strict "$bundle"

# Update the existing bundle only after a complete, verified build.
if [ -d dist/OpenClipboard.app ]; then
    mv dist/OpenClipboard.app "$stage/previous.app"
fi
mv "$bundle" dist/OpenClipboard.app
printf '%s\n' "$PWD/dist/OpenClipboard.app"
