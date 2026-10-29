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
    # Stop the running copy, or it keeps running the old code after the files are replaced.
    if pkill -x ServerFinder; then
        while pgrep -x ServerFinder >/dev/null; do sleep 0.2; done
    fi
    rm -rf /Applications/ServerFinder.app
    cp -R "$app" /Applications/
    echo "Installed /Applications/ServerFinder.app"
    # Right after the old copy quits, macOS sometimes refuses the first launch (error -600).
    for _ in 1 2 3; do open /Applications/ServerFinder.app 2>/dev/null && break; sleep 1; done
fi
