import Carbon

/// A system-wide keyboard shortcut (Carbon hot key: no permissions needed), registered exclusively so
/// it wins over the same keys in other apps. Each hot key has its own id, and its handler lets the
/// others' presses through.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void
    private let id: UInt32
    private static var nextID: UInt32 = 1
    private static let signature = OSType(0x5343_544C) // 'SCTL'

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        id = Self.nextID
        Self.nextID += 1
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
            var pressed = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                         nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard read == noErr, pressed.signature == HotKey.signature, pressed.id == hotKey.id else {
                return OSStatus(eventNotHandledErr) // another hot key: pass it on
            }
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard status == noErr else { return nil }
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        // Exclusive: these keys go to ScreenControl alone, even if another app registers them too.
        guard RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(),
                                  OptionBits(kEventHotKeyExclusive), &hotKeyRef) == noErr else {
            RemoveEventHandler(handlerRef)
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
