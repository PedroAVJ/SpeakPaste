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

private struct MacOutputVolumeSnapshot: Sendable {
    let deviceID: AudioObjectID
    let deviceUID: String
    let volumesByElement: [UInt32: Float]
}

extension MacCoreAudioTransport {
    /// Returns only writable volume controls for the current physical output.
    /// Prefer the virtual master control because it preserves channel balance;
    /// fall back to independently writable channels for devices without one.
    fileprivate static func currentOutputVolumeSnapshot() -> MacOutputVolumeSnapshot? {
        guard
            let deviceID = defaultOutputDeviceID(),
            let deviceUID = deviceUID(for: deviceID)
        else {
            return nil
        }

        let main = UInt32(kAudioObjectPropertyElementMain)
        if isWritableOutputVolume(deviceID: deviceID, element: main),
           let volume = outputVolume(deviceID: deviceID, element: main) {
            return MacOutputVolumeSnapshot(
                deviceID: deviceID,
                deviceUID: deviceUID,
                volumesByElement: [main: volume]
            )
        }

        guard let count = outputChannelCount(for: deviceID), count > 0 else {
            return nil
        }
        var volumes: [UInt32: Float] = [:]
        for element in 1...count where isWritableOutputVolume(
            deviceID: deviceID,
            element: element
        ) {
            if let volume = outputVolume(deviceID: deviceID, element: element) {
                volumes[element] = volume
            }
        }
        guard !volumes.isEmpty else { return nil }
        return MacOutputVolumeSnapshot(
            deviceID: deviceID,
            deviceUID: deviceUID,
            volumesByElement: volumes
        )
    }

    fileprivate static func outputVolumes(
        deviceID: AudioObjectID,
        elements: Dictionary<UInt32, Float>.Keys
    ) -> [UInt32: Float]? {
        var result: [UInt32: Float] = [:]
        for element in elements {
            guard let volume = outputVolume(deviceID: deviceID, element: element) else {
                return nil
            }
            result[element] = volume
        }
        return result
    }

    fileprivate static func attenuatedOutputVolumes(
        for snapshot: MacOutputVolumeSnapshot
    ) -> [UInt32: Float] {
        var result: [UInt32: Float] = [:]
        for pair in snapshot.volumesByElement {
            let decibelTarget = translatedOutputVolume(
                deviceID: snapshot.deviceID,
                element: pair.key,
                selector: kAudioDevicePropertyVolumeScalarToDecibels,
                value: pair.value
            ).flatMap { decibels in
                translatedOutputVolume(
                    deviceID: snapshot.deviceID,
                    element: pair.key,
                    selector: kAudioDevicePropertyVolumeDecibelsToScalar,
                    value: decibels - Float(MacCompetingMediaFadePolicy.attenuationDecibels)
                )
            }
            result[pair.key] = decibelTarget.map { min(max($0, 0), 1) }
                ?? MacCompetingMediaFadePolicy.quietVolume(for: pair.value)
        }
        return result
    }

    @discardableResult
    fileprivate static func setOutputVolumes(
        deviceID: AudioObjectID,
        volumesByElement: [UInt32: Float]
    ) -> Bool {
        for (element, requested) in volumesByElement.sorted(by: { $0.key < $1.key }) {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            var value = Float32(min(max(requested, 0), 1))
            guard AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &value
            ) == noErr else {
                return false
            }
        }
        return true
    }

    private static func outputVolume(
        deviceID: AudioObjectID,
        element: UInt32
    ) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: Float32 = 0
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        ) == noErr, value.isFinite else {
            return nil
        }
        return min(max(value, 0), 1)
    }

    private static func translatedOutputVolume(
        deviceID: AudioObjectID,
        element: UInt32,
        selector: AudioObjectPropertySelector,
        value: Float
    ) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var translated = Float32(value)
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &translated
        ) == noErr, translated.isFinite else {
            return nil
        }
        return translated
    }

    private static func isWritableOutputVolume(
        deviceID: AudioObjectID,
        element: UInt32
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var isSettable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr
            && isSettable.boolValue
    }
}

/// Smoothly attenuates the current output without starting another audio
/// engine, pausing a player, or changing the default device. The lease is
/// deliberately conservative: a volume-key press, route change, or failed
/// write immediately ends SpeakPaste's ownership so a user's choice is never
/// overwritten on release.
final class MacCompetingMediaFader: @unchecked Sendable {
    private struct Lease {
        let original: MacOutputVolumeSnapshot
        var lastWritten: [UInt32: Float]
    }

