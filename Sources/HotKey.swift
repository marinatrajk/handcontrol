import Carbon.HIToolbox

/// A system-wide keyboard shortcut. Uses the Carbon hot key API, which needs no extra permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var installed = false

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        Self.installHandler()
        let id = Self.nextID
        Self.nextID += 1
        Self.actions[id] = action
        let hotKeyID = EventHotKeyID(signature: OSType(0x4841_4E44), id: id)   // 'HAND'
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKey.actions[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
