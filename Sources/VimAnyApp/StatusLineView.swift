import AppKit
import VimAnyCore

@MainActor
final class StatusLineView: NSView {
    private let modeLabel = NSTextField(labelWithString: "NORMAL")
    private let pendingLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let positionLabel = NSTextField(labelWithString: "1:1")
    private let progressLabel = NSTextField(labelWithString: "100%")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        modeLabel.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        modeLabel.alignment = .center
        modeLabel.wantsLayer = true
        modeLabel.layer?.cornerRadius = 4
        modeLabel.layer?.masksToBounds = true
        pendingLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        messageLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        messageLabel.lineBreakMode = .byTruncatingTail
        positionLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)

        let stack = NSStackView(views: [modeLabel, pendingLabel, messageLabel, positionLabel, progressLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        positionLabel.setContentHuggingPriority(.required, for: .horizontal)
        progressLabel.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            modeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
        ])
    }

    func render(_ snapshot: EditorSnapshot) {
        modeLabel.stringValue = snapshot.mode.displayName
        switch snapshot.mode {
        case .insert:
            modeLabel.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.2).cgColor
        case .replace:
            modeLabel.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.2).cgColor
        case .visual, .visualLine:
            modeLabel.layer?.backgroundColor = NSColor.systemPurple.withAlphaComponent(0.2).cgColor
        default:
            modeLabel.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        }

        var pending = ""
        if let count = snapshot.pendingCount { pending += String(count) }
        if let pendingOperator = snapshot.pendingOperator { pending += pendingOperator }
        pendingLabel.stringValue = pending
        pendingLabel.isHidden = pending.isEmpty

        messageLabel.stringValue = snapshot.command ?? snapshot.message ?? ""
        messageLabel.textColor = snapshot.message?.hasPrefix("E") == true ? .systemRed : .secondaryLabelColor
        let column = TextCoordinateConverter.displayColumn(for: snapshot.cursor, in: snapshot.text)
        positionLabel.stringValue = "\(snapshot.cursor.line + 1):\(column)"
        let lines = TextCoordinateConverter.lineCount(in: snapshot.text)
        let percentage = min(100, max(0, ((snapshot.cursor.line + 1) * 100) / lines))
        progressLabel.stringValue = "\(percentage)%"
    }

    func showMessage(_ message: String, isError: Bool = true) {
        messageLabel.stringValue = message
        messageLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }
}

