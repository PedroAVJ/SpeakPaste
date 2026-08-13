import AVFoundation
import CoreAudio
import Foundation

struct MacAudioInputDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// Resolved from Core Audio's transport type rather than guessed from the
    /// display name. A device called "Pedro's iPhone Microphone" only reads as
    /// Continuity in English; the transport type is the same on every system
    /// locale, and it does not misfire on, say, a USB mic named "iPhone Mic".
    let isContinuityDevice: Bool
    var isBuiltInDevice: Bool {
        transportType == kAudioDeviceTransportTypeBuiltIn
    }
    /// Nil means Core Audio did not identify the transport. Unknown transport
    /// is never promoted to Continuity based on a localized/device-given name.
    let transportType: UInt32?
    /// Core Audio's input volume scalar when the device exposes one. Continuity
    /// microphones commonly do not; `nil` means unavailable, not full volume.
    let inputVolume: Float?

    var sourceLabel: String {
        switch transportType {
        case kAudioDeviceTransportTypeContinuityCaptureWired:
            "Continuity · wired"
        case kAudioDeviceTransportTypeContinuityCaptureWireless:
            "Continuity · wireless"
        case kAudioDeviceTransportTypeBuiltIn:
            "Built-in"
        case kAudioDeviceTransportTypeUSB:
            "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            "Bluetooth"
        case .some(_):
            "External"
        case .none:
            "Unknown transport"
        }
    }
}

enum MacAudioDeviceCatalog {
    static func availableInputs() -> [MacAudioInputDevice] {
        let transports = MacCoreAudioTransport.transportTypesByDeviceUID()
        let inputVolumes = MacCoreAudioTransport.inputVolumesByDeviceUID()

        return AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        .devices
        .map { device in
            MacAudioInputDevice(
                id: device.uniqueID,
                name: device.localizedName,
                isContinuityDevice: isContinuity(transportType: transports[device.uniqueID]),
                transportType: transports[device.uniqueID],
                inputVolume: inputVolumes[device.uniqueID]
            )
        }
        .sorted {
            if $0.isContinuityDevice != $1.isContinuityDevice {
                return $0.isContinuityDevice
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func isContinuity(transportType: UInt32?) -> Bool {
        transportType == kAudioDeviceTransportTypeContinuityCaptureWired
            || transportType == kAudioDeviceTransportTypeContinuityCaptureWireless
    }
}

enum MacCoreAudioTransport {
    /// Maps each input device's UID — the same string AVCaptureDevice reports as
    /// `uniqueID` — to its Core Audio transport type.
    static func transportTypesByDeviceUID() -> [String: UInt32] {
        var result: [String: UInt32] = [:]
        for deviceID in allDeviceIDs() {
            guard
                let uid = stringProperty(kAudioDevicePropertyDeviceUID, of: deviceID),
                let transport = uint32Property(kAudioDevicePropertyTransportType, of: deviceID)
            else {
                continue
            }
            result[uid] = transport
        }
        return result
    }

    static func inputVolumesByDeviceUID() -> [String: Float] {
        var result: [String: Float] = [:]
        for deviceID in allDeviceIDs() {
            guard
                let uid = stringProperty(kAudioDevicePropertyDeviceUID, of: deviceID),
                let volume = floatInputProperty(kAudioDevicePropertyVolumeScalar, of: deviceID)
            else {
                continue
            }
            result[uid] = volume
        }
        return result
    }

    static func deviceID(forUID uid: String) -> AudioObjectID? {
        allDeviceIDs().first {
            stringProperty(kAudioDevicePropertyDeviceUID, of: $0) == uid
        }
    }

    static func defaultOutputDeviceID() -> AudioObjectID? {
        systemDeviceID(for: kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func deviceUID(for deviceID: AudioObjectID) -> String? {
        stringProperty(kAudioDevicePropertyDeviceUID, of: deviceID)
    }

    static func inputChannelCount(for deviceID: AudioObjectID) -> UInt32? {
        channelCount(for: deviceID, scope: kAudioDevicePropertyScopeInput)
    }

    static func outputChannelCount(for deviceID: AudioObjectID) -> UInt32? {
        channelCount(for: deviceID, scope: kAudioDevicePropertyScopeOutput)
    }

    /// Aggregate stream order is security-relevant for capture: a later
    /// full-duplex output subdevice may contribute its own microphone channels.
    /// Read the order Core Audio actually activated instead of trusting only the
    /// creation dictionary we supplied.
    static func aggregateSubDeviceUIDs(for deviceID: AudioObjectID) -> [String]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFArray>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        guard
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &dataSize,
                &value
            ) == noErr
        else {
            return nil
        }
        guard let value else { return nil }
        return value.takeRetainedValue() as? [String]
    }

    private static func systemDeviceID(
        for selector: AudioObjectPropertySelector
    ) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                &value
            ) == noErr,
            value != kAudioObjectUnknown
        else {
            return nil
        }
        return value
    }

    static func allDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize
            ) == noErr
        else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                &deviceIDs
            ) == noErr
        else {
            return []
        }
        return deviceIDs
    }

    static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        of deviceID: AudioObjectID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        guard
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value) == noErr
        else {
            return nil
        }
        return value as String
    }

    private static func uint32Property(
        _ selector: AudioObjectPropertySelector,
        of deviceID: AudioObjectID
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        guard
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value) == noErr
        else {
            return nil
        }
        return value
    }

    private static func floatInputProperty(
        _ selector: AudioObjectPropertySelector,
        of deviceID: AudioObjectID
    ) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: Float32 = 0
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        guard
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value) == noErr,
            value.isFinite
        else {
            return nil
        }
        return min(1, max(0, value))
    }

    private static func channelCount(
        for deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(
                deviceID,
                &address,
                0,
                nil,
                &dataSize
            ) == noErr,
            dataSize >= UInt32(MemoryLayout<AudioBufferList>.size)
        else {
            return nil
        }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &dataSize,
                raw
            ) == noErr
        else {
            return nil
        }
        let bufferList = raw.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(bufferList).reduce(0) {
            $0 + $1.mNumberChannels
        }
    }
}
