import Carbon.HIToolbox

/// Registers a system-wide hotkey via Carbon `RegisterEventHotKey`, which —
/// unlike global NSEvent monitors — needs no Accessibility permission.
/// Default shortcut: ⌥⌘C (Option+Command+C).
final class HotKeyManager {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: UInt32 = UInt32(kVK_ANSI_C),
          modifiers: UInt32 = UInt32(optionKey | cmdKey),
          action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                Unmanaged<HotKeyManager>.fromOpaque(userData)
                    .takeUnretainedValue().action()
                return noErr
            },
            1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef)
        guard installStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: 0x434C_4442 /* "CLDB" */, id: 1)
        let regStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                            GetApplicationEventTarget(), 0, &ref)
        guard regStatus == noErr else { return nil }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
