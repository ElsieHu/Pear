import Carbon.HIToolbox

/// Global hot keys (they work even when the app is not focused).
///
/// `⌃⌥L` toggles the floating lyrics, `⌃⌥K` locks/unlocks its position.
/// Control+Option is used deliberately: it collides with very few
/// system or third-party shortcuts.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    var onToggleLyrics: (() -> Void)?
    var onToggleLock: (() -> Void)?

    private let signature: OSType = 0x4C46444B // "LFDK"
    private var handlerRef: EventHandlerRef?
    private var registered: [UInt32: EventHotKeyRef] = [:]
    private var installed = false

    private init() {}

    func install() {
        guard !installed else { return }
        installed = true

        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                   eventKind: UInt32(kEventHotKeyPressed))]
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return OSStatus(eventNotHandledErr) }
                let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                return center.handle(id: hotKeyID.id)
            },
            1,
            &types,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )

        register(id: 1, keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(controlKey | optionKey))
        register(id: 2, keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey))
    }

    private func register(id: UInt32, keyCode: UInt32, modifiers: UInt32) {
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            registered[id] = ref
        }
    }

    private func handle(id: UInt32) -> OSStatus {
        switch id {
        case 1: onToggleLyrics?()
        case 2: onToggleLock?()
        default: return OSStatus(eventNotHandledErr)
        }
        return noErr
    }
}
