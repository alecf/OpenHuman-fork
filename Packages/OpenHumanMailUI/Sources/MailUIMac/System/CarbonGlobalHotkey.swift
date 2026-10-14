import AppKit
import Carbon
import MailModel

@MainActor
public final class CarbonGlobalHotkey: GlobalHotkeyRegistering {
    public static let shared = CarbonGlobalHotkey()

    nonisolated static let signature: OSType = 0x4F48_4D4C

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (@MainActor () -> Void)?
    private var registered: (hotkey: GlobalHotkey, code: UInt32)?
    private var inputSourceObserver: (any NSObjectProtocol)?

    public init() {}

    isolated deinit {
        if let inputSourceObserver { DistributedNotificationCenter.default().removeObserver(inputSourceObserver) }
    }

    public func register(_ hotkey: GlobalHotkey, action: @escaping @MainActor () -> Void) throws {
        unregister()
        guard let code = Self.layoutKeyCode(hotkey.key) ?? Self.keyCode(hotkey.key) else {
            throw GlobalHotkeyError.unsupportedKey(hotkey.key)
        }
        try installHandler()
        try install(code, hotkey)
        self.action = action
        observeInputSources()
    }

    public func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        action = nil
        registered = nil
    }

    private func install(_ code: UInt32, _ hotkey: GlobalHotkey) throws {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(code, Self.carbonModifiers(hotkey.modifiers),
                                         EventHotKeyID(signature: Self.signature, id: 1), GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { throw GlobalHotkeyError.refused(status) }
        hotKey = ref
        registered = (hotkey, code)
    }

    private func fire() { action?() }

    static func layoutKeyCode(_ key: String, on layout: ASCIIKeyLayout = .shared) -> UInt32? {
        guard key.count == 1, let scalar = key.unicodeScalars.first, scalar.isASCII, scalar.properties.isAlphabetic
        else { return nil }
        return layout.keyCode(typing: key).map(UInt32.init)
    }

    private func observeInputSources() {
        guard inputSourceObserver == nil else { return }
        let name = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(forName: name, object: nil,
                                                                                  queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.inputSourceChanged() }
        }
    }

    private func inputSourceChanged() {
        guard let registered, let hotKey, let code = Self.layoutKeyCode(registered.hotkey.key),
              code != registered.code else { return }
        UnregisterEventHotKey(hotKey)
        self.hotKey = nil
        do {
            try install(code, registered.hotkey)
        } catch {
            try? install(registered.code, registered.hotkey)
        }
    }

    private func installHandler() throws {
        guard handler == nil else { return }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var ref: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                         MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard read == noErr, id.signature == CarbonGlobalHotkey.signature else { return OSStatus(eventNotHandledErr) }
            Task { @MainActor in CarbonGlobalHotkey.shared.fire() }
            return noErr
        }, 1, &pressed, nil, &ref)
        guard status == noErr, let ref else { throw GlobalHotkeyError.refused(status) }
        handler = ref
    }

    nonisolated static func keyCode(_ key: String) -> UInt32? {
        keyCodes[key.uppercased()].map(UInt32.init)
    }

    nonisolated static let keyCodes: [String: Int] = [
        "A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D, "E": kVK_ANSI_E, "F": kVK_ANSI_F,
        "G": kVK_ANSI_G, "H": kVK_ANSI_H, "I": kVK_ANSI_I, "J": kVK_ANSI_J, "K": kVK_ANSI_K, "L": kVK_ANSI_L,
        "M": kVK_ANSI_M, "N": kVK_ANSI_N, "O": kVK_ANSI_O, "P": kVK_ANSI_P, "Q": kVK_ANSI_Q, "R": kVK_ANSI_R,
        "S": kVK_ANSI_S, "T": kVK_ANSI_T, "U": kVK_ANSI_U, "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X,
        "Y": kVK_ANSI_Y, "Z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "5": kVK_ANSI_5,
        "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    ]

    nonisolated static func carbonModifiers(_ modifiers: GlobalHotkey.Modifiers) -> UInt32 {
        var bits = 0
        if modifiers.contains(.command) { bits |= cmdKey }
        if modifiers.contains(.option) { bits |= optionKey }
        if modifiers.contains(.control) { bits |= controlKey }
        if modifiers.contains(.shift) { bits |= shiftKey }
        return UInt32(bits)
    }
}
