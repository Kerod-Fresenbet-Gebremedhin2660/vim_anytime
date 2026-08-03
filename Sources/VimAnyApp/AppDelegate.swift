import AppKit
import VimAnyCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var shortcutManager: GlobalShortcutManager?
    private var panelController: EditorPanelController?
    private var nvimHost: NvimHost?
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AccessibilityTextService.requestPermissionPrompt()

        let clipboard = SystemClipboardService()
        let accessibility = AccessibilityTextService()
        let fallback = ClipboardFallbackService(clipboard: clipboard)
        let commitCoordinator = FieldCommitCoordinator(
            accessibility: accessibility,
            fallback: fallback
        )
        let host = NvimHost(clipboard: clipboard)
        let viewModel = EditorViewModel(engine: host)
        panelController = EditorPanelController(
            viewModel: viewModel,
            commitCoordinator: commitCoordinator
        )
        nvimHost = host

        configureStatusItem()
        let shortcutManager = GlobalShortcutManager { [weak self] in
            Task { @MainActor in self?.openEditor() }
        }
        self.shortcutManager = shortcutManager
        do {
            try shortcutManager.register()
        } catch {
            showError(error)
        }

        Task {
            do { try await host.start() }
            catch { await MainActor.run { self.showError(error) } }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating, let nvimHost else { return .terminateNow }
        isTerminating = true
        shortcutManager?.unregister()
        Task {
            await nvimHost.stop()
            await MainActor.run {
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

    private func openEditor() {
        guard let panelController else { return }
        Task {
            do {
                try await panelController.presentForFocusedField()
            } catch {
                showError(error)
            }
        }
    }

    private func configureStatusItem() {
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
        let shortcutItem = NSMenuItem(title: "Shortcut: ⌃⌥⌘V", action: nil, keyEquivalent: "")
        shortcutItem.isEnabled = false
        menu.addItem(shortcutItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit VimAny", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
    }

    private func showError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "VimAny"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

