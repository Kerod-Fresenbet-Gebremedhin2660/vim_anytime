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
  → AccessibilityTextContentAdapter removes target-app presentation markers
  → NvimHost.load(text:selection:)
  → EditorPanelController presents VimTextView
  → NSEvent / NSTextInputClient commit
  → KeyTranslator
  → NvimHost nvim_input / nvim_paste
  → EditorSnapshot
  → NSTextView storage, selection, scrolling, and native status bar
```

Commit converts the current Neovim byte-based cursor/visual selection into an AppKit UTF-16 range. `AccessibilityTextContentAdapter` first converts target-app presentation details into editable plain text and maps the AX selection into that representation. Cursor reference chips exposed as private-use file icon, label, and close icon lines become readable `@label` tokens. When those tokens remain unchanged and ordered, commit re-reads Cursor's current AX value—whose boundary presentation text can change with focus—and constructs descending AX range replacements for only the current plain-text gaps around them. `ClipboardFallbackService` selects each gap and uses Cursor's plain-paste path, preserving the original rich reference nodes and restoring the archived clipboard afterward. Whole AX value writes and Select All/Paste are never attempted for a field with adapted references because either operation flattens those nodes. A changed or reordered reference token fails safely instead. For ordinary fields, `AccessibilityTextService` first attempts a direct AX value and selection write, followed by clipboard fallback when needed. Every strategy reads the target value back, normalizes it through the same adapter, and only an exact editable-text match counts as success; successfully posting a keyboard event alone is not considered a successful write.

For commit-and-close, a failure of both field-write strategies becomes an
intentional clipboard action: after temporary fallback restoration has
finished, VimAny places the final edited text on the macOS clipboard and closes
the session. Commit-without-close keeps the panel open on failure and does not
replace the clipboard.

## Proposed Xcode project structure

Xcode can open the checked-in Swift package directly. The logical groups and eventual app target layout are:

```text
VimAny
├── VimAnyApp
│   ├── AppDelegate
│   ├── EditorPanelController
│   ├── LineNumberRulerView
│   ├── VimTextView
│   ├── StatusLineView
│   └── main
├── VimAnyCore
│   ├── Accessibility
│   │   ├── AccessibilityTextContentAdapter
│   │   ├── AccessibilityTextService
│   │   └── FieldCommitCoordinator
│   ├── Clipboard
│   │   ├── SystemClipboardService
│   │   └── ClipboardFallbackService
│   ├── Diagnostics
│   │   └── DiagnosticLogger
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
├── VimAnyAppTests
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

Rich-text attributes are flattened to plain text. AX fallback selection restoration depends on what the target application accepts after paste. Shortcut configuration is persisted but initially exposed through `defaults` rather than a preferences window. Native marked-text composition is displayed by `NSTextView` and committed to Neovim when the input method finalizes it. AppKit continuous spell checking provides visual misspelling underlines, but automatic correction and direct AppKit spelling replacement are disabled so Neovim's undo tree and dot-repeat remain authoritative. Syntax highlighting and other file-editor features are intentionally absent.

## Selectable feature roadmap

This section is a menu, not a commitment. Feature IDs are intended to remain
stable so a release can be scoped by selecting IDs such as `SET-1`, `AX-2`, and
`SEARCH-1`.

Relative effort:

- **S**: isolated change with little new state or UI.
- **M**: several components or a small native window/popover.
- **L**: cross-cutting state, substantial compatibility work, or a new protocol.
- **XL**: architectural project that should be delivered in stages.

Risk describes the chance of regressions, application-specific behavior, or
privacy/security surprises. It is not a measure of implementation quality.

### Roadmap guardrails

Every selected feature must preserve these properties:

- The visible UI remains native AppKit/TextKit. No terminal, PTY, terminal grid,
  Electron, web view, or Neovim terminal UI is introduced.
- Neovim remains an invisible persistent process launched directly with the
  deterministic embedded arguments and configuration.
