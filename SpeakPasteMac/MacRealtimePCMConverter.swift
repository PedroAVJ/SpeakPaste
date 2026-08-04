@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Converts the device-native PCM buffers emitted by AVCapture into Scribe's
/// required mono, little-endian PCM16 stream. AVCaptureAudioDataOutput does not
/// reliably honor a requested 16 kHz output format on every Mac/Continuity
/// input, so the realtime path owns the sample-rate conversion explicitly.
final class MacRealtimePCMConverter {
    private final class ConversionInput: @unchecked Sendable {
        private let lock = NSLock()
        private let buffer: AVAudioPCMBuffer
        private var wasProvided = false

        init(buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }

        func next(
            status: UnsafeMutablePointer<AVAudioConverterInputStatus>
        ) -> AVAudioBuffer? {
            lock.lock()
            defer { lock.unlock() }
            guard !wasProvided else {
                status.pointee = .noDataNow
                return nil
            }
            wasProvided = true
            status.pointee = .haveData
            return buffer
        }
    }

    static let sampleRate: Double = 16_000

    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: true
    )!
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    func reset() {
        converter?.reset()
        converter = nil
        inputFormat = nil
    }

    func convert(_ sampleBuffer: CMSampleBuffer) -> Data? {
        guard
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
        else {
            return nil
        }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0, sampleCount <= Int(Int32.max) else { return nil }
        guard let input = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(sampleCount)
        ) else {
            return nil
        }
        input.frameLength = AVAudioFrameCount(sampleCount)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(sampleCount),
            into: input.mutableAudioBufferList
        ) == noErr else {
            return nil
        }
        return convert(input)
    }

    /// Internal for the focused converter regression test; production enters
    /// through CMSampleBuffer above.
    func convert(_ input: AVAudioPCMBuffer) -> Data? {
        guard input.frameLength > 0 else { return nil }
        if inputFormat?.isEqual(input.format) != true {
            inputFormat = input.format
            converter = AVAudioConverter(from: input.format, to: outputFormat)
        }
        guard let converter else { return nil }

        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let estimatedFrames = ceil(Double(input.frameLength) * ratio)
        let outputCapacity = AVAudioFrameCount(
            min(Double(UInt32.max), max(1, estimatedFrames + 512))
        )
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else {
            return nil
        }

        let inputProvider = ConversionInput(buffer: input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) {
            _, inputStatus in
            inputProvider.next(status: inputStatus)
        }
        guard
            conversionError == nil,
            status != .error,
            output.frameLength > 0
        else {
            return nil
        }
        return data(from: output)
    }

    /// Flushes the resampler after AVCapture has stopped so the final fraction
    /// of a syllable reaches Scribe before the manual commit.
    func finish() -> Data {
        guard let converter else {
            reset()
            return Data()
        }
        var result = Data()
        for _ in 0..<4 {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: 4_096
            ) else {
                break
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) {
                _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            guard conversionError == nil, status != .error else { break }
            if let converted = data(from: output) {
                result.append(converted)
            }
            if status == .endOfStream || output.frameLength == 0 { break }
        }
        reset()
        return result
    }

    private func data(from buffer: AVAudioPCMBuffer) -> Data? {
        let audioBufferList = buffer.audioBufferList.pointee
        guard
            audioBufferList.mNumberBuffers == 1,
            let bytes = audioBufferList.mBuffers.mData,
            audioBufferList.mBuffers.mDataByteSize > 0
        else {
            return nil
        }
        return Data(
            bytes: bytes,
            count: Int(audioBufferList.mBuffers.mDataByteSize)
        )
    }
}
