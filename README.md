# VimAny

VimAny is a native macOS utility that edits the currently focused text field with Vim semantics. It renders a normal AppKit `NSTextView`; a persistent, invisible Neovim process provides editing behavior over MessagePack-RPC. It never opens Terminal, allocates a pseudo-terminal, or renders Neovim's terminal UI.

This repository contains the first end-to-end vertical slice: accessibility capture and commit, a borderless editor panel, normal/insert/replace/visual editing, native status, clipboard-backed Vim yanks and puts, a clipboard-preserving write fallback, deterministic embedded Neovim startup, and Unicode-aware coordinate conversion.

## Build and run

Requirements:

- macOS 13 or newer
- Xcode 15 or newer
- Neovim 0.10 or newer (`nvim` in `PATH`, `~/.local/bin`, `/opt/homebrew/bin`, or `/usr/local/bin`)

Open `Package.swift` in Xcode to develop and run tests, or build an application bundle from Terminal:

```sh
./Scripts/build-app.sh release
open .build/VimAny.app
```

On first use, macOS asks for Accessibility access. Enable VimAny in **System Settings → Privacy & Security → Accessibility**, then trigger the default shortcut, `⌃⌥⌘V`.

The shortcut is persisted with `UserDefaults`. Until the preferences UI is added, it can be changed with key code and Carbon modifier values:

```sh
defaults write dev.vimany.VimAny GlobalShortcutKeyCode -int 9
defaults write dev.vimany.VimAny GlobalShortcutModifiers -int 6400
```

Restart VimAny after changing those values.

## Editing

- `⌘Return` commits and closes.
- `⌘S` commits without closing.
- `⌘.` cancels without writing.
- Vim yanks, deletes, changes, `p`, and `P` use the macOS clipboard.
- `:w`, `:wq`, `:x`, `:q`, `:q!`, `:undo`, `:redo`, and `:nohlsearch` form the intentionally small Ex whitelist. Other Ex commands are rejected in the native status line. Shell commands are never passed to Neovim.

See [Implementation Plan](Documentation/IMPLEMENTATION_PLAN.md) for architecture, scope, and the proposed Xcode grouping.

