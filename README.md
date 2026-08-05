# VimAny

VimAny is a native macOS utility that edits the currently focused text field with Vim semantics. It renders a normal AppKit `NSTextView`; a persistent, invisible Neovim process provides editing behavior over MessagePack-RPC. It never opens Terminal, allocates a pseudo-terminal, or renders Neovim's terminal UI.

This repository contains the first end-to-end vertical slice: accessibility capture and commit, a borderless editor panel, normal/insert/replace/visual editing, native status, clipboard-backed Vim yanks and puts, a clipboard-preserving write fallback, deterministic embedded Neovim startup, and Unicode-aware coordinate conversion.

## Build and run

Requirements:

- macOS 13 or newer
- Xcode 15 or newer
- Neovim 0.10 or newer for local development builds and tests (`nvim` in `PATH`, `~/.local/bin`, `/opt/homebrew/bin`, or `/usr/local/bin`)

Open `Package.swift` in Xcode to develop and run tests, or build an application bundle from Terminal:

```sh
./Scripts/build-app.sh release
open .build/VimAny.app
```

On first use, macOS asks for Accessibility access. Enable VimAny in **System Settings → Privacy & Security → Accessibility**, then trigger the default shortcut, `⌃M`.

If VimAny is checked there but still reports that permission is required, reset the stale grant and authorize the current bundle once:

```sh
tccutil reset Accessibility dev.vimany.VimAny
open .build/VimAny.app
```

The development build uses a stable designated requirement, so the refreshed grant survives later runs of `build-app.sh`. Set `VIMANY_CODESIGN_IDENTITY` to use an installed signing identity instead.

The shortcut is persisted with `UserDefaults`. Until the preferences UI is added, it can be changed with key code and Carbon modifier values:

```sh
defaults write dev.vimany.VimAny GlobalShortcutKeyCode -int 46
defaults write dev.vimany.VimAny GlobalShortcutModifiers -int 4096
```

Restart VimAny after changing those values.

## Build a DMG

Create a universal Apple Silicon and Intel installer image with:

```sh
./Scripts/build-dmg.sh
```

The DMG and its SHA-256 checksum are written to `.build/distribution/`. It
contains `VimAny.app`, an Applications shortcut, and personal-install notes.
The app includes pinned Neovim 0.10.4 distributions for both Apple Silicon and
Intel, so the destination Mac does not need Homebrew, Neovim, or another
third-party dependency. The build downloads the official release archives,
verifies their fixed SHA-256 checksums, and includes the Neovim license and
source metadata in the application bundle.

Without a signing identity, the script creates an ad-hoc-signed personal build.
For Developer ID signing, set `VIMANY_CODESIGN_IDENTITY`. To submit that signed
image for notarization as well, store credentials in a `notarytool` keychain
profile and set `VIMANY_NOTARY_PROFILE`:

```sh
VIMANY_CODESIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
VIMANY_NOTARY_PROFILE="vimany-notary" \
./Scripts/build-dmg.sh
```

## Diagnostics

The development app writes structured diagnostics to `VimAny.log` in this project directory. The file persists across launches and separates each run with a timestamped `Session` entry. Choose **Reveal VimAny.log** from the menu bar item to locate it, then attach that one file when reporting a problem.

Diagnostics include application lifecycle, Accessibility results, shortcut registration, panel state, Neovim process/restart events, MessagePack-RPC method traffic, cursor coordinates, and clipboard fallback outcomes. Field text, inserted text, searches, and clipboard contents are not recorded; only their sizes and related coordinates are logged.

Set `VIMANY_LOG_PATH` to an absolute path before launch to override the destination. If the app is moved outside this development project, it falls back to `~/Library/Application Support/VimAny/VimAny.log`.

## Editing

- `⌘Return` commits and closes.
- `⌘S` commits without closing.
- `⌘.` cancels without writing.
- If commit-and-close cannot write to the original field through either AX or
  paste fallback, the edited text is copied to the macOS clipboard before the
  panel closes. A failed `⌘S` keeps the panel open instead.
- Native spell checking underlines likely misspellings without changing the
  buffer. Automatic correction and direct AppKit spelling replacements remain
  disabled so Neovim's undo history and dot-repeat stay authoritative.
- Cursor `@file` references are shown as readable `@filename` text instead of
  Cursor's private-use file and close icons. Commits replace only the editable
  text gaps around unchanged references, leaving Cursor's rich reference nodes
  in place. If a reference token itself is changed or reordered, VimAny refuses
  a destructive whole-field replacement and uses the normal safe-failure path.
- Vim yanks, deletes, changes, `p`, and `P` use the macOS clipboard.
- `:w`, `:wq`, `:x`, `:q`, `:q!`, `:undo`, `:redo`, and `:nohlsearch` form the intentionally small Ex whitelist. Other Ex commands are rejected in the native status line. Shell commands are never passed to Neovim.

See [Implementation Plan](Documentation/IMPLEMENTATION_PLAN.md) for architecture, scope, and the proposed Xcode grouping.
