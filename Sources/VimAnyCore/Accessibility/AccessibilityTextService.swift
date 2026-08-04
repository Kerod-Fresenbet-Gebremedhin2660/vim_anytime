import AppKit
import ApplicationServices
import Foundation

public enum AccessibilityTextError: Error, LocalizedError {
    case permissionDenied
    case noFocusedApplication
    case noFocusedTextElement
    case valueUnavailable

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Accessibility permission is required to read the focused text field."
        case .noFocusedApplication:
            return "No focused application was found."
        case .noFocusedTextElement:
            return "The focused control is not an accessible text field."
        case .valueUnavailable:
            return "The focused control does not expose plain text through Accessibility."
        }
    }
}

public final class AccessibilityTextTarget {
    fileprivate let applicationElement: AXUIElement
    fileprivate let textElement: AXUIElement
    public let processIdentifier: pid_t

    init(applicationElement: AXUIElement, textElement: AXUIElement, processIdentifier: pid_t) {
        self.applicationElement = applicationElement
        self.textElement = textElement
        self.processIdentifier = processIdentifier
    }

    /// Test-only construction remains internal and is available through `@testable import`.
    convenience init(testProcessIdentifier: pid_t = 0) {
        self.init(
            applicationElement: AXUIElementCreateApplication(testProcessIdentifier),
            textElement: AXUIElementCreateSystemWide(),
            processIdentifier: testProcessIdentifier
        )
    }
}

public struct CapturedTextField {
    public let text: String
    public let selectionRange: NSRange
    public let target: AccessibilityTextTarget
    public let applicationName: String?

    public init(
        text: String,
        selectionRange: NSRange,
        target: AccessibilityTextTarget,
        applicationName: String?
    ) {
        self.text = text
        self.selectionRange = selectionRange
        self.target = target
        self.applicationName = applicationName
    }

    public var editorSelection: EditorSelection {
        TextCoordinateConverter.editorSelection(fromUTF16Range: selectionRange, in: text)
    }
}

@MainActor
public protocol AccessibilityTextServicing: AnyObject {
    func captureFocusedTextField() throws -> CapturedTextField
    func readText(from target: AccessibilityTextTarget) -> String?
    func write(text: String, selectionRange: NSRange, to target: AccessibilityTextTarget) -> Bool
    func writeSelection(_ selectionRange: NSRange, to target: AccessibilityTextTarget)
    func restoreFocus(to target: AccessibilityTextTarget)
}

@MainActor
public final class AccessibilityTextService: AccessibilityTextServicing {
    private let logger = DiagnosticLogger.shared
    private let systemWideElement = AXUIElementCreateSystemWide()

    public init() {}

