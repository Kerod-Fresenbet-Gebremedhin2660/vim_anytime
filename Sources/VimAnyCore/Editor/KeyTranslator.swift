import AppKit
import Foundation

public enum TranslatedKeyAction: Equatable {
    case application(EditorApplicationCommand)
    case vim(VimKey)
    case useNativeTextInput
    case beginExCommand
    case appendExText(String)
    case deleteExCharacter
    case submitExCommand
    case cancelExCommand
    case ignored
}

public enum KeyTranslator {
    public static func translate(
        event: NSEvent,
        mode: VimMode,
        isEnteringExCommand: Bool
    ) -> TranslatedKeyAction {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let commandOnlyModifiers = modifiers.subtracting([.capsLock, .numericPad])

        if commandOnlyModifiers.contains(.command) {
            if isReturn(event), !commandOnlyModifiers.contains(.option), !commandOnlyModifiers.contains(.control) {
                return .application(.commitAndClose)
            }
            let character = event.charactersIgnoringModifiers?.lowercased()
            if character == "s" { return .application(.commit) }
            if character == "." { return .application(.cancel) }
            return .ignored
        }

        if isEnteringExCommand {
            switch event.keyCode {
            case 53: return .cancelExCommand
            case 36, 76: return .submitExCommand
            case 51, 117: return .deleteExCharacter
            default:
                guard !commandOnlyModifiers.contains(.control),
                      !commandOnlyModifiers.contains(.option),
                      let text = event.characters,
                      !text.isEmpty else { return .ignored }
                return .appendExText(text)
            }
        }

        if let special = specialKeyNotation(for: event, modifiers: commandOnlyModifiers) {
            return .vim(VimKey(special))
        }

        let charactersIgnoringModifiers = event.charactersIgnoringModifiers ?? ""
        if mode.isNormalLike,
           commandOnlyModifiers.isDisjoint(with: [.control, .option]),
           charactersIgnoringModifiers == ":" {
            return .beginExCommand
        }

        if commandOnlyModifiers.contains(.control) || commandOnlyModifiers.contains(.option) {
            guard let base = notationBase(from: charactersIgnoringModifiers) else { return .ignored }
            var components: [String] = []
            if commandOnlyModifiers.contains(.control) { components.append("C") }
            if commandOnlyModifiers.contains(.option) { components.append("M") }
            if commandOnlyModifiers.contains(.shift) { components.append("S") }
            components.append(base)
            return .vim(VimKey("<\(components.joined(separator: "-"))>"))
        }

        if mode.acceptsCommittedText {
            return .useNativeTextInput
        }

        guard let text = event.characters, !text.isEmpty else { return .ignored }
        return .vim(VimKey(text))
    }

    private static func specialKeyNotation(
        for event: NSEvent,
        modifiers: NSEvent.ModifierFlags
    ) -> String? {
        let base: String
        switch event.keyCode {
        case 53: base = "Esc"
        case 36, 76: base = "CR"
        case 51: base = "BS"
        case 117: base = "Del"
        case 48: base = modifiers.contains(.shift) ? "S-Tab" : "Tab"
        case 123: base = "Left"
        case 124: base = "Right"
        case 125: base = "Down"
        case 126: base = "Up"
        case 115: base = "Home"
        case 119: base = "End"
        case 116: base = "PageUp"
        case 121: base = "PageDown"
        default: return nil
        }

        let effective = modifiers.intersection([.control, .option])
        guard !effective.isEmpty else { return "<\(base)>" }
        var components: [String] = []
        if effective.contains(.control) { components.append("C") }
        if effective.contains(.option) { components.append("M") }
        components.append(base)
        return "<\(components.joined(separator: "-"))>"
    }

    private static func notationBase(from characters: String) -> String? {
        guard let character = characters.first else { return nil }
        if character == " " { return "Space" }
        if character == "<" { return "LT" }
        return String(character).lowercased()
    }

    private static func isReturn(_ event: NSEvent) -> Bool {
        event.keyCode == 36 || event.keyCode == 76
    }
}