- User `init.lua`, plugins, file editing, and arbitrary shell or raw Ex command
  execution remain disabled.
- The UI does not expose macros, marks, named/numbered registers, or register
  selection syntax.
- Clipboard fallback remains separate from intentional Vim clipboard actions.
- Logs and diagnostics describe text by metadata, never by recording field or
  clipboard contents.
- Features should depend on `NvimEditingEngine`, not concrete Neovim details,
  whenever the abstraction can represent them cleanly.

### Settings and lifecycle

| ID | Feature | User outcome | Effort / risk | Implementation notes |
|---|---|---|---|---|
| **SET-1** | Native Settings window and shortcut recorder | Change the global shortcut without `defaults`; detect shortcut conflicts before saving. | M / Low | Add typed preferences, validation, reset-to-default, and live shortcut re-registration. This is the foundation for SET-2 and SET-4. |
| **SET-2** | Appearance preferences | Configure font size, panel width/height, opacity, line numbers, status-line density, and light/dark/system appearance. | M / Low | Apply changes live and retain accessible contrast floors. Do not permit selecting a font that cannot render ordinary Unicode fallback glyphs. |
| **SET-3** | Launch at login | Start VimAny automatically and show its current engine/permission state in the menu-bar menu. | S / Low | Use `SMAppService`; include a clear off switch and no background helper unless it becomes necessary. |
| **SET-4** | Per-application profiles | Use different panel, commit, clipboard, or fallback behavior for specific bundle identifiers. | L / Medium | Depends on SET-1. Profiles must have predictable precedence and a visible indication when active. |

### Native panel and discoverability

| ID | Feature | User outcome | Effort / risk | Implementation notes |
|---|---|---|---|---|
| **UX-1** | Smarter panel placement | Open near the source caret when AX geometry is available; otherwise remember a sensible position per display. | M / Medium | Handle multiple displays, Spaces, full-screen apps, menu-bar/Dock insets, and stale source geometry. |
| **UX-2** | Vim command cheat sheet | Show a searchable native popover of supported keys and application shortcuts. | M / Low | Generate the list from the tested command capability table so documentation cannot drift from behavior. |
| **UX-3** | Configurable status line | Choose compact or detailed status; optionally show pending count/operator, selection length, search match count, engine health, and commit state. | S / Low | Depends on SET-1 for persistence. Keep errors visually dominant and VoiceOver-readable. |
| **UX-4** | Accessibility and display polish | Improve VoiceOver labels/order, keyboard focus visibility, Increase Contrast, Reduce Transparency, Reduce Motion, and larger text behavior. | M / Low | Add an accessibility audit and automated assertions where AppKit exposes testable state. |
| **UX-5** | Native command palette | Offer safe app commands such as Commit, Cancel, Preferences, Copy Diagnostics, and supported buffer transformations. | M / Low | The palette invokes typed application APIs; it must never forward arbitrary strings to Ex or a shell. |

### Vim editing behavior

| ID | Feature | User outcome | Effort / risk | Implementation notes |
|---|---|---|---|---|
| **VIM-1** | Certified safe command matrix | Explicitly support and test more built-in motions/operators such as `%`, `{}`, `}`, `f/F/t/T`, `;`, `,`, `J`, `~`, `gu`, `gU`, `>>`, `<<`, and numeric increment/decrement. | M / Medium | Add commands only after confirming they cannot escape the scratch buffer or expose excluded register/mark/macro UI. |
| **VIM-2** | Visual-block mode | Add `Ctrl-V` rectangular selection, native block highlighting, block insert/append/change/yank, and Unicode-safe columns. | XL / High | A single `NSRange` cannot represent a rectangle. Introduce a native selection overlay model and test tabs, emoji, combining marks, and short lines. |
| **VIM-3** | Native word completion | Support safe `Ctrl-N`/`Ctrl-P` completion from words already in the scratch buffer with an AppKit completion popover. | L / Medium | Neovim computes candidates and selection; AppKit renders the list. No LSP, plugins, filesystem dictionaries, or shell completion. |
| **VIM-4** | Edit-selection-only session | Optionally load only the source selection and replace only that range on commit. | L / High | Detect source-field changes and range drift before commit. Multiline and browser `AXTextMarker` fields require special handling. |
| **VIM-5** | Constrained key customization | Let users map keys only to a validated set of supported editing/application actions. | L / High | Never accept raw Lua, Ex, register prefixes, macro keys, marks, shell commands, or arbitrary Neovim mappings. Prefer a typed action enum. |
| **VIM-6** | Keyboard-layout robustness | Make command keys predictable across non-US layouts while leaving inserted text and IME composition native. | M / Medium | Separate physical command-key interpretation from composed text. Test dead keys, Dvorak/Colemak, RTL input, and input-source changes mid-session. |

