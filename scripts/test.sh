#!/bin/bash
# Runs the test suite. Works with full Xcode or with only the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."

developer_dir="$(xcode-select -p)"
if [[ "$developer_dir" == *CommandLineTools* ]]; then
    # Without Xcode, Swift Testing lives in a folder the compiler doesn't search by default.
    frameworks="$developer_dir/Library/Developer/Frameworks"
    libs="$developer_dir/Library/Developer/usr/lib"
    exec swift test \
        -Xswiftc -F -Xswiftc "$frameworks" \
        -Xlinker -F -Xlinker "$frameworks" \
        -Xlinker -rpath -Xlinker "$frameworks" \
        -Xlinker -rpath -Xlinker "$libs" \
        "$@"
fi
exec swift test "$@"