    private struct StoredLease: Codable {
        let deviceUID: String
        let original: [UInt32: Float]
        let lastWritten: [UInt32: Float]
        let updatedAt: Date
    }

    private static let storedLeaseKey = "mac-competing-media-volume-lease"
    private static let staleLeaseLifetime: TimeInterval = 12 * 60 * 60

    private let queue = DispatchQueue(
        label: "com.speakpaste.competing-media-fader",
        qos: .userInitiated
    )
    private let queueKey = DispatchSpecificKey<Void>()
    private let defaults: UserDefaults
    private var generation: UInt64 = 0
    private var lease: Lease?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        queue.setSpecific(key: queueKey, value: ())
    }

    /// Called only after the single-instance lease proves this is the primary
    /// app. If a prior process died while faded, restore only when the output
    /// still exactly resembles SpeakPaste's last write.
    func recoverStaleFade() {
        queue.async { [weak self] in self?.recoverStaleFadeOnQueue() }
    }

    func fadeDown() {
        queue.async { [weak self] in self?.fadeDownOnQueue() }
    }

    func fadeUp() {
        queue.async { [weak self] in self?.fadeUpOnQueue() }
    }

    /// AppKit's termination notification cannot await work. Guarantee normal
    /// output synchronously even if that means skipping the release animation.
    func restoreImmediately() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            restoreOwnedLeaseImmediatelyOnQueue()
        } else {
            queue.sync { restoreOwnedLeaseImmediatelyOnQueue() }
        }
    }

    private func fadeDownOnQueue() {
        generation &+= 1
        let token = generation

        if lease == nil {
            guard let snapshot = MacCoreAudioTransport.currentOutputVolumeSnapshot() else {
                clearStoredLease()
                return
            }
            lease = Lease(
                original: snapshot,
                lastWritten: snapshot.volumesByElement
            )
            persistLease()
        }

        guard
            let lease,
            outputIsStillCurrent(lease.original),
            let current = currentVolumes(for: lease),
            stillOwns(current: current, lastWritten: lease.lastWritten)
        else {
            abandonLeaseWithoutWriting()
            return
        }

        let target = MacCoreAudioTransport.attenuatedOutputVolumes(
            for: lease.original
        )
        scheduleTransition(
            from: current,
            to: target,
            duration: MacCompetingMediaFadePolicy.fadeDownDuration,
            token: token,
            clearsLeaseOnCompletion: false
        )
    }

    private func fadeUpOnQueue() {
        generation &+= 1
        let token = generation
        guard let lease else {
            clearStoredLease()
            return
        }
        guard outputIsStillCurrent(lease.original) else {
            restoreOwnedLeaseImmediatelyOnQueue()
            return
        }
        guard
            let current = currentVolumes(for: lease),
            stillOwns(current: current, lastWritten: lease.lastWritten)
        else {
            abandonLeaseWithoutWriting()
            return
        }
        scheduleTransition(
            from: current,
            to: lease.original.volumesByElement,
            duration: MacCompetingMediaFadePolicy.fadeUpDuration,
            token: token,
            clearsLeaseOnCompletion: true
        )
    }

    private func scheduleTransition(
        from start: [UInt32: Float],
        to target: [UInt32: Float],
        duration: TimeInterval,
        token: UInt64,
        clearsLeaseOnCompletion: Bool
    ) {
        let steps = max(1, Int(ceil(duration * MacCompetingMediaFadePolicy.updatesPerSecond)))
        for step in 1...steps {
            let progress = Double(step) / Double(steps)
            queue.asyncAfter(deadline: .now() + (duration * progress)) { [weak self] in
                guard let self, self.generation == token, var lease = self.lease else {
                    return
                }
                guard self.outputIsStillCurrent(lease.original) else {
                    self.restoreOwnedLeaseImmediatelyOnQueue()
                    return
                }
                guard
                    let observed = self.currentVolumes(for: lease),
                    self.stillOwns(current: observed, lastWritten: lease.lastWritten)
                else {
                    self.abandonLeaseWithoutWriting()
                    return
                }

                let next = target.reduce(into: [UInt32: Float]()) { result, pair in
                    guard let initial = start[pair.key] else { return }
                    result[pair.key] = MacCompetingMediaFadePolicy.volume(
                        from: initial,
                        to: pair.value,
                        progress: progress
                    )
                }
                guard next.count == target.count,
                      MacCoreAudioTransport.setOutputVolumes(
                        deviceID: lease.original.deviceID,
                        volumesByElement: next
                      ) else {
                    self.restoreOwnedLeaseImmediatelyOnQueue()
                    return
                }

                lease.lastWritten = next
                self.lease = lease
                self.persistLease()

                guard step == steps else { return }
                if clearsLeaseOnCompletion {
                    self.abandonLeaseWithoutWriting()
                } else {
                    self.scheduleOwnershipCheck(token: token)
                }
            }
        }
    }

    private func scheduleOwnershipCheck(token: UInt64) {
        queue.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            guard let self, self.generation == token, let lease = self.lease else {
                return
            }
            guard self.outputIsStillCurrent(lease.original) else {
                self.restoreOwnedLeaseImmediatelyOnQueue()
                return
            }
            guard
                let current = self.currentVolumes(for: lease),
                self.stillOwns(current: current, lastWritten: lease.lastWritten)
            else {
                self.abandonLeaseWithoutWriting()
                return
            }
            self.scheduleOwnershipCheck(token: token)
        }
    }

    private func recoverStaleFadeOnQueue() {
        guard
            let data = defaults.data(forKey: Self.storedLeaseKey),
            let stored = try? JSONDecoder().decode(StoredLease.self, from: data),
            Date().timeIntervalSince(stored.updatedAt) <= Self.staleLeaseLifetime,
            let snapshot = MacCoreAudioTransport.currentOutputVolumeSnapshot(),
            snapshot.deviceUID == stored.deviceUID,
            Set(snapshot.volumesByElement.keys) == Set(stored.original.keys),
            let current = MacCoreAudioTransport.outputVolumes(
                deviceID: snapshot.deviceID,
                elements: stored.original.keys
            ),
            stillOwns(current: current, lastWritten: stored.lastWritten)
        else {
            clearStoredLease()
            return
        }
        _ = MacCoreAudioTransport.setOutputVolumes(
            deviceID: snapshot.deviceID,
            volumesByElement: stored.original
        )
        clearStoredLease()
    }

    private func restoreOwnedLeaseImmediatelyOnQueue() {
        generation &+= 1
        guard let lease else {
            recoverStaleFadeOnQueue()
            return
        }
        if let current = currentVolumes(for: lease),
           stillOwns(current: current, lastWritten: lease.lastWritten) {
            _ = MacCoreAudioTransport.setOutputVolumes(
                deviceID: lease.original.deviceID,
                volumesByElement: lease.original.volumesByElement
            )
        }
        abandonLeaseWithoutWriting()
    }

    private func outputIsStillCurrent(_ snapshot: MacOutputVolumeSnapshot) -> Bool {
        MacCoreAudioTransport.defaultOutputDeviceID() == snapshot.deviceID
    }

    private func currentVolumes(for lease: Lease) -> [UInt32: Float]? {
        MacCoreAudioTransport.outputVolumes(
            deviceID: lease.original.deviceID,
            elements: lease.original.volumesByElement.keys
        )
    }

    private func stillOwns(
        current: [UInt32: Float],
        lastWritten: [UInt32: Float]
    ) -> Bool {
        current.count == lastWritten.count && current.allSatisfy { element, value in
            guard let expected = lastWritten[element] else { return false }
            return MacCompetingMediaFadePolicy.stillOwns(
                current: value,
                lastWritten: expected
            )
        }
    }

    private func persistLease() {
        guard let lease,
              let data = try? JSONEncoder().encode(
                StoredLease(
                    deviceUID: lease.original.deviceUID,
                    original: lease.original.volumesByElement,
                    lastWritten: lease.lastWritten,
                    updatedAt: Date()
                )
              ) else {
            return
        }
        defaults.set(data, forKey: Self.storedLeaseKey)
    }

    private func abandonLeaseWithoutWriting() {
        generation &+= 1
        lease = nil
        clearStoredLease()
    }

    private func clearStoredLease() {
        defaults.removeObject(forKey: Self.storedLeaseKey)
    }
}
