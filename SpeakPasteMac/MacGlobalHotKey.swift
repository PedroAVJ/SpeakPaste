import Carbon.HIToolbox
import Foundation

private func speakPasteHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let address = UInt(bitPattern: userData)
    DispatchQueue.main.async {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
        let hotKey = Unmanaged<MacGlobalHotKey>.fromOpaque(pointer).takeUnretainedValue()
        hotKey.performAction()
    }
    return noErr
}

@MainActor
final class MacGlobalHotKey {
    private var handler: EventHandlerRef?
    private var reference: EventHotKeyRef?
    private var action: (() -> Void)?

    func install(action: @escaping () -> Void) {
        uninstall()
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            speakPasteHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )

        let signature = OSType(UInt32(ascii: "SPST"))
        let hotKeyID = EventHotKeyID(signature: signature, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(controlKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
    }

    func uninstall() {
        if let reference {
            UnregisterEventHotKey(reference)
        }
        if let handler {
            RemoveEventHandler(handler)
        }
        reference = nil
        handler = nil
        action = nil
    }

    fileprivate func performAction() {
        action?()
    }

}

private extension UInt32 {
    init(ascii value: String) {
        self = value.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
