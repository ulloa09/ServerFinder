#!/bin/bash
# Builds build/ServerFinder.app. Pass --install to also copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64
bin_dir="$(swift build -c release --arch arm64 --show-bin-path)"

app="build/ServerFinder.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/ServerFinder" "$app/Contents/MacOS/"
cp Resources/Info.plist "$app/Contents/"
cp -R Resources/*.lproj "$app/Contents/Resources/"
# Ad-hoc signature: enough to run on this Mac.
codesign --force --sign - "$app"
echo "Built $app"

if [[ "${1:-}" == "--install" ]]; then
    osascript -e 'quit app "ServerFinder"' 2>/dev/null || true
    rm -rf /Applications/ServerFinder.app
    cp -R "$app" /Applications/
    echo "Installed /Applications/ServerFinder.app"
fi
