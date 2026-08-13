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

private enum MacCoreAudioTransport {
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

    static func outputChannelCount(for deviceID: AudioObjectID) -> UInt32? {
        channelCount(for: deviceID, scope: kAudioDevicePropertyScopeOutput)
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

    private static func allDeviceIDs() -> [AudioObjectID] {
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

    private static func stringProperty(
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
    ) -> [UInt32: Float]? {
        var result: [UInt32: Float] = [:]
        for pair in snapshot.volumesByElement {
            guard let originalDecibels = translatedOutputVolume(
                deviceID: snapshot.deviceID,
                element: pair.key,
                selector: kAudioDevicePropertyVolumeScalarToDecibels,
                value: pair.value
            ), let decibelTarget = translatedOutputVolume(
                deviceID: snapshot.deviceID,
                element: pair.key,
                selector: kAudioDevicePropertyVolumeDecibelsToScalar,
                value: originalDecibels
                    - Float(MacCompetingMediaFadePolicy.attenuationDecibels)
            ) else {
                // Scalar volume is device-specific and is not promised to be
                // linear amplitude. Without both translators, a claimed 12 dB
                // fade would be fiction, so this output fails open unchanged.
                return nil
            }
            result[pair.key] = min(max(decibelTarget, 0), 1)
        }
        return result
    }

    fileprivate static func interpolatedOutputVolumes(
        deviceID: AudioObjectID,
        from start: [UInt32: Float],
        to target: [UInt32: Float],
        progress: Double
    ) -> [UInt32: Float]? {
        guard MacCompetingMediaLeasePolicy.hasSameElements(start, target) else {
            return nil
        }
        var result: [UInt32: Float] = [:]
        for pair in target {
            guard
                let startScalar = start[pair.key],
                let startDecibels = translatedOutputVolume(
                    deviceID: deviceID,
                    element: pair.key,
                    selector: kAudioDevicePropertyVolumeScalarToDecibels,
                    value: startScalar
                ),
                let targetDecibels = translatedOutputVolume(
                    deviceID: deviceID,
                    element: pair.key,
                    selector: kAudioDevicePropertyVolumeScalarToDecibels,
                    value: pair.value
                ),
                let scalar = translatedOutputVolume(
                    deviceID: deviceID,
                    element: pair.key,
                    selector: kAudioDevicePropertyVolumeDecibelsToScalar,
                    value: MacCompetingMediaFadePolicy.decibels(
                        from: startDecibels,
                        to: targetDecibels,
                        progress: progress
                    )
                )
            else {
                return nil
            }
            result[pair.key] = min(max(scalar, 0), 1)
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
/// engine, pausing a player, or changing the default device. Every hardware
/// mutation is preceded by an fsynced write-ahead receipt. The receipt survives
/// disconnects and process crashes until the complete original volume map has
/// been written and read back successfully.
final class MacCompetingMediaFader: @unchecked Sendable {
    private struct LegacyStoredLease: Codable {
        let deviceUID: String
        let original: [UInt32: Float]
        let lastWritten: [UInt32: Float]
    }

    private static let legacyStoredLeaseKey = "mac-competing-media-volume-lease"
    private static let retryDelay: TimeInterval = 2

    private let queue = DispatchQueue(
        label: "com.speakpaste.competing-media-fader",
        qos: .userInitiated
    )
    private let queueKey = DispatchSpecificKey<Void>()
    private let store: MacCompetingMediaLeaseStore
    private let legacyDefaults: UserDefaults

    private var generation: UInt64 = 0
    private var retryGeneration: UInt64 = 0
    private var lease: MacCompetingMediaStoredLease?
    /// True from a live recording's fade-down through the end of its fade-up.
    /// It distinguishes harmless device-list churn (for example a private VPIO
    /// aggregate appearing) from launch/reconnect recovery of an old receipt.
    private var liveSessionOwnsFade = false

    private var systemListener: AudioObjectPropertyListenerBlock?
    private var systemListenerAddresses: [AudioObjectPropertyAddress] = []
    private var volumeListener: AudioObjectPropertyListenerBlock?
    private var volumeListenerDeviceID: AudioObjectID?
    private var volumeListenerAddresses: [AudioObjectPropertyAddress] = []

    init(
        applicationSupportDirectory: URL? = nil,
        defaults: UserDefaults = .standard
    ) {
        store = MacCompetingMediaLeaseStore(
            applicationSupportDirectory: applicationSupportDirectory
        )
        legacyDefaults = defaults
        queue.setSpecific(key: queueKey, value: ())
    }

    /// Called only after the single-instance lease proves this is the primary
    /// app. A disconnected output keeps its receipt indefinitely; device-list
    /// and default-output listeners retry restoration when it returns.
    func recoverStaleFade() {
        queue.async { [weak self] in self?.recoverStaleFadeOnQueue() }
    }

    func fadeDown() {
        queue.async { [weak self] in self?.fadeDownOnQueue() }
    }

    func fadeUp() {
        queue.async { [weak self] in self?.fadeUpOnQueue() }
    }

    /// AppKit's termination notification cannot await work. Skip the release
    /// animation, but retain the durable receipt if HAL cannot prove restoration.
    func restoreImmediately() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            restoreLeaseIfPossibleOnQueue()
        } else {
            queue.sync { restoreLeaseIfPossibleOnQueue() }
        }
    }

    private func fadeDownOnQueue() {
        let hasExistingReceipt = loadPersistedLeaseOnQueue()
        if hasExistingReceipt {
            // `true` with no decoded in-memory lease means the durable receipt
            // is temporarily unreadable. Fail open rather than replacing the
            // only evidence that an older output may still need restoration.
            guard let existingLease = lease else { return }
            // A fast stop -> start reverses the release from the exact current
            // level. Keep the same original receipt and cancel the older ramp;
            // never jump to full volume or create a second lease.
            generation &+= 1
            let token = generation
            guard
                existingLease.restoreRequired,
                currentDefaultOutputUID() == existingLease.deviceUID,
                let deviceID = MacCoreAudioTransport.deviceID(
                    forUID: existingLease.deviceUID
                ),
                let current = currentVolumes(
                    deviceID: deviceID,
                    lease: existingLease
                ),
                MacCompetingMediaLeasePolicy.ownsLiveState(
                    current: current,
                    lease: existingLease
                ),
                let target = MacCoreAudioTransport.attenuatedOutputVolumes(
                    for: MacOutputVolumeSnapshot(
                        deviceID: deviceID,
                        deviceUID: existingLease.deviceUID,
                        volumesByElement: existingLease.original
                    )
                ),
                let frames = transitionFrames(
                    deviceID: deviceID,
                    from: current,
                    to: target,
                    duration: MacCompetingMediaFadePolicy.fadeDownDuration
                ),
                installSystemListenersOnQueue(),
                installVolumeListenersOnQueue(
                    deviceID: deviceID,
                    elements: existingLease.original.keys
                )
            else {
                // An earlier output that cannot be proven app-owned must be
                // restored (or retain its durable retry receipt) before any
                // later output is attenuated.
                restoreLeaseIfPossibleOnQueue()
                return
            }
            retryGeneration &+= 1
            liveSessionOwnsFade = true
            scheduleTransition(
                frames: frames,
                duration: MacCompetingMediaFadePolicy.fadeDownDuration,
                token: token,
                writeKind: .fade,
                restoresOnCompletion: false
            )
            return
        }
        guard
            let snapshot = MacCoreAudioTransport.currentOutputVolumeSnapshot(),
            let target = MacCoreAudioTransport.attenuatedOutputVolumes(for: snapshot),
            let frames = transitionFrames(
                deviceID: snapshot.deviceID,
                from: snapshot.volumesByElement,
                to: target,
                duration: MacCompetingMediaFadePolicy.fadeDownDuration
            )
        else {
            // An output without writable controls and both scalar/dB translators
            // keeps playing at the user's current level.
            return
        }

        let newLease = MacCompetingMediaStoredLease(
            deviceUID: snapshot.deviceUID,
            original: snapshot.volumesByElement,
            committed: snapshot.volumesByElement
        )
        guard persist(newLease) else { return }
        lease = newLease

        guard installSystemListenersOnQueue(), installVolumeListenersOnQueue(
            deviceID: snapshot.deviceID,
            elements: snapshot.volumesByElement.keys
        ) else {
            restoreLeaseIfPossibleOnQueue()
            return
        }

        generation &+= 1
        retryGeneration &+= 1
        let token = generation
        liveSessionOwnsFade = true
        scheduleTransition(
            frames: frames,
            duration: MacCompetingMediaFadePolicy.fadeDownDuration,
            token: token,
            writeKind: .fade,
            restoresOnCompletion: false
        )
    }

    private func fadeUpOnQueue() {
        guard loadPersistedLeaseOnQueue(), let lease else { return }
        generation &+= 1
        retryGeneration &+= 1
        let token = generation
        guard
            let deviceID = MacCoreAudioTransport.deviceID(forUID: lease.deviceUID),
            let current = currentVolumes(deviceID: deviceID, lease: lease),
            MacCompetingMediaLeasePolicy.ownsLiveState(current: current, lease: lease),
            let frames = transitionFrames(
                deviceID: deviceID,
                from: current,
                to: lease.original,
                duration: MacCompetingMediaFadePolicy.fadeUpDuration
            )
        else {
            // A route/translator/read failure must not strand a low volume.
            // Restoration itself does not need the translator and is retried.
            restoreLeaseIfPossibleOnQueue()
            return
        }
        scheduleTransition(
            frames: frames,
            duration: MacCompetingMediaFadePolicy.fadeUpDuration,
            token: token,
            writeKind: .restore,
            restoresOnCompletion: true
        )
    }

    private func transitionFrames(
        deviceID: AudioObjectID,
        from start: [UInt32: Float],
        to target: [UInt32: Float],
        duration: TimeInterval
    ) -> [[UInt32: Float]]? {
        let steps = max(
            1,
            Int(ceil(duration * MacCompetingMediaFadePolicy.updatesPerSecond))
        )
        var frames: [[UInt32: Float]] = []
        frames.reserveCapacity(steps)
        for step in 1...steps {
            guard let frame = MacCoreAudioTransport.interpolatedOutputVolumes(
                deviceID: deviceID,
                from: start,
                to: target,
                progress: Double(step) / Double(steps)
            ) else {
                return nil
            }
            frames.append(frame)
        }
        return frames
    }

    private func scheduleTransition(
        frames: [[UInt32: Float]],
        duration: TimeInterval,
        token: UInt64,
        writeKind: MacCompetingMediaPendingWrite.Kind,
        restoresOnCompletion: Bool
    ) {
        for (index, frame) in frames.enumerated() {
            let progress = Double(index + 1) / Double(frames.count)
            queue.asyncAfter(deadline: .now() + (duration * progress)) { [weak self] in
                guard let self, self.generation == token else { return }
                guard self.applyOwnedFrameOnQueue(frame, kind: writeKind) else { return }
                guard index == frames.count - 1 else { return }
                if restoresOnCompletion {
                    self.finishRestoredLeaseOnQueue()
                } else {
                    self.scheduleOwnershipCheck(token: token)
                }
            }
        }
    }

    private func applyOwnedFrameOnQueue(
        _ requested: [UInt32: Float],
        kind: MacCompetingMediaPendingWrite.Kind
    ) -> Bool {
        guard var lease else { return false }
        guard currentDefaultOutputUID() == lease.deviceUID else {
            restoreLeaseIfPossibleOnQueue()
            return false
        }
        guard
            let deviceID = MacCoreAudioTransport.deviceID(forUID: lease.deviceUID),
            let observed = currentVolumes(deviceID: deviceID, lease: lease)
        else {
            restoreLeaseIfPossibleOnQueue()
            return false
        }
        guard MacCompetingMediaLeasePolicy.ownsLiveState(
            current: observed,
            lease: lease
        ) else {
            abandonForExternalChangeOnQueue(observed: observed)
            return false
        }

        // A previous write may have been interrupted after only some hardware
        // elements changed. Once that exact WAL state is observed, make it the
        // new committed starting point before replacing the pending frame.
        lease.committed = observed
        lease.pendingWrite = nil
        lease.pendingWrite = MacCompetingMediaPendingWrite(
            from: observed,
            to: requested,
            kind: kind
        )
        guard persist(lease) else {
            restoreLeaseIfPossibleOnQueue()
            return false
        }
        self.lease = lease

        guard
            MacCoreAudioTransport.setOutputVolumes(
                deviceID: deviceID,
                volumesByElement: requested
            ),
            let applied = currentVolumes(deviceID: deviceID, lease: lease)
        else {
            // The durable pending map recognizes a partial multi-channel write.
            restoreLeaseIfPossibleOnQueue()
            return false
        }

        // Never adopt an arbitrary value observed after our HAL write. Core
        // Audio may quantize onto a nearby selectable value, including just
        // past the request. The policy bounds that rounding using the exact
        // pre-write readback; anything outside it is an external choice, so
        // every queued app frame stops.
        guard let pendingWrite = lease.pendingWrite,
              MacCompetingMediaLeasePolicy.matchesPendingRealization(
                applied,
                pending: pendingWrite
              )
        else {
            abandonForExternalChangeOnQueue(observed: applied)
            return false
        }

        lease.committed = applied
        lease.pendingWrite = nil
        guard persist(lease) else {
            // The prior durable pending record remains authoritative.
            restoreLeaseIfPossibleOnQueue()
            return false
        }
        self.lease = lease
        return true
    }

    private func scheduleOwnershipCheck(token: UInt64) {
        queue.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            guard let self, self.generation == token, let lease = self.lease else {
                return
            }
            guard self.currentDefaultOutputUID() == lease.deviceUID else {
                self.restoreLeaseIfPossibleOnQueue()
                return
            }
            guard
                let deviceID = MacCoreAudioTransport.deviceID(forUID: lease.deviceUID),
                let current = self.currentVolumes(deviceID: deviceID, lease: lease)
            else {
                self.restoreLeaseIfPossibleOnQueue()
                return
            }
            guard MacCompetingMediaLeasePolicy.ownsLiveState(
                current: current,
                lease: lease
            ) else {
                self.abandonForExternalChangeOnQueue(observed: current)
                return
            }
            self.scheduleOwnershipCheck(token: token)
        }
    }

    private func recoverStaleFadeOnQueue() {
        guard loadPersistedLeaseOnQueue() else { return }
        _ = installSystemListenersOnQueue()
        restoreLeaseIfPossibleOnQueue()
    }

    /// Restores by device UID even when that device is no longer the default.
    /// Missing devices and failed HAL operations retain the receipt and retry.
    private func restoreLeaseIfPossibleOnQueue() {
        liveSessionOwnsFade = false
        generation &+= 1
        guard loadPersistedLeaseOnQueue(), var lease else { return }
        guard lease.restoreRequired else {
            removeAbandonedReceiptOnQueue()
            return
        }
        _ = installSystemListenersOnQueue()
        guard let deviceID = MacCoreAudioTransport.deviceID(forUID: lease.deviceUID) else {
            uninstallVolumeListenersOnQueue()
            scheduleRecoveryRetryOnQueue()
            return
        }
        _ = installVolumeListenersOnQueue(
            deviceID: deviceID,
            elements: lease.original.keys
        )
        guard let current = currentVolumes(deviceID: deviceID, lease: lease) else {
            scheduleRecoveryRetryOnQueue()
            return
        }
        guard MacCompetingMediaLeasePolicy.ownsRecoverableState(
            current: current,
            lease: lease
        ) else {
            abandonForExternalChangeOnQueue(observed: current)
            return
        }
        if MacCompetingMediaLeasePolicy.mapsMatch(current, lease.original) {
            lease.committed = current
            lease.pendingWrite = nil
            self.lease = lease
            finishRestoredLeaseOnQueue()
            return
        }

        let restoring = MacCompetingMediaPendingWrite(
            from: current,
            to: lease.original,
            kind: .restore
        )
        lease.pendingWrite = restoring
        if persist(lease) {
            self.lease = lease
        }
        // Even if the new receipt cannot be written, the existing receipt plus
        // the always-recognized original map makes a partial restore recoverable.
        _ = MacCoreAudioTransport.setOutputVolumes(
            deviceID: deviceID,
            volumesByElement: lease.original
        )
        guard
            let restored = currentVolumes(deviceID: deviceID, lease: lease),
            MacCompetingMediaLeasePolicy.mapsMatch(restored, lease.original)
        else {
            scheduleRecoveryRetryOnQueue()
            return
        }
        lease.committed = restored
        lease.pendingWrite = nil
        self.lease = lease
        finishRestoredLeaseOnQueue()
    }

    /// The only path that removes a restoration receipt: every original element
    /// was read back, the restored state was committed durably, and deletion of
    /// that durable receipt itself succeeded.
    private func finishRestoredLeaseOnQueue() {
        guard var lease,
              let deviceID = MacCoreAudioTransport.deviceID(forUID: lease.deviceUID),
              let current = currentVolumes(deviceID: deviceID, lease: lease),
              MacCompetingMediaLeasePolicy.mapsMatch(current, lease.original)
        else {
            scheduleRecoveryRetryOnQueue()
            return
        }
        lease.committed = current
        lease.pendingWrite = nil
        guard persist(lease) else {
            self.lease = lease
            scheduleRecoveryRetryOnQueue()
            return
        }
        self.lease = lease
        do {
            try store.remove()
        } catch {
            scheduleRecoveryRetryOnQueue()
            return
        }
        legacyDefaults.removeObject(forKey: Self.legacyStoredLeaseKey)
        clearInMemoryLeaseOnQueue()
    }

    private func loadPersistedLeaseOnQueue() -> Bool {
        if lease != nil { return true }
        do {
            if let stored = try store.load() {
                if stored.restoreRequired {
                    lease = stored
                    return true
                }
                try store.remove()
                return false
            }
        } catch {
            // An unreadable or temporarily unavailable receipt must never be
            // deleted or replaced by another fade.
            scheduleRecoveryRetryOnQueue()
            return true
        }

        // One-way migration for a crash receipt made by the short-lived
        // UserDefaults implementation. New writes never use UserDefaults.
        guard
            let data = legacyDefaults.data(forKey: Self.legacyStoredLeaseKey),
            let legacy = try? JSONDecoder().decode(LegacyStoredLease.self, from: data)
        else {
            return false
        }
        let migrated = MacCompetingMediaStoredLease(
            deviceUID: legacy.deviceUID,
            original: legacy.original,
            committed: legacy.lastWritten
        )
        guard persist(migrated) else { return true }
        legacyDefaults.removeObject(forKey: Self.legacyStoredLeaseKey)
        lease = migrated
        return true
    }

    private func abandonForExternalChangeOnQueue(observed: [UInt32: Float]) {
        generation &+= 1
        retryGeneration &+= 1
        guard var abandoned = lease else {
            clearInMemoryLeaseOnQueue()
            return
        }
        abandoned.restoreRequired = false
        abandoned.pendingWrite = nil
        if MacCompetingMediaLeasePolicy.hasSameElements(
            observed,
            abandoned.original
        ) {
            abandoned.committed = observed
        }
        self.lease = abandoned

        // Persist a non-restoring tombstone before deletion so a crash between
        // those operations cannot resurrect an old volume over the user's
        // choice. If both operations fail, retain the in-memory tombstone and
        // listeners while retrying instead of forgetting the conflict.
        let tombstoneIsDurable = persist(abandoned)
        do {
            try store.remove()
            legacyDefaults.removeObject(forKey: Self.legacyStoredLeaseKey)
            clearInMemoryLeaseOnQueue()
        } catch {
            if !tombstoneIsDurable {
                self.lease = abandoned
            }
            scheduleRecoveryRetryOnQueue()
        }
    }

    private func removeAbandonedReceiptOnQueue() {
        do {
            try store.remove()
            legacyDefaults.removeObject(forKey: Self.legacyStoredLeaseKey)
            clearInMemoryLeaseOnQueue()
        } catch {
            scheduleRecoveryRetryOnQueue()
        }
    }

    private func currentVolumes(
        deviceID: AudioObjectID,
        lease: MacCompetingMediaStoredLease
    ) -> [UInt32: Float]? {
        guard MacCoreAudioTransport.deviceUID(for: deviceID) == lease.deviceUID else {
            return nil
        }
        return MacCoreAudioTransport.outputVolumes(
            deviceID: deviceID,
            elements: lease.original.keys
        )
    }

    private func currentDefaultOutputUID() -> String? {
        guard let deviceID = MacCoreAudioTransport.defaultOutputDeviceID() else {
            return nil
        }
        return MacCoreAudioTransport.deviceUID(for: deviceID)
    }

    private func persist(_ lease: MacCompetingMediaStoredLease) -> Bool {
        do {
            try store.save(lease)
            return true
        } catch {
            return false
        }
    }

    private func scheduleRecoveryRetryOnQueue() {
        retryGeneration &+= 1
        let token = retryGeneration
        queue.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
            guard let self, self.retryGeneration == token else { return }
            self.restoreLeaseIfPossibleOnQueue()
        }
    }

    private func clearInMemoryLeaseOnQueue() {
        generation &+= 1
        retryGeneration &+= 1
        liveSessionOwnsFade = false
        lease = nil
        uninstallVolumeListenersOnQueue()
        uninstallSystemListenersOnQueue()
    }

    // MARK: Core Audio ownership listeners

    private func installSystemListenersOnQueue() -> Bool {
        if systemListener != nil { return true }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleSystemAudioChangeOnQueue()
        }
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDevices,
        ]
        var registered: [AudioObjectPropertyAddress] = []
        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                listener
            ) == noErr else {
                for var prior in registered {
                    AudioObjectRemovePropertyListenerBlock(
                        AudioObjectID(kAudioObjectSystemObject),
                        &prior,
                        queue,
                        listener
                    )
                }
                return false
            }
            registered.append(address)
        }
        systemListener = listener
        systemListenerAddresses = registered
        return true
    }

    private func installVolumeListenersOnQueue(
        deviceID: AudioObjectID,
        elements: Dictionary<UInt32, Float>.Keys
    ) -> Bool {
        let sortedElements = elements.sorted()
        if volumeListenerDeviceID == deviceID,
           volumeListenerAddresses.map(\.mElement).sorted() == sortedElements {
            return true
        }
        uninstallVolumeListenersOnQueue()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleVolumeChangeOnQueue()
        }
        var registered: [AudioObjectPropertyAddress] = []
        for element in sortedElements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectAddPropertyListenerBlock(
                deviceID,
                &address,
                queue,
                listener
            ) == noErr else {
                for var prior in registered {
                    AudioObjectRemovePropertyListenerBlock(
                        deviceID,
                        &prior,
                        queue,
                        listener
                    )
                }
                return false
            }
            registered.append(address)
        }
        volumeListener = listener
        volumeListenerDeviceID = deviceID
        volumeListenerAddresses = registered
        return true
    }

    private func uninstallSystemListenersOnQueue() {
        guard let listener = systemListener else { return }
        for var address in systemListenerAddresses {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                listener
            )
        }
        systemListener = nil
        systemListenerAddresses = []
    }

    private func uninstallVolumeListenersOnQueue() {
        guard let listener = volumeListener, let deviceID = volumeListenerDeviceID else {
            volumeListener = nil
            volumeListenerDeviceID = nil
            volumeListenerAddresses = []
            return
        }
        for var address in volumeListenerAddresses {
            AudioObjectRemovePropertyListenerBlock(
                deviceID,
                &address,
                queue,
                listener
            )
        }
        volumeListener = nil
        volumeListenerDeviceID = nil
        volumeListenerAddresses = []
    }

    private func handleSystemAudioChangeOnQueue() {
        retryGeneration &+= 1
        guard loadPersistedLeaseOnQueue() else { return }
        guard let lease else {
            scheduleRecoveryRetryOnQueue()
            return
        }
        if currentDefaultOutputUID() == lease.deviceUID, liveSessionOwnsFade {
            // The private Continuity/VPIO aggregate appears and disappears in
            // the global device list while the real output stays unchanged.
            // That is not an output-route change and must not snap a scheduled
            // 900 ms release to full volume. Refresh the element listener in
            // case Core Audio recycled the physical device ID, then let the
            // current ramp keep its generation.
            if let deviceID = MacCoreAudioTransport.deviceID(
                forUID: lease.deviceUID
            ) {
                _ = installVolumeListenersOnQueue(
                    deviceID: deviceID,
                    elements: lease.original.keys
                )
            }
            return
        }
        restoreLeaseIfPossibleOnQueue()
    }

    private func handleVolumeChangeOnQueue() {
        guard let lease,
              let deviceID = MacCoreAudioTransport.deviceID(forUID: lease.deviceUID),
              let current = currentVolumes(deviceID: deviceID, lease: lease)
        else {
            scheduleRecoveryRetryOnQueue()
            return
        }
        guard MacCompetingMediaLeasePolicy.ownsLiveState(
            current: current,
            lease: lease
        ) else {
            abandonForExternalChangeOnQueue(observed: current)
            return
        }
        if currentDefaultOutputUID() != lease.deviceUID {
            restoreLeaseIfPossibleOnQueue()
        }
    }
}
