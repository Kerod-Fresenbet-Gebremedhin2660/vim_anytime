import AppKit
import VimAnyCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = DiagnosticLogger.shared
    private var statusItem: NSStatusItem?
    private var shortcutManager: GlobalShortcutManager?
    private var panelController: EditorPanelController?
    private var nvimHost: NvimHost?
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info(
            "App",
            "didFinishLaunching accessibilityTrusted=\(AccessibilityTextService.isTrusted)"
        )
        NSApp.setActivationPolicy(.accessory)
        AccessibilityTextService.requestPermissionPrompt()

        let clipboard = SystemClipboardService()
        let accessibility = AccessibilityTextService()
        let fallback = ClipboardFallbackService(clipboard: clipboard)
        let commitCoordinator = FieldCommitCoordinator(
            accessibility: accessibility,
            fallback: fallback,
            clipboard: clipboard
        )
        let host = NvimHost(clipboard: clipboard)
        let viewModel = EditorViewModel(engine: host)
        panelController = EditorPanelController(
            viewModel: viewModel,
            commitCoordinator: commitCoordinator
        )
        nvimHost = host

        let shortcutManager = GlobalShortcutManager { [weak self] in
            Task { @MainActor in self?.openEditor() }
        }
        self.shortcutManager = shortcutManager
        configureStatusItem(shortcutName: shortcutManager.configuredShortcut.displayName)
        do {
            try shortcutManager.register()
            logger.info(
                "App",
                "global shortcut registered shortcut=\(shortcutManager.configuredShortcut.displayName)"
            )
        } catch {
            showError(error)
        }

        Task {
            do {
                try await host.start()
                self.logger.info("App", "embedded Neovim ready")
            } catch {
                await MainActor.run { self.showError(error) }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating, let nvimHost else {
            logger.info("App", "terminating immediately")
            logger.flush()
            return .terminateNow
        }
        logger.info("App", "termination requested")
        isTerminating = true
        shortcutManager?.unregister()
        Task {
            await nvimHost.stop()
            await MainActor.run {
                self.logger.info("App", "embedded Neovim stopped; terminating")
                self.logger.flush()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    @objc private func openEditorFromMenu(_ sender: Any?) {
        openEditor()
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    @objc private func revealLogFile(_ sender: Any?) {
        logger.info("App", "reveal log requested")
        logger.flush()
        NSWorkspace.shared.activateFileViewerSelecting([logger.fileURL])
    }

    private func openEditor() {
        logger.info("App", "open editor requested")
        guard let panelController else {
            logger.error("App", "open editor ignored because panel controller is unavailable")
            return
        }
        Task {
            do {
                try await panelController.presentForFocusedField()
            } catch {
                self.logger.error("App", error: error, context: "open editor failed")
                if let accessibilityError = error as? AccessibilityTextError,
                   case .permissionDenied = accessibilityError {
                    showAccessibilityPermissionError()
                } else {
                    showError(error)
                }
            }
        }
    }

    private func configureStatusItem(shortcutName: String) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "character.cursor.ibeam",
                accessibilityDescription: "VimAny"
            )
        }
        let menu = NSMenu()
        let openItem = NSMenuItem(
            title: "Open VimAny",
            action: #selector(openEditorFromMenu(_:)),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)
        let shortcutItem = NSMenuItem(title: "Shortcut: \(shortcutName)", action: nil, keyEquivalent: "")
        shortcutItem.isEnabled = false
        menu.addItem(shortcutItem)
        menu.addItem(.separator())
        let logItem = NSMenuItem(
            title: "Reveal VimAny.log",
            action: #selector(revealLogFile(_:)),
            keyEquivalent: ""
        )
        logItem.target = self
        menu.addItem(logItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit VimAny", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
    }

    private func showError(_ error: Error) {
        logger.error("App", error: error, context: "presenting error alert")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "VimAny"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showAccessibilityPermissionError() {
        logger.warning(
            "Accessibility",
            "permission recovery alert shown trusted=\(AccessibilityTextService.isTrusted)"
        )
        NSApp.activate(ignoringOtherApps: true)
        let appPath = Bundle.main.bundleURL.path
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Accessibility access needs to be refreshed"
        alert.informativeText = """
        macOS has not authorized this exact VimAny build. Remove the existing VimAny entry in Privacy & Security → Accessibility, add the app at:

        \(appPath)

        Then enable it and relaunch VimAny.
        """
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let settingsURL = URL(
               string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
           ) {
            NSWorkspace.shared.open(settingsURL)
        }
    }
}
