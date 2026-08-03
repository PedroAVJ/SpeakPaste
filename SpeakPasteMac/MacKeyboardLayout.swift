import AppKit
import Carbon
import CoreGraphics
import Foundation

/// Resolves the virtual key code that actually produces a given character on
/// the layout the user is typing in right now.
///
/// Hard-coding 0x09 for "V" is only correct on QWERTY-like layouts. On Dvorak,
/// Colemak, and several European layouts that key code is a different letter,
/// so a synthesized ⌘V silently becomes some other command in the user's
/// editor — and `CGEvent.post` reports nothing either way.
enum MacKeyboardLayout {
    private static let cache = MacKeyCodeCache()

    /// Virtual key code for "v" on the current layout, falling back to the
    /// ANSI position when the layout cannot be read.
    static var pasteKeyCode: CGKeyCode {
        cache.keyCode(for: "v") ?? 0x09
    }

    static func startObservingLayoutChanges() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: nil
        ) { _ in
            cache.invalidate()
        }
    }
}

private final class MacKeyCodeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved: [Character: CGKeyCode?] = [:]

    func invalidate() {
        lock.lock()
        resolved.removeAll()
        lock.unlock()
    }

    func keyCode(for character: Character) -> CGKeyCode? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = resolved[character] { return cached }
        let found = Self.scanLayout(for: character)
        resolved[character] = found
        return found
    }

    private static func scanLayout(for character: Character) -> CGKeyCode? {
        guard
            let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let rawLayout = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(rawLayout).takeUnretainedValue() as Data

        return layoutData.withUnsafeBytes { buffer -> CGKeyCode? in
            guard let header = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }
            for keyCode in 0..<CGKeyCode(128) {
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    header,
                    UInt16(keyCode),
                    UInt16(kUCKeyActionDown),
                    0, // no modifiers: the unshifted character
                    UInt32(LMGetKbdType()),
                    UInt32(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    characters.count,
                    &length,
                    &characters
                )
                guard status == noErr, length > 0 else { continue }
                if String(utf16CodeUnits: characters, count: length) == String(character) {
                    return keyCode
                }
            }
            return nil
        }
    }
}
