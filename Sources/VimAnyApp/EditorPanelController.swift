import AppKit
import VimAnyCore

private final class EditorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class EditorPanelController: NSWindowController {
    private let logger = DiagnosticLogger.shared
    private let viewModel: EditorViewModel
    private let commitCoordinator: FieldCommitCoordinator
    private let textView: VimTextView
    private let statusLine = StatusLineView(frame: .zero)
    private var isPresenting = false
    private var lastLoggedMode: VimMode?

    init(viewModel: EditorViewModel, commitCoordinator: FieldCommitCoordinator) {
        self.viewModel = viewModel
        self.commitCoordinator = commitCoordinator

        let panel = EditorPanel(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 470),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        // `init(frame:textContainer:)` does not create a TextKit network when
        // its container is nil. Use the frame-only initializer so snapshots
        // have a real NSTextStorage/layout manager to render into.
        textView = VimTextView(frame: .zero)
        precondition(textView.textStorage != nil, "VimTextView requires a TextKit backing store")
        super.init(window: panel)
        buildContent(in: panel)
        connectEvents()
        logger.info("Panel", "initialized textStorageAvailable=\(textView.textStorage != nil)")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func presentForFocusedField() async throws {
        if window?.isVisible == true {
            logger.info("Panel", "presentation reused existing visible panel")
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            return
        }
        guard !isPresenting else {
            logger.warning("Panel", "duplicate presentation ignored while capture is in progress")
            return
        }
        logger.info("Panel", "presentation started")
        isPresenting = true
        defer { isPresenting = false }

        let capture: CapturedTextField
        do {
            capture = try commitCoordinator.begin()
        } catch {
            logger.error("Panel", error: error, context: "focused field capture failed")
            throw error
        }
        logger.info(
            "Panel",
            "captured app=\(capture.applicationName ?? "unknown") "
                + "pid=\(capture.target.processIdentifier) utf16Length=\(capture.text.utf16.count) "
                + "selection=\(NSStringFromRange(capture.selectionRange))"
        )
        do {
            try await viewModel.load(text: capture.text, selection: capture.editorSelection)
        } catch {
            logger.error("Panel", error: error, context: "loading field into Neovim failed")
            commitCoordinator.cancel()
            throw error
        }

        positionPanel()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
        logger.info("Panel", "shown frame=\(NSStringFromRect(window?.frame ?? .zero))")
    }

    private func buildContent(in panel: NSPanel) {
        let background = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 11
        background.layer?.masksToBounds = true
        background.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = background

        let scrollView = NSScrollView(frame: .zero)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        textView.frame = scrollView.contentView.bounds
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        scrollView.documentView = textView

        statusLine.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(scrollView)
        background.addSubview(statusLine)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: background.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusLine.topAnchor),
            statusLine.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            statusLine.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            statusLine.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            statusLine.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func connectEvents() {
        textView.isEnteringExCommand = { [weak viewModel] in
            viewModel?.exCommandText != nil
        }
        textView.onKeyAction = { [weak viewModel] action in
            viewModel?.handle(action)
        }
        textView.onCommittedText = { [weak viewModel] text in
            viewModel?.insertCommittedText(text)
        }
        textView.onNativeSelection = { [weak viewModel] selection in
            viewModel?.setNativeSelection(selection)
        }
        viewModel.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            if self.lastLoggedMode != snapshot.mode {
                self.logger.debug(
                    "Panel",
                    "mode changed from=\(self.lastLoggedMode?.displayName ?? "none") "
                        + "to=\(snapshot.mode.displayName)"
                )
                self.lastLoggedMode = snapshot.mode
            }
            if let message = snapshot.message {
                self.logger.warning(
                    "Panel",
                    "status message received characterCount=\(message.count) "
                        + "isError=\(message.hasPrefix("E"))"
                )
            }
            self.textView.apply(snapshot: snapshot)
            self.statusLine.render(snapshot)
        }
        viewModel.onApplicationCommand = { [weak self] command in
            guard let self else { return }
            self.logger.info("Panel", "application command=\(String(describing: command))")
            Task { @MainActor in
                switch command {
                case .commitAndClose: await self.commit(close: true)
                case .commit: await self.commit(close: false)
                case .cancel: self.cancel()
                }
            }
        }
    }

    private func commit(close: Bool) async {
        logger.info("Panel", "commit started close=\(close)")
        do {
            let snapshot = try await viewModel.snapshotForCommit()
            let selection = snapshot.selection ?? .caret(at: snapshot.cursor)
            let selectionRange = TextCoordinateConverter.utf16Range(for: selection, in: snapshot.text)
            if close { window?.orderOut(nil) }
            let result = await commitCoordinator.commit(
                text: snapshot.text,
                selectionRange: selectionRange,
                restoreFocus: close
            )
            guard result != .failed else {
                logger.error("Panel", "commit failed for all write strategies")
                if close {
                    NSApp.activate(ignoringOtherApps: true)
                    window?.makeKeyAndOrderFront(nil)
                    window?.makeFirstResponder(textView)
                }
                statusLine.showMessage("Could not write to the original field")
                return
            }

            if close {
                logger.info("Panel", "commit succeeded strategy=\(String(describing: result)); closing")
                commitCoordinator.finish()
                await viewModel.reset()
            } else {
                logger.info("Panel", "commit succeeded strategy=\(String(describing: result)); staying open")
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
                window?.makeFirstResponder(textView)
                statusLine.showMessage("Committed", isError: false)
            }
        } catch {
            logger.error("Panel", error: error, context: "commit snapshot failed")
            statusLine.showMessage(error.localizedDescription)
        }
    }

    private func cancel() {
        logger.info("Panel", "cancel requested; original field will not be modified")
        window?.orderOut(nil)
        commitCoordinator.cancel()
        lastLoggedMode = nil
        Task { @MainActor [viewModel] in await viewModel.reset() }
    }

    private func positionPanel() {
        guard let panel = window else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            panel.center()
            return
        }
        let width = min(900, max(620, visibleFrame.width * 0.68))
        let height = min(560, max(360, visibleFrame.height * 0.54))
        panel.setContentSize(NSSize(width: width, height: height))
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.midY - height / 2
        ))
    }
}
