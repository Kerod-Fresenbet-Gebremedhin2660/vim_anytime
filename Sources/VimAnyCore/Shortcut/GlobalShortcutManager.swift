import Carbon.HIToolbox
import Foundation

public struct GlobalShortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var carbonModifiers: UInt32

    public init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    public static let `default` = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_M),
        carbonModifiers: UInt32(controlKey)
    )

    public var displayName: String {
        var value = ""
        if carbonModifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        switch keyCode {
        case UInt32(kVK_ANSI_M): value += "M"
        case UInt32(kVK_ANSI_V): value += "V"
        default: value += "Key \(keyCode)"
        }
        return value
    }
}

public enum GlobalShortcutError: Error, LocalizedError {
    case eventHandler(OSStatus)
    case registration(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .eventHandler(let status):
            return "The global shortcut event handler could not be installed (\(status))."
        case .registration(let status):
            return "The global shortcut is already in use or could not be registered (\(status))."
        }
    }
}

public final class GlobalShortcutManager: @unchecked Sendable {
    public static let keyCodeDefaultsKey = "GlobalShortcutKeyCode"
    public static let modifiersDefaultsKey = "GlobalShortcutModifiers"
    private static let schemaVersionDefaultsKey = "GlobalShortcutSchemaVersion"
    private static let currentSchemaVersion = 2
    private static let legacyDefault = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_V),
        carbonModifiers: UInt32(cmdKey | optionKey | controlKey)
    )

    private var eventHandlerReference: EventHandlerRef?
    private var hotKeyReference: EventHotKeyRef?
    private let logger = DiagnosticLogger.shared
    private let callback: @Sendable () -> Void
    private let defaults: UserDefaults

    public init(
        defaults: UserDefaults = .standard,
        callback: @escaping @Sendable () -> Void
    ) {
        self.defaults = defaults
        self.callback = callback
        migrateLegacyDefaultIfNeeded()
        logger.debug("Shortcut", "manager initialized configured=\(configuredShortcut.displayName)")
    }

    deinit {
        unregister()
    }

    public var configuredShortcut: GlobalShortcut {
        let hasKeyCode = defaults.object(forKey: Self.keyCodeDefaultsKey) != nil
        let hasModifiers = defaults.object(forKey: Self.modifiersDefaultsKey) != nil
        guard hasKeyCode, hasModifiers else { return .default }
        return GlobalShortcut(
            keyCode: UInt32(defaults.integer(forKey: Self.keyCodeDefaultsKey)),
            carbonModifiers: UInt32(defaults.integer(forKey: Self.modifiersDefaultsKey))
        )
    }

    public func register() throws {
        logger.info("Shortcut", "registration started shortcut=\(configuredShortcut.displayName)")
        unregister()
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            vimAnyHotKeyHandler,
            1,
            &eventType,
            userData,
            &eventHandlerReference
        )
        guard handlerStatus == noErr else {
            logger.error("Shortcut", "event handler installation failed status=\(handlerStatus)")
            throw GlobalShortcutError.eventHandler(handlerStatus)
        }

        let shortcut = configuredShortcut
        let identifier = EventHotKeyID(signature: OSType(0x56414E59), id: 1) // "VANY"
        let registrationStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyReference
        )
        guard registrationStatus == noErr else {
            logger.error("Shortcut", "hotkey registration failed status=\(registrationStatus)")
            unregister()
            throw GlobalShortcutError.registration(registrationStatus)
        }
        logger.info("Shortcut", "registration succeeded shortcut=\(shortcut.displayName)")
    }

    public func update(shortcut: GlobalShortcut) throws {
        logger.info("Shortcut", "updating shortcut=\(shortcut.displayName)")
        defaults.set(Int(shortcut.keyCode), forKey: Self.keyCodeDefaultsKey)
        defaults.set(Int(shortcut.carbonModifiers), forKey: Self.modifiersDefaultsKey)
        defaults.set(Self.currentSchemaVersion, forKey: Self.schemaVersionDefaultsKey)
        try register()
    }

    public func unregister() {
        let wasRegistered = hotKeyReference != nil || eventHandlerReference != nil
        if let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
            self.hotKeyReference = nil
        }
        if let eventHandlerReference {
            RemoveEventHandler(eventHandlerReference)
            self.eventHandlerReference = nil
        }
        if wasRegistered { logger.info("Shortcut", "unregistered") }
    }

    fileprivate func invoke() {
        logger.info("Shortcut", "invoked shortcut=\(configuredShortcut.displayName)")
        callback()
    }

    private func migrateLegacyDefaultIfNeeded() {
        guard defaults.integer(forKey: Self.schemaVersionDefaultsKey) < Self.currentSchemaVersion else {
            return
        }

        let hasKeyCode = defaults.object(forKey: Self.keyCodeDefaultsKey) != nil
        let hasModifiers = defaults.object(forKey: Self.modifiersDefaultsKey) != nil
        let storedShortcut = GlobalShortcut(
            keyCode: UInt32(defaults.integer(forKey: Self.keyCodeDefaultsKey)),
            carbonModifiers: UInt32(defaults.integer(forKey: Self.modifiersDefaultsKey))
        )
        if !hasKeyCode || !hasModifiers || storedShortcut == Self.legacyDefault {
            logger.info("Shortcut", "migrating legacy default to=\(GlobalShortcut.default.displayName)")
            defaults.set(Int(GlobalShortcut.default.keyCode), forKey: Self.keyCodeDefaultsKey)
            defaults.set(Int(GlobalShortcut.default.carbonModifiers), forKey: Self.modifiersDefaultsKey)
        }
        defaults.set(Self.currentSchemaVersion, forKey: Self.schemaVersionDefaultsKey)
        logger.debug("Shortcut", "preferences schema migrated version=\(Self.currentSchemaVersion)")
    }
}

private let vimAnyHotKeyHandler: EventHandlerUPP = { _, _, userData in
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async {
        manager.invoke()
    }
    return noErr
}
