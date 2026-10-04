import AppKit
import Carbon.HIToolbox

/// System-wide keyboard shortcut via Carbon's RegisterEventHotKey, which
/// (unlike key event monitors) needs no Accessibility permission.
@MainActor
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextId: UInt32 = 1
    private static var eventHandlerInstalled = false

    private var ref: EventHotKeyRef?
    private let id: UInt32

    init?(_ shortcut: Shortcut, handler: @escaping () -> Void) {
        Self.installEventHandlerIfNeeded()
        id = Self.nextId
        Self.nextId += 1

        let hotKeyID = EventHotKeyID(signature: OSType(0x4163_6369), id: id) // 'Acci'
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.carbonModifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr else { return nil }
        Self.handlers[id] = handler
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.handlers[id] = nil
    }

    private static func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr else { return status }
            let id = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKey.handlers[id]?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// A key plus modifiers, stored in UserDefaults as "keyCode:modifierFlags".
struct Shortcut: Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: NSEvent.ModifierFlags

    /// ⌃⌥⌘A, for Accio.
    static let defaultReveal = Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: [.control, .option, .command])

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection([.control, .option, .shift, .command])
    }

    init?(event: NSEvent) {
        let mods = event.modifierFlags.intersection([.control, .option, .shift, .command])
        // A global shortcut needs at least one of ⌃⌥⌘, or it would swallow plain typing.
        guard !mods.intersection([.control, .option, .command]).isEmpty else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods)
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":").compactMap { UInt($0) }
        guard parts.count == 2 else { return nil }
        self.init(keyCode: UInt32(parts[0]), modifiers: NSEvent.ModifierFlags(rawValue: parts[1]))
    }

    var rawValue: String { "\(keyCode):\(modifiers.rawValue)" }

    var carbonModifiers: UInt32 {
        var flags = 0
        if modifiers.contains(.control) { flags |= controlKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        if modifiers.contains(.command) { flags |= cmdKey }
        return UInt32(flags)
    }

    var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    /// The key as an NSMenuItem key equivalent, when it's a single character.
    var menuKeyEquivalent: String? {
        let name = Self.keyName(keyCode)
        return name.count == 1 && name.allSatisfy(\.isASCII) ? name.lowercased() : nil
    }

    private static func keyName(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: break
        }
        if let index = functionKeys.firstIndex(of: Int(keyCode)) { return "F\(index + 1)" }
        // Ask the current keyboard layout what the key types.
        guard
            let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "#\(keyCode)" }
        let layout = unsafeBitCast(data, to: CFData.self)
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = CFDataGetBytePtr(layout).withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) {
            UCKeyTranslate(
                $0, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars
            )
        }
        guard status == noErr, length > 0 else { return "#\(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }

    private static let functionKeys = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]
}
