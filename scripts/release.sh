#!/bin/bash
# Builds the downloadable app: build/ServerFinder.dmg, for Apple silicon and Intel Macs.
# Usage: scripts/release.sh 1.2.0
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:?Usage: scripts/release.sh <version, e.g. 1.2.0>}"
ARCHS="arm64 x86_64" VERSION="$version" scripts/build-app.sh

# A disk image with the app and a shortcut to Applications, to drag it into.
staging="build/dmg"
rm -rf "$staging" build/ServerFinder.dmg
mkdir -p "$staging"
cp -R build/ServerFinder.app "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "ServerFinder $version" -srcfolder "$staging" -fs HFS+ -format UDZO -ov build/ServerFinder.dmg >/dev/null
rm -rf "$staging"

# Always the same file name, so the "latest release" download link never changes.
shasum -a 256 build/ServerFinder.dmg | tee build/ServerFinder.dmg.sha256
echo "Built build/ServerFinder.dmg ($version)"
