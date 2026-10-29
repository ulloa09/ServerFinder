import AppKit
import Carbon.HIToolbox

/// A key combination such as ⌥Space.
struct KeyShortcut: Codable, Equatable {
    var keyCode: UInt16
    /// Raw value of the ⌘ ⌥ ⌃ ⇧ modifier flags.
    var modifierFlags: UInt
    /// How the key is shown, e.g. "Space" or "F". Captured when the shortcut is recorded,
    /// so it matches the user's keyboard layout.
    var keyLabel: String

    static let defaultSearch = KeyShortcut(keyCode: UInt16(kVK_Space), modifierFlags: NSEvent.ModifierFlags.option.rawValue, keyLabel: "Space")

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierFlags) }

    /// "⌥ Space", "⌃⌘ F".
    var displayString: String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        let key = keyLabel == "Space" ? String(localized: "Space") : keyLabel
        return symbols + " " + key
    }

    /// Builds a shortcut from a key press, or `nil` if it can't be a global shortcut
    /// (it needs ⌘, ⌥ or ⌃, unless it's a function key).
    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let isFunctionKey = Self.functionKeyLabels[Int(event.keyCode)] != nil
        guard isFunctionKey || !modifiers.intersection([.command, .option, .control]).isEmpty else { return nil }
        self.keyCode = event.keyCode
        self.modifierFlags = modifiers.rawValue
        self.keyLabel = Self.label(for: event)
    }

    init(keyCode: UInt16, modifierFlags: UInt, keyLabel: String) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.keyLabel = keyLabel
    }

    private static func label(for event: NSEvent) -> String {
        if let special = specialKeyLabels[Int(event.keyCode)] ?? functionKeyLabels[Int(event.keyCode)] {
            return special
        }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }

    private static let specialKeyLabels: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    private static let functionKeyLabels: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    fileprivate var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}

/// A keyboard shortcut that works while any app is in front.
@MainActor
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onPress: () -> Void

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                // Carbon delivers hot key events on the main thread.
                MainActor.assumeIsolated { hotKey.onPress() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }

    /// Replaces the active shortcut. Returns `false` if another app already uses it.
    @discardableResult
    func register(_ shortcut: KeyShortcut?) -> Bool {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        guard let shortcut else { return true }
        let id = EventHotKeyID(signature: OSType(0x5346_4E44), id: 1) // "SFND"
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode), shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef
        )
        return status == noErr
    }
}
