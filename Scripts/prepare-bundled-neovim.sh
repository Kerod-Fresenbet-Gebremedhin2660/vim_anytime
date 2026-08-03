#!/bin/zsh
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  print -u2 "usage: $0 <app-resources-directory>"
  exit 64
fi

project_root="${0:A:h:h}"
resources_directory="${1:A}"
neovim_version="0.10.4"
dependency_cache_root="${VIMANY_DEPENDENCY_CACHE:-$project_root/.build/dependencies}"
cache_directory="$dependency_cache_root/neovim/v$neovim_version"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/vimany-neovim.XXXXXX")"

cleanup() {
  if [[ -n "$temporary_directory" && -d "$temporary_directory" ]]; then
    rm -rf "$temporary_directory"
  fi
}
trap cleanup EXIT

download_verified() {
  local source_url="$1"
  local expected_sha256="$2"
  local destination="$3"
  local downloaded_file="$destination.download.$$"
  local actual_sha256

  if [[ -f "$destination" ]]; then
    actual_sha256="$(shasum -a 256 "$destination" | awk '{print $1}')"
    if [[ "$actual_sha256" == "$expected_sha256" ]]; then
      print "Using cached ${destination:t}"
      return
    fi
    print -u2 "Discarding cached file with an invalid checksum: $destination"
    rm -f "$destination"
  fi

  print "Downloading $source_url"
  curl --fail --location --silent --show-error \
    --output "$downloaded_file" \
    "$source_url"

  actual_sha256="$(shasum -a 256 "$downloaded_file" | awk '{print $1}')"
  if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    rm -f "$downloaded_file"
    print -u2 "error: checksum mismatch for $source_url"
    print -u2 "expected: $expected_sha256"
    print -u2 "actual:   $actual_sha256"
    exit 1
  fi
  mv -f "$downloaded_file" "$destination"
}

embed_architecture() {
  local architecture="$1"
  local archive_sha256="$2"
  local archive_name="nvim-macos-$architecture.tar.gz"
  local archive_path="$cache_directory/$archive_name"
  local source_url="https://github.com/neovim/neovim/releases/download/v$neovim_version/$archive_name"
  local extracted_root="$temporary_directory/nvim-macos-$architecture"
  local destination_root="$resources_directory/neovim/$architecture"
  local executable_path="$destination_root/bin/nvim"
  local executable_architectures

  download_verified "$source_url" "$archive_sha256" "$archive_path"
  tar -xzf "$archive_path" -C "$temporary_directory"
  if [[ ! -d "$extracted_root" ]]; then
    print -u2 "error: archive did not contain the expected directory: $extracted_root"
    exit 1
  fi

  rm -rf "$destination_root"
  mkdir -p "${destination_root:h}"
  ditto "$extracted_root" "$destination_root"

  if [[ ! -x "$executable_path" ]]; then
    print -u2 "error: bundled Neovim is not executable: $executable_path"
    exit 1
  fi
  if [[ ! -d "$destination_root/share/nvim/runtime" ]]; then
    print -u2 "error: bundled Neovim runtime is missing for $architecture"
    exit 1
  fi

  executable_architectures="$(lipo -archs "$executable_path")"
  if [[ "$executable_architectures" != *"$architecture"* ]]; then
    print -u2 "error: expected $architecture Neovim, found: $executable_architectures"
    exit 1
  fi
  print "Embedded Neovim $neovim_version for $architecture"
}

mkdir -p "$cache_directory" "$resources_directory/ThirdPartyLicenses"

embed_architecture \
  arm64 \
  3d7b07ec9b491d2a3d55167bc1db1cfa96773a1a37e74ea384cb15ab0189223b
embed_architecture \
  x86_64 \
  c1405071127b59dbdefc31d9c52e9a5c36db67dcef6dcf83e898aada1f3f778e

license_path="$cache_directory/Neovim-LICENSE.txt"
download_verified \
  "https://raw.githubusercontent.com/neovim/neovim/v$neovim_version/LICENSE.txt" \
  e1ff044cabc90a87faf9356618a5c43078c020c3c5e98a4dee570dd098da043d \
  "$license_path"

print -r -- "$neovim_version" > "$resources_directory/neovim/VERSION"
cp "$license_path" "$resources_directory/ThirdPartyLicenses/Neovim-LICENSE.txt"
cp \
  "$project_root/Support/Neovim-DEPENDENCY.txt" \
  "$resources_directory/ThirdPartyLicenses/Neovim-DEPENDENCY.txt"
