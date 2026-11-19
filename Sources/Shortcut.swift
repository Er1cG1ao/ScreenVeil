import AppKit
import Carbon
import CoreGraphics

struct Shortcut: Codable, Equatable {
    static let standard = Shortcut(key: UInt16(kVK_ANSI_L), flags: CGEventFlags([.maskCommand, .maskShift]).rawValue,
                                   keyLabel: "L")
    private static let modifiers: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn]

    let key: UInt16
    let flags: UInt64
    let keyLabel: String

    var label: String {
        let flags = CGEventFlags(rawValue: flags)
        return (flags.contains(.maskControl) ? "⌃" : "") +
            (flags.contains(.maskAlternate) ? "⌥" : "") +
            (flags.contains(.maskShift) ? "⇧" : "") +
            (flags.contains(.maskCommand) ? "⌘" : "") + keyLabel
    }

    var carbonModifiers: UInt32 {
        let flags = CGEventFlags(rawValue: flags)
        var result: UInt32 = 0
        if flags.contains(.maskCommand) { result |= UInt32(cmdKey) }
        if flags.contains(.maskShift) { result |= UInt32(shiftKey) }
        if flags.contains(.maskAlternate) { result |= UInt32(optionKey) }
        if flags.contains(.maskControl) { result |= UInt32(controlKey) }
        return result
    }

    static func recorded(from event: NSEvent) -> Shortcut? {
        let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)).intersection(modifiers)
        guard !flags.intersection([.maskCommand, .maskAlternate, .maskControl]).isEmpty,
              !flags.contains(.maskSecondaryFn),
              let keyLabel = keyLabel(for: event) else { return nil }
        // macOS handles these before normal application keyboard delivery.
        let command: CGEventFlags = [.maskCommand]
        if event.keyCode == kVK_Tab, flags.contains(.maskCommand) { return nil }
        if event.keyCode == kVK_Space, flags == command { return nil }
        if event.keyCode == kVK_Escape, flags == [.maskCommand, .maskAlternate] { return nil }
        return Shortcut(key: event.keyCode, flags: flags.rawValue, keyLabel: keyLabel)
    }

    private static func keyLabel(for event: NSEvent) -> String? {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Escape: return "⎋"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "Page Up"
        case kVK_PageDown: return "Page Down"
        default:
            let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9,
                                kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17,
                                kVK_F18, kVK_F19, kVK_F20]
            if let index = functionKeys.firstIndex(of: Int(event.keyCode)) { return "F\(index + 1)" }
            guard let character = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers,
                  character.count == 1,
                  character.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
            return character.uppercased()
        }
    }

    func matches(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.keyboardEventKeycode) == Int64(key) &&
            event.getIntegerValueField(.keyboardEventAutorepeat) == 0 &&
            event.flags.intersection(Self.modifiers).rawValue == flags
    }
}

final class GlobalShortcut {
    private static var nextID: UInt32 = 0
    private let id: UInt32
    private var handler: EventHandlerRef?
    private var registration: EventHotKeyRef?
    private var pressed = false
    private let onRelease: () -> Void

    init?(shortcut: Shortcut, onRelease: @escaping () -> Void) {
        Self.nextID &+= 1
        id = Self.nextID
        self.onRelease = onRelease
        var events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let target = GetApplicationEventTarget()
        let status = InstallEventHandler(target, { _, event, pointer in
            guard let event, let pointer else { return OSStatus(eventNotHandledErr) }
            let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(pointer).takeUnretainedValue()
            return shortcut.handle(event)
        }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: 0x53564549, id: id)
        guard RegisterEventHotKey(UInt32(shortcut.key), shortcut.carbonModifiers, hotKeyID,
                                  target, UInt32(kEventHotKeyExclusive), &registration) == noErr else { return nil }
    }

    deinit {
        if let registration { UnregisterEventHotKey(registration) }
        if let handler { RemoveEventHandler(handler) }
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var id = EventHotKeyID()
        guard GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                EventParamType(typeEventHotKeyID), nil,
                                MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
              id.signature == 0x53564549, id.id == self.id else { return OSStatus(eventNotHandledErr) }

        if GetEventKind(event) == UInt32(kEventHotKeyPressed) {
            pressed = true
        } else if pressed {
            pressed = false
            onRelease()
        }
        return noErr
    }
}
