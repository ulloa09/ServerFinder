#!/bin/bash
# Regenerates the app icons from scripts/make-icon.swift:
#   Resources/AppIcon.icns      blue, the bundle icon (Finder, Spotlight) and the light-mode icon
#   Resources/AppIconDark.icns  dark, used inside the app in dark mode
#   docs/logo.png               dark, for the README
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
swiftc -O scripts/make-icon.swift -o "$work/make-icon"

for variant in blue dark; do
    iconset="$work/$variant.iconset"
    mkdir -p "$iconset"
    for size in 16 32 128 256 512; do
        "$work/make-icon" "$variant" "$iconset/icon_${size}x${size}.png" "$size"
        "$work/make-icon" "$variant" "$iconset/icon_${size}x${size}@2x.png" "$((size * 2))"
    done
    name=$([[ $variant == blue ]] && echo AppIcon || echo AppIconDark)
    iconutil --convert icns "$iconset" --output "Resources/$name.icns"
done
"$work/make-icon" dark docs/logo.png 512
echo "Wrote Resources/AppIcon.icns, Resources/AppIconDark.icns and docs/logo.png"
