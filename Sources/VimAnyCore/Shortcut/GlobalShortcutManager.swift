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
        keyCode: UInt32(kVK_ANSI_V),
        carbonModifiers: UInt32(cmdKey | optionKey | controlKey)
    )
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

    private var eventHandlerReference: EventHandlerRef?
    private var hotKeyReference: EventHotKeyRef?
    private let callback: @Sendable () -> Void
    private let defaults: UserDefaults

    public init(
        defaults: UserDefaults = .standard,
        callback: @escaping @Sendable () -> Void
    ) {
        self.defaults = defaults
        self.callback = callback
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
            unregister()
            throw GlobalShortcutError.registration(registrationStatus)
        }
    }

    public func update(shortcut: GlobalShortcut) throws {
        defaults.set(Int(shortcut.keyCode), forKey: Self.keyCodeDefaultsKey)
        defaults.set(Int(shortcut.carbonModifiers), forKey: Self.modifiersDefaultsKey)
        try register()
    }

    public func unregister() {
        if let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
            self.hotKeyReference = nil
        }
        if let eventHandlerReference {
            RemoveEventHandler(eventHandlerReference)
            self.eventHandlerReference = nil
        }
    }

    fileprivate func invoke() {
        callback()
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
