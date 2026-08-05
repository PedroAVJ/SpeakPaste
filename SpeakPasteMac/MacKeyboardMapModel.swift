import Carbon
import Foundation

/// The three physical keyboard shapes Apple ships. The shape changes where the
/// bound keys sit, so the map has to draw the board actually under the user's
/// hands rather than a generic picture of a keyboard.
enum MacPhysicalKeyboardShape: Equatable, Sendable {
    case ansi
    case iso
    case jis

    static var current: MacPhysicalKeyboardShape {
        shape(forLayoutType: Int(KBGetLayoutType(Int16(LMGetKbdType()))))
    }

    static func shape(forLayoutType layoutType: Int) -> MacPhysicalKeyboardShape {
        switch layoutType {
        case kKeyboardISO: .iso
        case kKeyboardJIS: .jis
        default: .ansi
        }
    }
}

/// One drawn key. Positions are in key units from the top-left of the map, so
/// the whole board scales with a single multiplier and nothing has to be
/// re-measured when the panel changes width.
struct MacKeyboardMapKey: Identifiable {
    let id: Int
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let binding: MacDictationKey?
}

/// How a bound key currently reads. The map is a mirror: every value here is
/// derived from the model's state, and none of them is clickable.
enum MacKeyIndication: Equatable, Sendable {
    /// Not bound at all — the overwhelming majority of the board.
    case blank
    /// Bound, but inert in this state: drawn quietly, because pressing it now
    /// would do nothing.
    case inert(symbol: String)
    case active(symbol: String, tint: MacKeyTint)
    /// Bound and live, but refusing: this key would only say "pause first".
    case refused(symbol: String)

    var symbol: String? {
        switch self {
        case .blank: nil
        case let .inert(symbol): symbol
        case let .active(symbol, _): symbol
        case let .refused(symbol): symbol
        }
    }

    var isActive: Bool {
        if case .active = self { return true }
        return false
    }
}

enum MacKeyTint: Equatable, Sendable {
    case source
    case deliver
    case discard
}

/// The state matrix, as one pure function. The panel and the tests read the
/// same table, so the picture on screen cannot drift away from what the keys
/// actually do.
enum MacKeyboardMapState {
    static func indications(
        phase: MacCapturePhase,
        activeSource: MacInputMode?,
        hasBankedSegments: Bool,
        canStartRecording: Bool
    ) -> [MacDictationKey: MacKeyIndication] {
        var result: [MacDictationKey: MacKeyIndication] = [:]
        for key in MacDictationKey.allCases {
            result[key] = indication(
                for: key,
                phase: phase,
                activeSource: activeSource,
                hasBankedSegments: hasBankedSegments,
                canStartRecording: canStartRecording
            )
        }
        return result
    }

    private static func indication(
        for key: MacDictationKey,
        phase: MacCapturePhase,
        activeSource: MacInputMode?,
        hasBankedSegments: Bool,
        canStartRecording: Bool
    ) -> MacKeyIndication {
        switch key {
        case .macSource, .iPhoneSource:
            sourceIndication(
                for: key,
                phase: phase,
                activeSource: activeSource,
                canStartRecording: canStartRecording
            )
        case .end:
            endIndication(phase: phase, hasBankedSegments: hasBankedSegments)
        case .cancel:
            cancelIndication(phase: phase, hasBankedSegments: hasBankedSegments)
        }
    }

    private static func sourceIndication(
        for key: MacDictationKey,
        phase: MacCapturePhase,
        activeSource: MacInputMode?,
        canStartRecording: Bool
    ) -> MacKeyIndication {
        guard let mode = key.inputMode else { return .blank }
        let sourceSymbol = mode == .mac ? "laptopcomputer" : "iphone"
        switch phase {
        case .ready, .succeeded, .failed:
            return canStartRecording
                ? .active(symbol: sourceSymbol, tint: .source)
                : .inert(symbol: sourceSymbol)
        case .paused:
            return .active(symbol: sourceSymbol, tint: .source)
        case .connecting:
            // Wrong-key correction: the attempt has produced no audio yet, so
            // the other source key just retargets it.
            return activeSource == mode
                ? .inert(symbol: sourceSymbol)
                : .active(symbol: sourceSymbol, tint: .source)
        case .recording:
            return activeSource == mode
                ? .active(symbol: "pause.fill", tint: .source)
                : .refused(symbol: sourceSymbol)
        case .finalizing:
            return .inert(symbol: sourceSymbol)
        }
    }

    private static func endIndication(
        phase: MacCapturePhase,
        hasBankedSegments: Bool
    ) -> MacKeyIndication {
        let symbol = "text.insert"
        switch phase {
        case .recording, .paused, .finalizing:
            return .active(symbol: symbol, tint: .deliver)
        case .connecting:
            // Inert when nothing is banked: there would be no text to close
            // over, and End must never come to mean "abort".
            return hasBankedSegments
                ? .active(symbol: symbol, tint: .deliver)
                : .inert(symbol: symbol)
        case .ready, .succeeded, .failed:
            return .inert(symbol: symbol)
        }
    }

    private static func cancelIndication(
        phase: MacCapturePhase,
        hasBankedSegments: Bool
    ) -> MacKeyIndication {
        let symbol = "xmark"
        switch phase {
        case .connecting, .recording:
            return .active(symbol: symbol, tint: .discard)
        case .paused:
            return hasBankedSegments
                ? .active(symbol: symbol, tint: .discard)
                : .inert(symbol: symbol)
        case .finalizing, .ready, .succeeded, .failed:
            return .inert(symbol: symbol)
        }
    }
}

