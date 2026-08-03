import Carbon.HIToolbox
import Foundation
import XCTest
@testable import VimAnyCore

final class GlobalShortcutManagerTests: XCTestCase {
    func testDefaultShortcutIsControlM() {
        XCTAssertEqual(GlobalShortcut.default.keyCode, UInt32(kVK_ANSI_M))
        XCTAssertEqual(GlobalShortcut.default.carbonModifiers, UInt32(controlKey))
        XCTAssertEqual(GlobalShortcut.default.displayName, "⌃M")
    }

    func testLegacyDefaultMigratesToControlM() {
        withDefaults { defaults in
            defaults.set(Int(kVK_ANSI_V), forKey: GlobalShortcutManager.keyCodeDefaultsKey)
            defaults.set(
                Int(cmdKey | optionKey | controlKey),
                forKey: GlobalShortcutManager.modifiersDefaultsKey
            )

            let manager = GlobalShortcutManager(defaults: defaults, callback: {})
            XCTAssertEqual(manager.configuredShortcut, .default)
        }
    }

    func testCustomShortcutIsPreservedDuringMigration() {
        withDefaults { defaults in
            defaults.set(Int(kVK_ANSI_V), forKey: GlobalShortcutManager.keyCodeDefaultsKey)
            defaults.set(Int(controlKey), forKey: GlobalShortcutManager.modifiersDefaultsKey)

            let manager = GlobalShortcutManager(defaults: defaults, callback: {})
            XCTAssertEqual(
                manager.configuredShortcut,
                GlobalShortcut(
                    keyCode: UInt32(kVK_ANSI_V),
                    carbonModifiers: UInt32(controlKey)
                )
            )
        }
    }

    private func withDefaults(_ operation: (UserDefaults) -> Void) {
        let suiteName = "dev.vimany.shortcut-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        operation(defaults)
    }
}
