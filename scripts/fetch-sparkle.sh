#!/bin/sh
set -eu

destination=${1:?Usage: fetch-sparkle.sh destination}
version=2.10.1
archive="Sparkle-$version.tar.xz"
digest=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
mkdir -p "$destination"
curl --fail --silent --show-error --location --retry 2 --max-time 120 \
    "https://github.com/sparkle-project/Sparkle/releases/download/$version/$archive" \
    -o "$destination/$archive"
printf '%s  %s\n' "$digest" "$destination/$archive" | shasum -a 256 -c -
tar -xf "$destination/$archive" -C "$destination"