    public static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    public static func requestPermissionPrompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        DiagnosticLogger.shared.info(
            "Accessibility",
            "permission check with prompt completed trusted=\(trusted)"
        )
    }

    public func captureFocusedTextField() throws -> CapturedTextField {
        logger.info("Accessibility", "focused field capture started trusted=\(Self.isTrusted)")
        guard Self.isTrusted else {
            logger.error("Accessibility", "focused field capture denied by TCC")
            throw AccessibilityTextError.permissionDenied
        }

        guard let application = copyElementAttribute(
            kAXFocusedApplicationAttribute as CFString,
            from: systemWideElement
        ) else {
            logger.error("Accessibility", "kAXFocusedApplicationAttribute unavailable")
            throw AccessibilityTextError.noFocusedApplication
        }

        guard let element = copyElementAttribute(
            kAXFocusedUIElementAttribute as CFString,
            from: application
        ) else {
            logger.error("Accessibility", "kAXFocusedUIElementAttribute unavailable")
            throw AccessibilityTextError.noFocusedTextElement
        }

        guard let text = copyAttribute(kAXValueAttribute as CFString, from: element) as? String else {
            logger.error("Accessibility", "focused element has no plain String AX value")
            throw AccessibilityTextError.valueUnavailable
        }

        var processIdentifier: pid_t = 0
        AXUIElementGetPid(application, &processIdentifier)
        let selectedRange = copyRangeAttribute(kAXSelectedTextRangeAttribute as CFString, from: element)
            ?? NSRange(location: text.utf16.count, length: 0)
        let applicationName = NSRunningApplication(processIdentifier: processIdentifier)?.localizedName
        let target = AccessibilityTextTarget(
            applicationElement: application,
            textElement: element,
            processIdentifier: processIdentifier
        )
        logger.info(
            "Accessibility",
            "capture succeeded app=\(applicationName ?? "unknown") pid=\(processIdentifier) "
                + "utf16Length=\(text.utf16.count) selection=\(NSStringFromRange(selectedRange))"
        )
        return CapturedTextField(
            text: text,
            selectionRange: selectedRange,
            target: target,
            applicationName: applicationName
        )
    }

    public func write(
        text: String,
        selectionRange: NSRange,
        to target: AccessibilityTextTarget
    ) -> Bool {
        let result = AXUIElementSetAttributeValue(
            target.textElement,
            kAXValueAttribute as CFString,
            text as CFTypeRef
        )
        guard result == .success else {
            logger.warning(
                "Accessibility",
                "direct AX value write failed pid=\(target.processIdentifier) "
                    + "error=\(result.rawValue) utf16Length=\(text.utf16.count)"
            )
            return false
        }
        logger.info(
            "Accessibility",
            "direct AX value write succeeded pid=\(target.processIdentifier) "
                + "utf16Length=\(text.utf16.count)"
        )
        writeSelection(selectionRange, to: target)
        return true
    }

    public func readText(from target: AccessibilityTextTarget) -> String? {
        guard let text = copyAttribute(
            kAXValueAttribute as CFString,
            from: target.textElement
        ) as? String else {
            logger.warning(
                "Accessibility",
                "target value verification unavailable pid=\(target.processIdentifier)"
            )
            return nil
        }
        logger.debug(
            "Accessibility",
            "target value verification read pid=\(target.processIdentifier) "
                + "utf16Length=\(text.utf16.count)"
        )
        return text
    }

    public func writeSelection(_ selectionRange: NSRange, to target: AccessibilityTextTarget) {
        var range = CFRange(location: selectionRange.location, length: selectionRange.length)
        guard let value = AXValueCreate(.cfRange, &range) else {
            logger.error("Accessibility", "could not create AX selection value")
            return
        }
        let result = AXUIElementSetAttributeValue(
            target.textElement,
            kAXSelectedTextRangeAttribute as CFString,
            value
        )
        if result == .success {
            logger.debug(
                "Accessibility",
                "selection write succeeded pid=\(target.processIdentifier) "
                    + "range=\(NSStringFromRange(selectionRange))"
            )
        } else {
            logger.warning(
                "Accessibility",
                "selection write failed pid=\(target.processIdentifier) error=\(result.rawValue) "
                    + "range=\(NSStringFromRange(selectionRange))"
            )
        }
    }

    public func restoreFocus(to target: AccessibilityTextTarget) {
        logger.info("Accessibility", "restoring focus pid=\(target.processIdentifier)")
        if let application = NSRunningApplication(processIdentifier: target.processIdentifier) {
            let activated = application.activate(options: [.activateIgnoringOtherApps])
            logger.debug("Accessibility", "application activation result=\(activated)")
        } else {
            logger.warning(
                "Accessibility",
                "target process no longer has an NSRunningApplication pid=\(target.processIdentifier)"
            )
        }
        let applicationFocusResult = AXUIElementSetAttributeValue(
            target.applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            target.textElement
        )
        let elementFocusResult = AXUIElementSetAttributeValue(
            target.textElement,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        logger.debug(
            "Accessibility",
            "focus AX results application=\(applicationFocusResult.rawValue) "
                + "element=\(elementFocusResult.rawValue)"
        )
    }

    private func copyAttribute(_ attribute: CFString, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else {
            logger.warning(
                "Accessibility",
                "attribute read failed attribute=\(attribute) error=\(result.rawValue)"
            )
            return nil
        }
        return value
    }

    private func copyElementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        guard let value = copyAttribute(attribute, from: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func copyRangeAttribute(_ attribute: CFString, from element: AXUIElement) -> NSRange? {
        guard let value = copyAttribute(attribute, from: element),
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range), range.location >= 0, range.length >= 0 else {
            return nil
        }
        return NSRange(location: range.location, length: range.length)
    }
}