/// The drawn boards. Fifteen key units wide in every shape, so the variants
/// stay the same size on screen and only their key geometry differs.
enum MacKeyboardMapLayout {
    static let unitsWide: Double = 15
    static var unitsTall: Double { bottomRowY + 1 }

    private static let functionRowHeight: Double = 0.62
    private static let rowGap: Double = 0.1
    private static var numberRowY: Double { functionRowHeight + rowGap }
    private static var letterRowY: Double { numberRowY + 1 + rowGap }
    private static var homeRowY: Double { letterRowY + 1 + rowGap }
    private static var shiftRowY: Double { homeRowY + 1 + rowGap }
    private static var bottomRowY: Double { shiftRowY + 1 + rowGap }

    static func keys(for shape: MacPhysicalKeyboardShape) -> [MacKeyboardMapKey] {
        var builder = Builder()
        functionRow(&builder)
        switch shape {
        case .ansi: ansiBody(&builder)
        case .iso: isoBody(&builder)
        case .jis: jisBody(&builder)
        }
        bottomRow(&builder, shape: shape)
        return builder.keys
    }

    private static func functionRow(_ builder: inout Builder) {
        builder.startRow(y: 0, height: functionRowHeight)
        builder.add(width: 1.5, binding: .cancel)
        builder.addRepeating(count: 12)
        builder.add(width: 1.5)
    }

    private static func ansiBody(_ builder: inout Builder) {
        builder.startRow(y: numberRowY)
        builder.addRepeating(count: 13)
        builder.add(width: 2)

        builder.startRow(y: letterRowY)
        builder.add(width: 1.5)
        builder.addRepeating(count: 12)
        builder.add(width: 1.5)

        builder.startRow(y: homeRowY)
        builder.add(width: 1.75)
        builder.addRepeating(count: 11)
        builder.add(width: 2.25)

        builder.startRow(y: shiftRowY)
        builder.add(width: 2.25)
        builder.addRepeating(count: 10)
        builder.add(width: 2.75)
    }

    private static func isoBody(_ builder: inout Builder) {
        builder.startRow(y: numberRowY)
        builder.addRepeating(count: 13)
        builder.add(width: 2)

        // The tall, narrow return spanning the letter and home rows is the
        // unmistakable ISO tell, along with the extra key to the left of Z.
        builder.startRow(y: letterRowY)
        builder.add(width: 1.5)
        builder.addRepeating(count: 12)
        builder.add(width: 1.5, height: 2 + rowGap)

        builder.startRow(y: homeRowY)
        builder.add(width: 1.5)
        builder.addRepeating(count: 12)

        builder.startRow(y: shiftRowY)
        builder.add(width: 1.25)
        builder.addRepeating(count: 11)
        builder.add(width: 2.75)
    }

    private static func jisBody(_ builder: inout Builder) {
        builder.startRow(y: numberRowY)
        builder.addRepeating(count: 14)
        builder.add(width: 1)

        builder.startRow(y: letterRowY)
        builder.add(width: 1.5)
        builder.addRepeating(count: 12)
        builder.add(width: 1.5, height: 2 + rowGap)

        builder.startRow(y: homeRowY)
        builder.add(width: 1.5)
        builder.addRepeating(count: 12)

        builder.startRow(y: shiftRowY)
        builder.add(width: 1.5)
        builder.addRepeating(count: 11)
        builder.add(width: 2.5)
    }

    private static func bottomRow(
        _ builder: inout Builder,
        shape: MacPhysicalKeyboardShape
    ) {
        builder.startRow(y: bottomRowY)
        builder.add(width: 1, binding: .end)
        builder.add(width: 1)
        builder.add(width: 1)
        builder.add(width: 1.25)
        switch shape {
        case .ansi, .iso:
            builder.add(width: 5.5)
        case .jis:
            // JIS trades space-bar width for the two input-mode keys flanking it.
            builder.add(width: 1)
            builder.add(width: 3.5)
            builder.add(width: 1)
        }
        builder.add(width: 1.25, binding: .macSource)
        builder.add(width: 1, binding: .iPhoneSource)
        builder.add(width: 1)
        builder.addStackedPair(width: 1)
        builder.add(width: 1)
    }

    private struct Builder {
        private(set) var keys: [MacKeyboardMapKey] = []
        private var x: Double = 0
        private var y: Double = 0
        private var height: Double = 1

        mutating func startRow(y: Double, height: Double = 1) {
            self.x = 0
            self.y = y
            self.height = height
        }

        mutating func add(
            width: Double,
            height: Double? = nil,
            binding: MacDictationKey? = nil
        ) {
            keys.append(
                MacKeyboardMapKey(
                    id: keys.count,
                    x: x,
                    y: y,
                    width: width,
                    height: height ?? self.height,
                    binding: binding
                )
            )
            x += width
        }

        mutating func addRepeating(count: Int) {
            for _ in 0..<count { add(width: 1) }
        }

        /// The half-height up/down pair in the arrow cluster.
        mutating func addStackedPair(width: Double) {
            let half = height / 2
            let top = y
            add(width: width, height: half)
            x -= width
            y = top + half
            add(width: width, height: half)
            y = top
        }
    }
}