### Search and safe commands

| ID | Feature | User outcome | Effort / risk | Implementation notes |
|---|---|---|---|---|
| **SEARCH-1** | Incremental search presentation | Highlight all matches natively while typing `/` or `?`, show current/total match count, and keep `n`/`N` synchronized. | L / Medium | Neovim owns patterns and match positions; convert byte ranges to TextKit UTF-16 ranges without using terminal highlights. |
| **SEARCH-2** | Native find-and-replace sheet | Preview and apply literal or Vim-pattern replacements without typing Ex syntax. | L / Medium | Use structured parameters and an explicit confirmation for replace-all. Never concatenate untrusted input into raw commands. |
| **EX-1** | Expanded safe Ex whitelist | Add buffer-only commands such as substitute, sort, join, delete-lines, and whitespace cleanup. | L / High | Parse into typed commands and call structured Lua/API functions. Do not expose `:normal`, `:source`, file commands, scripting, jobs, terminals, or shell escapes. |
| **EX-2** | Safe command history and completion | Navigate commands entered during the current app run and complete only whitelisted command names. | M / Low | Store no field contents or search text across launches unless a separate explicit privacy setting is added. |

### Clipboard and paste behavior

| ID | Feature | User outcome | Effort / risk | Implementation notes |
|---|---|---|---|---|
| **CLIP-1** | Clipboard policy preference | Choose whether delete/change operations update the macOS clipboard or preserve the most recent explicit yank. | M / Medium | This changes behavior, not register selection. The UI should explain both policies using normal macOS clipboard language. |
| **CLIP-2** | Paste transformations | Offer explicit Paste Plain, normalize CRLF, trim one final newline, or reindent multiline text. | M / Medium | Transform a local copy and leave the user clipboard unchanged. Default paste must remain lossless. |
| **CLIP-3** | Hardened fallback strategies | Improve commit fallback for browser, Electron, JetBrains, and custom controls with verification, bounded retry, and actionable failure messages. | L / High | Never retry blindly after a paste that may already have succeeded. Preserve intentional Vim clipboard generations in every branch. |
| **CLIP-4** | Pasteboard fidelity test suite | Verify fallback restoration for multiple items and non-text types such as images, files, URLs, colors, and custom UTTypes. | M / Medium | Tests should prove that temporary replacement does not silently discard pasteboard representations. |

### Accessibility and application compatibility

| ID | Feature | User outcome | Effort / risk | Implementation notes |
|---|---|---|---|---|
| **AX-1** | Permission onboarding and repair | See whether the exact running bundle is trusted, open the correct Settings page, and receive precise steps for stale TCC entries. | M / Medium | Show bundle path, signature identity, and trust state without automatically resetting TCC. Detect when a relaunch is required. |
| **AX-2** | `AXTextMarker` and contenteditable support | Reliably capture and restore selection in browser editors and controls that do not expose `AXSelectedTextRange`. | XL / High | Add a second coordinate model behind `CapturedTextTarget`; test Chromium, Safari/WebKit, and multiline contenteditable elements. |
| **AX-3** | Compatibility profiles and health checks | Detect known target-app capabilities before opening and select direct AX write or fallback deliberately. | L / High | Key profiles by bundle ID and observed AX attributes, not brittle app names. Keep a generic path for unknown apps. |
| **AX-4** | Source caret geometry | Read the target selection bounds for UX-1 and restore the source scroll/caret position more accurately. | L / High | Different applications expose bounds through ranges, text markers, or not at all; every path needs a fallback. |
| **AX-5** | Commit verification and focus recovery | Confirm that text/selection actually changed, handle closed or replaced controls, and explain partial success. | L / High | Use bounded read-back checks without logging contents. Never overwrite a newly focused unrelated control. |

