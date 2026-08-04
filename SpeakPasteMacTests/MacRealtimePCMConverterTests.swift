import AVFoundation
import XCTest
@testable import SpeakPaste

final class MacRealtimePCMConverterTests: XCTestCase {
    func testConvertsDeviceNativeFloatPCMToScribePCM16() throws {
        let sourceFormat = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 2,
                interleaved: false
            )
        )
        let input = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 4_800)
        )
        input.frameLength = 4_800
        for channel in 0..<Int(sourceFormat.channelCount) {
            let samples = try XCTUnwrap(input.floatChannelData?[channel])
            for index in 0..<Int(input.frameLength) {
                samples[index] = sin(Float(index) * 0.05) * 0.25
            }
        }

        let converter = MacRealtimePCMConverter()
        let converted = try XCTUnwrap(converter.convert(input))
        let tail = converter.finish()

        // 100 ms at 16 kHz mono PCM16 is approximately 3,200 bytes. The
        // resampler may retain a short filter tail until finish().
        XCTAssertGreaterThan(converted.count, 0)
        XCTAssertGreaterThan(converted.count + tail.count, 3_000)
        XCTAssertLessThan(converted.count + tail.count, 3_500)
        XCTAssertEqual(converted.count % MemoryLayout<Int16>.size, 0)
        XCTAssertLessThan(tail.count, 1_024)
    }

    func testConvertsSequential44100HzBuffersAndResetDoesNotLeakTail() throws {
        let sourceFormat = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 44_100,
                channels: 1,
                interleaved: false
            )
        )
        func makeInput() throws -> AVAudioPCMBuffer {
            let input = try XCTUnwrap(
                AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 4_410)
            )
            input.frameLength = 4_410
            let samples = try XCTUnwrap(input.floatChannelData?[0])
            for index in 0..<Int(input.frameLength) {
                samples[index] = sin(Float(index) * 0.04) * 0.2
            }
            return input
        }

        let converter = MacRealtimePCMConverter()
        let first = try XCTUnwrap(converter.convert(try makeInput()))
        let second = try XCTUnwrap(converter.convert(try makeInput()))
        let firstTail = converter.finish()
        let sequentialByteCount = first.count + second.count + firstTail.count
        XCTAssertGreaterThan(sequentialByteCount, 6_100)
        XCTAssertLessThan(sequentialByteCount, 6_700)

        converter.reset()
        let afterReset = try XCTUnwrap(converter.convert(try makeInput()))
        let resetTail = converter.finish()
        XCTAssertGreaterThan(afterReset.count + resetTail.count, 3_000)
        XCTAssertLessThan(afterReset.count + resetTail.count, 3_500)
    }
}
