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

mkdir -p "$contents_path/MacOS" "$contents_path/Resources"
cp "$binary_directory/VimAny" "$contents_path/MacOS/VimAny"
cp Support/Info.plist "$contents_path/Info.plist"

if [[ -n "${VIMANY_CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$VIMANY_CODESIGN_IDENTITY" "$bundle_path"
else
  # A default ad-hoc signature normally uses the executable's changing cdhash as
  # its designated requirement. TCC then treats every rebuild as a different app.
  # Give local development builds a stable requirement so one Accessibility grant
  # survives subsequent rebuilds at this bundle path.
  codesign \
    --force \
    --sign - \
    --identifier dev.vimany.VimAny \
    --requirements '=designated => identifier "dev.vimany.VimAny"' \
    "$bundle_path"
fi

print "$bundle_path"