### Data safety and privacy

| ID | Feature | User outcome | Effort / risk | Implementation notes |
|---|---|---|---|---|
| **SAFE-1** | Concurrent-change detection | Avoid overwriting source text that another process or the user changed while the panel was open. | L / High | Retain a fingerprint plus structural metadata, re-read before commit, then offer Cancel, Replace, or a native diff. |
| **SAFE-2** | Crash-recovery draft | Recover an interrupted edit after an app or machine crash. | L / High | Opt-in only. Encrypt drafts at rest, exclude secure fields, define retention, and provide Delete Now. In-memory Neovim restart recovery remains automatic. |
| **SAFE-3** | Commit diff preview | Review additions/deletions before replacing a long field or resolving SAFE-1 conflicts. | L / Medium | Render a native text diff; never invoke an external diff tool or write a temporary plaintext file. |
| **SAFE-4** | Secure-field guard | Refuse password/secure controls and warn when a target appears sensitive. | M / Medium | Inspect AX role/subrole and target metadata. Fail closed when the field is explicitly secure. |

### Engine, latency, and large text

| ID | Feature | User outcome | Effort / risk | Implementation notes |
|---|---|---|---|---|
| **ENG-1** | Event-driven buffer updates | Reduce RPC round trips and repaint only changed ranges instead of requesting the full snapshot after every input. | XL / High | Use `nvim_buf_attach` notifications plus a versioned state reducer; retain a full-snapshot resync path after dropped events or restart. |
| **ENG-2** | Input coalescing and backpressure | Keep rapid typing, key repeat, paste, and IME commits responsive when Neovim or TextKit is briefly busy. | L / High | Preserve strict Vim key order. Coalesce renders, not semantic input, and cap queues with observable recovery. |
| **ENG-3** | Engine health supervision | Show startup/restart state, perform a lightweight heartbeat, and recover without presenting stale text as current. | M / Medium | Build on existing process termination recovery; add generation IDs so late RPC responses cannot update a new session. |
| **ENG-4** | Large-field mode | Keep fields containing hundreds of thousands of characters usable. | XL / High | Establish benchmarks first. Likely requires ENG-1, incremental attribute work, bounded line-number layout, and reduced status computation. |

### Diagnostics and supportability

| ID | Feature | User outcome | Effort / risk | Implementation notes |
|---|---|---|---|---|
| **DIAG-1** | Export Diagnostics bundle | Produce one attachable archive containing the rotated log, app/build version, OS, CPU, Neovim version, permission state, and sanitized configuration. | M / Low | Include a manifest of every exported file and a privacy preview. Never include edited text, searches, clipboard data, or draft contents. |
| **DIAG-2** | In-app health window | Inspect shortcut registration, AX trust, current font/fallbacks, Neovim process, bundle paths, signatures, and last recoverable error. | M / Low | Use read-only probes and Copy Summary. This complements AX-1 and ENG-3. |
| **DIAG-3** | Log levels, rotation, and redaction tests | Prevent unbounded log growth and prove sensitive strings cannot enter diagnostics. | M / Low | Rotate by size/count, retain recent failures, and add automated redaction canary tests. |

### Distribution and updates

