// Native shortcut regression harness. Run from the project directory:
// mkdir -p .build/qa .build/module-cache
// xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache \
//   Sources/MacFileManager/AppSupport.swift Tests/UIRegression/KeyboardShortcutRegression.swift \
//   -o .build/qa/keyboard-shortcut-regression
// .build/qa/keyboard-shortcut-regression
// Events are constructed in memory only: no event is posted or injected, no
// visible window is created, and the current keyboard layout is not changed.
import AppKit
import CoreGraphics

private struct ShortcutRegressionFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct KeyboardShortcutRegression {
    private static let shortcuts = ["a", "c", "x", "v", "z", "y", "l", "f", "t", "w", "r", "n"]

    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ShortcutRegressionFailure(description: message) }
    }

    private static func event(keyCode: CGKeyCode, flags: CGEventFlags) throws -> NSEvent {
        guard let keyboardEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else {
            throw ShortcutRegressionFailure(description: "Could not construct an in-memory keyboard event")
        }
        keyboardEvent.flags = flags
        guard let nativeEvent = NSEvent(cgEvent: keyboardEvent) else {
            throw ShortcutRegressionFailure(description: "Could not convert a keyboard event to NSEvent")
        }
        return nativeEvent
    }

    private static func scalars(_ string: String?) -> String {
        (string ?? "").unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
    }

    private static func run() throws {
        // Discover the physical keys for the active layout instead of assuming
        // US-QWERTY positions. The expected application commands remain a/c/z/etc.
        var keyCodes: [String: CGKeyCode] = [:]
        for code in CGKeyCode(0)...CGKeyCode(127) {
            let native = try event(keyCode: code, flags: .maskCommand)
            // Physical modifier keys become flagsChanged events, for which
            // AppKit's character-translation APIs are deliberately invalid.
            guard native.type == .keyDown || native.type == .keyUp else { continue }
            guard let command = native.characters(byApplyingModifiers: .command)?.lowercased(),
                  shortcuts.contains(command), keyCodes[command] == nil else { continue }
            keyCodes[command] = code
        }
        let variants: [(String, CGEventFlags)] = [
            ("Control", .maskControl),
            ("Command", .maskCommand),
            ("Control+Shift", [.maskControl, .maskShift]),
            ("Command+Shift", [.maskCommand, .maskShift])
        ]
        var ordinaryTextDifferences = 0
        for expected in shortcuts {
            guard let code = keyCodes[expected] else {
                throw ShortcutRegressionFailure(description: "The active layout has no discoverable Command-\(expected.uppercased()) key")
            }
            var results: [String] = []
            for (variant, flags) in variants {
                let native = try event(keyCode: code, flags: flags)
                let result = shortcutKey(for: native)
                try require(result == expected,
                    "\(variant)+\(expected.uppercased()) normalized to \(result.debugDescription), expected \(expected); ordinary characters were \(scalars(native.charactersIgnoringModifiers))")
                // Normalizing the key must leave Shift/Control intact for actions
                // such as Control+Shift+Z (Redo) and Control+Shift+N (New Folder).
                try require(native.modifierFlags.contains(.shift) == flags.contains(.maskShift), "Shortcut normalization changed Shift")
                try require(native.modifierFlags.contains(.control) == flags.contains(.maskControl), "Shortcut normalization changed Control")
                results.append(result)
            }
            try require(Set(results).count == 1, "Command, Control, and Shift variants disagree for \(expected)")
            let control = try event(keyCode: code, flags: .maskControl)
            if control.charactersIgnoringModifiers?.lowercased() != expected { ordinaryTextDifferences += 1 }
            if ["z", "y", "l", "f"].contains(expected) {
                print("\(expected.uppercased()): keyCode=\(code), ordinary=\(scalars(control.charactersIgnoringModifiers)), Control output=\(scalars(control.characters)), shortcut=\(shortcutKey(for: control))")
            }
        }
        // Reproduce the non-Latin character cache observed during the live bug,
        // even if the active input source changes before this harness runs.
        // The key codes still come from the current layout's shortcut positions.
        let arabicCharacters = ["z": "ئ", "y": "غ", "l": "م", "f": "ب"]
        var cachedCharacterCases = 0
        for expected in ["z", "y", "l", "f"] {
            let code = keyCodes[expected]!
            for (variant, flags) in variants {
                let control = flags.contains(.maskControl)
                let modifiers: NSEvent.ModifierFlags = control
                    ? (flags.contains(.maskShift) ? [.control, .shift] : .control)
                    : (flags.contains(.maskShift) ? [.command, .shift] : .command)
                let characters = control ? String(UnicodeScalar(UInt32(expected.utf8.first! - 96))!) : expected
                guard let cached = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                    timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                    charactersIgnoringModifiers: arabicCharacters[expected]!, isARepeat: false, keyCode: code) else {
                    throw ShortcutRegressionFailure(description: "Could not construct a cached-character fixture")
                }
                try require(cached.charactersIgnoringModifiers == arabicCharacters[expected], "Arabic fixture character cache was not retained")
                try require(shortcutKey(for: cached) == expected,
                    "\(variant)+\(expected.uppercased()) must use the native shortcut key despite an Arabic character cache")
                cachedCharacterCases += 1
            }
        }
        print("PASS: \(shortcuts.count * variants.count) shortcut cases; Command/Control and Shift variants agree without changing modifier flags")
        print("PASS: \(cachedCharacterCases) explicit Arabic character-cache cases for Undo, Redo, Address, and Search")
        print("Active-layout coverage: ordinary text differs from shortcut letters for \(ordinaryTextDifferences) of \(shortcuts.count) keys")
        if ordinaryTextDifferences == 0 {
            print("The active layout is Latin for these keys. Run with an Arabic or other non-Latin input layout to exercise the original regression.")
        }
    }
}
