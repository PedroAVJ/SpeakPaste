import AVFoundation
import Foundation

struct MacAudioInputDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String

    var isContinuityDevice: Bool {
        name.localizedCaseInsensitiveContains("iPhone")
            || name.localizedCaseInsensitiveContains("Continuity")
    }

    var sourceLabel: String {
        isContinuityDevice ? "Continuity" : "Mac"
    }
}

enum MacAudioDeviceCatalog {
    static func availableInputs() -> [MacAudioInputDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        .devices
        .map { MacAudioInputDevice(id: $0.uniqueID, name: $0.localizedName) }
        .sorted {
            if $0.isContinuityDevice != $1.isContinuityDevice {
                return $0.isContinuityDevice
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
