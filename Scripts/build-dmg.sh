#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"

info_plist="$project_root/Support/Info.plist"
read_me="$project_root/Support/DMG-README.txt"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
minimum_macos="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$info_plist")"
macos_sdk="$(xcrun --sdk macosx --show-sdk-path)"
output_directory="$project_root/.build/distribution"
artifact_name="VimAny-${version}-universal"
dmg_path="$output_directory/${artifact_name}.dmg"
checksum_path="$dmg_path.sha256"
work_directory="$(mktemp -d "${TMPDIR:-/tmp}/vimany-distribution.XXXXXX")"

cleanup() {
  if [[ -n "$work_directory" && -d "$work_directory" ]]; then
    rm -rf "$work_directory"
  fi
}
trap cleanup EXIT

export CLANG_MODULE_CACHE_PATH="$work_directory/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$work_directory/swift-module-cache"

build_architecture() {
  local architecture="$1"
  local target_triple="${architecture}-apple-macosx${minimum_macos}"
  local scratch_path="$work_directory/build-$architecture"
  local binary_directory

  print "Building VimAny for $architecture..." >&2
  swift build \
    --scratch-path "$scratch_path" \
    --triple "$target_triple" \
    --sdk "$macos_sdk" \
    -c release \
    --product VimAny >&2
  binary_directory="$(swift build \
    --scratch-path "$scratch_path" \
    --triple "$target_triple" \
    --sdk "$macos_sdk" \
    -c release \
    --show-bin-path)"
  print -r -- "$binary_directory/VimAny"
}

arm64_binary="$(build_architecture arm64)"
x86_64_binary="$(build_architecture x86_64)"
application_path="$work_directory/VimAny.app"
application_contents="$application_path/Contents"

mkdir -p "$application_contents/MacOS" "$application_contents/Resources"
lipo -create "$arm64_binary" "$x86_64_binary" -output "$application_contents/MacOS/VimAny"
cp "$info_plist" "$application_contents/Info.plist"
"$project_root/Scripts/prepare-bundled-neovim.sh" "$application_contents/Resources"

sign_embedded_neovim() {
  local embedded_file

  while IFS= read -r -d '' embedded_file; do
    if file -b "$embedded_file" | grep -q 'Mach-O'; then
      if [[ -n "${VIMANY_CODESIGN_IDENTITY:-}" ]]; then
        codesign \
          --force \
          --options runtime \
          --timestamp \
          --sign "$VIMANY_CODESIGN_IDENTITY" \
          "$embedded_file"
      else
        codesign --force --sign - "$embedded_file"
      fi
    fi
  done < <(find "$application_contents/Resources/neovim" -type f -print0)
}

sign_embedded_neovim

if [[ -n "${VIMANY_CODESIGN_IDENTITY:-}" ]]; then
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$VIMANY_CODESIGN_IDENTITY" \
    "$application_path"
else
  codesign \
    --force \
    --sign - \
    --identifier dev.vimany.VimAny \
    --requirements '=designated => identifier "dev.vimany.VimAny"' \
    "$application_path"
  print -u2 "Warning: no VIMANY_CODESIGN_IDENTITY was supplied."
  print -u2 "The DMG is suitable for personal use but is not notarized for public distribution."
fi

codesign --verify --deep --strict "$application_path"
universal_architectures="$(lipo -archs "$application_contents/MacOS/VimAny")"
if [[ "$universal_architectures" != *arm64* || "$universal_architectures" != *x86_64* ]]; then
  print -u2 "error: universal binary validation failed: $universal_architectures"
  exit 1
fi

arm64_neovim="$application_contents/Resources/neovim/arm64/bin/nvim"
x86_64_neovim="$application_contents/Resources/neovim/x86_64/bin/nvim"
if [[ "$(lipo -archs "$arm64_neovim")" != *arm64* ]]; then
  print -u2 "error: packaged Apple Silicon Neovim validation failed"
  exit 1
fi
if [[ "$(lipo -archs "$x86_64_neovim")" != *x86_64* ]]; then
  print -u2 "error: packaged Intel Neovim validation failed"
  exit 1
fi

staging_directory="$work_directory/dmg-root"
mkdir -p "$staging_directory" "$output_directory"
ditto "$application_path" "$staging_directory/VimAny.app"
ln -s /Applications "$staging_directory/Applications"
cp "$read_me" "$staging_directory/Read Me.txt"

hdiutil create \
  -volname "VimAny $version" \
  -srcfolder "$staging_directory" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "$dmg_path"

if [[ -n "${VIMANY_CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp --sign "$VIMANY_CODESIGN_IDENTITY" "$dmg_path"
fi

if [[ -n "${VIMANY_NOTARY_PROFILE:-}" ]]; then
  if [[ -z "${VIMANY_CODESIGN_IDENTITY:-}" ]]; then
    print -u2 "error: VIMANY_NOTARY_PROFILE requires a Developer ID signing identity"
    exit 1
  fi
  xcrun notarytool submit "$dmg_path" \
    --keychain-profile "$VIMANY_NOTARY_PROFILE" \
    --wait
  xcrun stapler staple "$dmg_path"
  xcrun stapler validate "$dmg_path"
fi

hdiutil verify "$dmg_path"
(
  cd "$output_directory"
  shasum -a 256 "${dmg_path:t}" > "${checksum_path:t}"
)

print "Created universal DMG:"
print "$dmg_path"
print "SHA-256:"
print "$checksum_path"