| ID | Feature | User outcome | Effort / risk | Implementation notes |
|---|---|---|---|---|
| **DIST-1** | Developer ID signing and notarization | Open the downloaded app normally without Gatekeeper workarounds. | M / Medium | Requires an Apple Developer identity and notary credentials. Sign every embedded Mach-O component before the outer app and DMG. |
| **DIST-2** | Signed automatic updates | Receive verified updates without manually replacing the app. | L / High | A framework such as Sparkle must be bundled, signed, pinned, licensed, and isolated from editor data. Require EdDSA update signatures. |
| **DIST-3** | Reproducible release CI | Build/test both architectures, verify dependency checksums and signatures, notarize, produce DMG/checksum/SBOM, and retain provenance. | L / Medium | Keep local personal builds working without CI secrets. Test the packaged Neovim engine, not only the developer installation. |
| **DIST-4** | Versioned preferences and bundled-engine migration | Upgrade settings safely and make pinned Neovim updates repeatable with compatibility tests and rollback notes. | M / Medium | Never silently begin loading user configuration or plugins when the embedded engine changes. |

### Test infrastructure

| ID | Feature | User outcome | Effort / risk | Implementation notes |
|---|---|---|---|---|
| **QA-1** | Accessibility application harness | Catch capture, write, fallback, cancel, and focus regressions across native fields, browsers, contenteditable, and deliberately hostile controls. | L / Medium | Build controlled fixture apps/pages and assert final text without relying on the developer's open documents. |
| **QA-2** | Unicode and RPC fuzzing | Find malformed MessagePack frames, split-read bugs, and UTF-8/UTF-16 coordinate failures before users do. | L / Medium | Generate combining sequences, emoji ZWJ clusters, RTL text, invalid boundaries, multiline text, and random transport chunking. |
| **QA-3** | Native UI snapshot and accessibility tests | Detect boxed glyphs, cursor/selection errors, line-number drift, contrast problems, and panel layout regressions. | L / Medium | Render deterministic AppKit fixtures in light/dark/high-contrast modes and test actual fallback-font coverage. |

## Suggested selection bundles

These bundles are independent suggestions; individual IDs can be mixed freely.

### Best next daily-driver release

`SET-1`, `AX-1`, `SAFE-1`, `SEARCH-1`, `DIAG-1`, `DIAG-3`

This makes the current app easier to configure, safer to commit from, easier to
search in, and much easier to support without changing its core architecture.

### Vim-polish release

`VIM-1`, `VIM-6`, `SEARCH-1`, `SEARCH-2`, `EX-2`, `CLIP-1`

This improves editing depth and discoverability while keeping the intentionally
small security boundary around Ex commands and registers.

### Compatibility release

`AX-2`, `AX-3`, `AX-5`, `CLIP-3`, `QA-1`

This is the highest-value bundle if browser and custom-control compatibility is
the main source of user reports. It is also comparatively high risk and should
be driven by fixture tests.

### Public distribution release

`DIST-1`, `DIST-2`, `DIST-3`, `DIST-4`, `DIAG-1`

This turns the personal DMG into a maintainable public release channel. Apple
Developer credentials are a prerequisite for the full bundle.

### Performance release

`ENG-1`, `ENG-2`, `ENG-3`, `ENG-4`, `QA-2`, `QA-3`

This should follow measured benchmarks rather than be selected preemptively.
ENG-1 is the architectural foundation for ENG-4.

## Deliberately excluded roadmap items

The following are not candidates because they conflict with the product's
security boundary or focused utility design:

- Terminal UI rendering, terminal launch, or pseudo-terminal support.
- Loading the user's Neovim configuration or plugins.
- Arbitrary Lua, raw Ex, shell, job, terminal, or file commands.
- Macro recording/execution, marks, register selection, or register inspection.
- File browsing/editing, tabs, multiple Neovim windows, LSP, or a general IDE.
- Silent persistent storage of source text, clipboard contents, searches, or
  commands.

Rich-text preservation is not listed as a near-term candidate. It would require
a separate attributed-text edit/merge model because Neovim owns plain buffer
text; pretending it is a small extension would create silent formatting loss.
