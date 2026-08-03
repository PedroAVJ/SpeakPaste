import Foundation

/// Pure verification for accessibility-readable paste destinations.
///
/// Seeing the dictated text somewhere in the final value is not proof that the
/// paste succeeded: the field may already contain that phrase while an
/// unrelated autocorrection changes something else. We only call delivery
/// confirmed when the final UTF-16 value is exactly the original value plus one
/// insertion of the requested text.
enum MacPasteVerification {
    static func isExactInsertion(
        _ insertedText: String,
        before: String?,
        after: String?
    ) -> Bool {
        guard
            !insertedText.isEmpty,
            let before,
            let after
        else {
            return false
        }

        let inserted = Array(insertedText.utf16)
        let original = Array(before.utf16)
        let final = Array(after.utf16)
        guard final.count == original.count + inserted.count else { return false }

        for offset in 0...original.count {
            guard final[offset..<(offset + inserted.count)].elementsEqual(inserted) else {
                continue
            }
            guard final[..<offset].elementsEqual(original[..<offset]) else {
                continue
            }
            guard final[(offset + inserted.count)...].elementsEqual(original[offset...]) else {
                continue
            }
            return true
        }

        return false
    }
}
