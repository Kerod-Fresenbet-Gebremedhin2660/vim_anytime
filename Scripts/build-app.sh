#!/bin/zsh
set -euo pipefail

configuration="${1:-release}"
if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
  print -u2 "usage: $0 [debug|release]"
  exit 64
fi

swift build -c "$configuration" --product VimAny
binary_directory="$(swift build -c "$configuration" --show-bin-path)"
bundle_path=".build/VimAny.app"
contents_path="$bundle_path/Contents"

rm -rf "$bundle_path"
mkdir -p "$contents_path/MacOS" "$contents_path/Resources"
cp "$binary_directory/VimAny" "$contents_path/MacOS/VimAny"
cp Support/Info.plist "$contents_path/Info.plist"
codesign --force --sign - "$bundle_path"

print "$bundle_path"
