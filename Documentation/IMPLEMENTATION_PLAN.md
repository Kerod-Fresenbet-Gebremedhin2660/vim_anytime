# Technical implementation plan

## Goals and boundaries

The first release is a menu-bar-style AppKit utility. A global hot key captures the focused accessibility text element, mirrors its plain text into one scratch Neovim buffer, and presents that buffer in a borderless native panel. AppKit owns pixels, input methods, mouse interaction, scrolling, and platform accessibility; Neovim owns editing state and semantics.

The embedded process is launched directly as:

```text
nvim --embed --headless --clean -i NONE
```

stdin and stdout carry MessagePack-RPC. There is no terminal, PTY, terminal-grid renderer, user configuration, or plugin loading. The process stays alive across popup sessions and restarts after an unexpected exit. The only accepted Ex commands are app-side, whitelisted commands. Normal-mode mappings suppress macro recording/execution, mark creation/jumps, register selection, Ex mode, suspension, file-write/quit shortcuts, and shell filters.

## Event and state flow

```text
Carbon global shortcut
  → AccessibilityTextService.captureFocusedTextField()
  → NvimHost.load(text:selection:)
  → EditorPanelController presents VimTextView
  → NSEvent / NSTextInputClient commit
  → KeyTranslator
  → NvimHost nvim_input / nvim_paste
  → EditorSnapshot
  → NSTextView storage, selection, scrolling, and native status bar
```

Commit converts the current Neovim byte-based cursor/visual selection into an AppKit UTF-16 range. `AccessibilityTextService` first attempts a direct AX value and selection write. If the value write is rejected, `ClipboardFallbackService` focuses the captured application, temporarily places the final text on the pasteboard, synthesizes Select All and Paste, then restores a full pasteboard archive only when neither the pasteboard nor the intentional-edit clipboard generation changed during the operation.

## Proposed Xcode project structure

Xcode can open the checked-in Swift package directly. The logical groups and eventual app target layout are:

```text
VimAny
├── VimAnyApp
│   ├── AppDelegate
│   ├── EditorPanelController
│   ├── VimTextView
│   ├── StatusLineView
│   └── main
├── VimAnyCore
│   ├── Accessibility
│   │   ├── AccessibilityTextService
│   │   └── FieldCommitCoordinator
│   ├── Clipboard
│   │   ├── SystemClipboardService
│   │   └── ClipboardFallbackService
│   ├── Editor
│   │   ├── EditorModels
│   │   ├── EditorViewModel
│   │   ├── KeyTranslator
│   │   └── TextCoordinateConverter
│   ├── Neovim
│   │   ├── MessagePack
│   │   ├── MessagePackRPCClient
│   │   └── NvimHost
│   └── Shortcut
│       └── GlobalShortcutManager
├── VimAnyCoreTests
└── VimAnyIntegrationTests
```

The split deliberately keeps Neovim behind `NvimEditingEngine`, so another engine can replace it without changing panel, AX, shortcut, or clipboard code.

## Delivery stages

1. Build the data model, lossless UTF-8/UTF-16 conversion, and unit tests.
2. Implement incremental MessagePack encoding/decoding and request/response/notification routing.
3. Launch and harden a deterministic persistent Neovim host, including clipboard provider callbacks and crash recovery.
4. Implement accessibility capture/direct write, focus restoration, and clipboard-preserving fallback.
5. Implement the AppKit panel, status line, input translation, native committed-text path, and app shortcuts.
6. Verify representative Vim operations against the real embedded process and verify clipboard semantics.

## Known first-slice limits

Rich-text attributes are flattened to plain text. AX fallback selection restoration depends on what the target application accepts after paste. Shortcut configuration is persisted but initially exposed through `defaults` rather than a preferences window. Native marked-text composition is displayed by `NSTextView` and committed to Neovim when the input method finalizes it; syntax highlighting and other file-editor features are intentionally absent.

