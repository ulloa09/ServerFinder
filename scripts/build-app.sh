#!/bin/bash
# Builds build/ServerFinder.app. Pass --install to also copy it to /Applications.
# ARCHS="arm64 x86_64" builds one app for Apple silicon and Intel Macs; VERSION=1.2.0 stamps
# that version into the app (both are set by scripts/release.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

read -r -a archs <<< "${ARCHS:-arm64}"
binaries=()
for arch in "${archs[@]}"; do
    swift build -c release --arch "$arch"
    binaries+=("$(swift build -c release --arch "$arch" --show-bin-path)/ServerFinder")
done

app="build/ServerFinder.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/ServerFinder"
cp Resources/Info.plist "$app/Contents/"
if [[ -n "${VERSION:-}" ]]; then
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$app/Contents/Info.plist"
    # The build number only has to grow; the commit count does.
    plutil -replace CFBundleVersion -string "$(git rev-list --count HEAD)" "$app/Contents/Info.plist"
fi
cp -R Resources/*.lproj Resources/*.icns "$app/Contents/Resources/"
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
