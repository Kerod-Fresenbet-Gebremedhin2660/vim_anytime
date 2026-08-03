VimAny — Personal Install
=========================

Requirements
------------

• macOS 13 or newer

Neovim 0.10.4 is included inside VimAny.app for both Apple Silicon and Intel.
No Homebrew packages or other dependencies need to be installed.

Install
-------

1. Drag VimAny.app onto the Applications shortcut in this window.
2. In Applications, Control-click VimAny and choose Open. Confirm Open once.
3. Enable VimAny in:

       System Settings → Privacy & Security → Accessibility

4. VimAny appears in the menu bar. Focus a plain-text field and press Control-M.

If this image was built without a Developer ID, it is ad-hoc signed and is not
Apple-notarized. If Gatekeeper still blocks the copy you made yourself, run
this once in Terminal:

    xattr -dr com.apple.quarantine /Applications/VimAny.app
    open /Applications/VimAny.app

Only remove quarantine from a DMG you built yourself or received through a
trusted private transfer.

Editing shortcuts
-----------------

• Command-Return: commit and close
• Command-S: commit without closing
• Command-period: cancel without changing the original field

Diagnostics
-----------

Choose “Reveal VimAny.log” from the VimAny menu-bar menu. Outside the source
project, the log is stored in:

    ~/Library/Application Support/VimAny/VimAny.log
