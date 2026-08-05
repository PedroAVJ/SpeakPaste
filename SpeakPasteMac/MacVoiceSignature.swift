import Accelerate
import AVFoundation
import Foundation

/// A fixed-length acoustic fingerprint of one voice, derived from mel-frequency
/// cepstral coefficients.
///
/// This is deliberately a summary and not audio. Enrolling a voice means
/// keeping a few dozen numbers describing its spectral shape; the recording
/// they came from is still deleted on the normal schedule, and nothing here can
/// be played back or reconstructed into speech.
///
/// The vector is L2-normalized on the way in so comparison is a plain dot
/// product and loudness drops out: the same person dictating quietly and
/// loudly should land in the same place.
struct MacVoiceSignature: Codable, Equatable, Sendable {
    /// Twelve cepstral means followed by twelve cepstral standard deviations.
    /// The mean captures the voice's average spectral envelope; the deviation
    /// captures how much it moves, which separates a person from a steady
    /// background source that happens to share an envelope.
    static let dimensions = 24

    let values: [Double]

    /// Nil for any vector that is not a usable unit-length fingerprint. A
    /// zero, non-finite, or wrong-length vector would silently poison every
    /// later comparison, so it is refused at construction instead.
    init?(values: [Double]) {
        guard
            values.count == Self.dimensions,
            values.allSatisfy(\.isFinite)
        else {
            return nil
        }
        let magnitude = sqrt(values.reduce(0) { $0 + $1 * $1 })
        guard magnitude.isFinite, magnitude > 1e-9 else { return nil }
        self.values = values.map { $0 / magnitude }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decoded = try container.decode([Double].self)
        guard let signature = Self(values: decoded) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unusable voice signature vector."
            )
        }
        self = signature
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    /// Both operands are unit vectors, so this is the cosine of the angle
    /// between them: 1 is identical, 0 is unrelated.
    func similarity(to other: MacVoiceSignature) -> Double {
        zip(values, other.values).reduce(0) { $0 + $1.0 * $1.1 }
    }

    /// The unit-length average of a group. Used to turn several enrolled
    /// samples into one point to compare against.
    static func centroid(of signatures: [MacVoiceSignature]) -> MacVoiceSignature? {
        guard !signatures.isEmpty else { return nil }
        var summed = [Double](repeating: 0, count: dimensions)
        for signature in signatures {
            for index in 0..<dimensions {
                summed[index] += signature.values[index]
            }
        }
        return MacVoiceSignature(values: summed)
    }
}

/// Turns raw PCM into a `MacVoiceSignature`.
///
/// The analysis is deliberately sample-rate independent: the window is a fixed
/// number of milliseconds and the mel bank spans a fixed frequency range, so a
/// 48 kHz Continuity capture and a 16 kHz file produce comparable vectors
/// without a resampling stage that could itself color the result.
enum MacVoiceAnalysis {
    static let melFilterCount = 26
    /// Coefficient zero is overall loudness, which says more about how far the
    /// mouth was from the microphone than about who was speaking. It is
    /// computed and dropped, leaving twelve shape coefficients.
    static let keptCepstralCoefficients = 12
    static let lowerFrequency: Double = 80
    static let upperFrequency: Double = 7_600
    static let windowSeconds: Double = 0.025
    static let hopSeconds: Double = 0.010
    static let preEmphasis: Float = 0.97
    /// Below this there is not enough voiced audio to characterize anything;
    /// a fingerprint built from a fraction of a second would be noise.
    static let minimumVoicedFrames = 20

    static func signature(samples: [Float], sampleRate: Double) -> MacVoiceSignature? {
        guard
            sampleRate.isFinite,
            sampleRate > 0,
            !samples.isEmpty
        else {
            return nil
        }

        let windowLength = max(16, Int((windowSeconds * sampleRate).rounded()))
        let hop = max(1, Int((hopSeconds * sampleRate).rounded()))
        guard samples.count >= windowLength else { return nil }

        var fftSize = 1
        while fftSize < windowLength { fftSize <<= 1 }
        let log2n = vDSP_Length(log2(Double(fftSize)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return nil
        }
        defer { vDSP_destroy_fftsetup(setup) }

        let binCount = fftSize / 2
        let filterBank = melFilterBank(
            binCount: binCount,
            fftSize: fftSize,
            sampleRate: sampleRate
        )

        // Pre-emphasis lifts the high frequencies that carry most of a voice's
        // identifying detail and that a small microphone rolls off.
        var emphasized = [Float](repeating: 0, count: samples.count)
        emphasized[0] = samples[0]
        for index in 1..<samples.count {
            emphasized[index] = samples[index] - preEmphasis * samples[index - 1]
        }

        var window = [Float](repeating: 0, count: windowLength)
        vDSP_hamm_window(&window, vDSP_Length(windowLength), 0)

        var frameLevels: [Float] = []
        var frameCepstra: [[Double]] = []
        var offset = 0
        while offset + windowLength <= emphasized.count {
            let frame = Array(emphasized[offset..<(offset + windowLength)])

            var level: Float = 0
            vDSP_rmsqv(frame, 1, &level, vDSP_Length(windowLength))

            var windowed = [Float](repeating: 0, count: windowLength)
            vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(windowLength))

            let power = powerSpectrum(
                frame: windowed,
                fftSize: fftSize,
                log2n: log2n,
                setup: setup
            )

            var logEnergies = [Double](repeating: 0, count: melFilterCount)
            for filterIndex in 0..<melFilterCount {
                var energy: Float = 0
                vDSP_dotpr(
                    power,
                    1,
                    filterBank[filterIndex],
                    1,
                    &energy,
                    vDSP_Length(binCount)
                )
                // The floor keeps log() finite through digital silence.
                logEnergies[filterIndex] = log(max(Double(energy), 1e-10))
            }

            frameLevels.append(level)
            frameCepstra.append(discreteCosineTransform(logEnergies))
            offset += hop
        }

        guard let loudestFrame = frameLevels.max(), loudestFrame > 0 else {
            return nil
        }
        // Silence and room tone between phrases would otherwise dominate a
        // whispered dictation, where the pauses outweigh the speech.
        let levelGate = max(loudestFrame * 0.06, 1e-5)
        let voiced = zip(frameLevels, frameCepstra)
            .filter { $0.0 >= levelGate }
            .map(\.1)
        guard voiced.count >= minimumVoicedFrames else { return nil }

        var means = [Double](repeating: 0, count: keptCepstralCoefficients)
        for cepstrum in voiced {
            for index in 0..<keptCepstralCoefficients {
                means[index] += cepstrum[index + 1]
            }
        }
        for index in 0..<keptCepstralCoefficients {
            means[index] /= Double(voiced.count)
        }

        var deviations = [Double](repeating: 0, count: keptCepstralCoefficients)
        for cepstrum in voiced {
            for index in 0..<keptCepstralCoefficients {
                let delta = cepstrum[index + 1] - means[index]
                deviations[index] += delta * delta
            }
        }
        for index in 0..<keptCepstralCoefficients {
            deviations[index] = sqrt(deviations[index] / Double(voiced.count))
        }

        return MacVoiceSignature(values: means + deviations)
    }

    private static func powerSpectrum(
        frame: [Float],
        fftSize: Int,
        log2n: vDSP_Length,
        setup: FFTSetup
    ) -> [Float] {
        var padded = frame
        if padded.count < fftSize {
            padded.append(contentsOf: [Float](repeating: 0, count: fftSize - padded.count))
        }
        let binCount = fftSize / 2
        var real = [Float](repeating: 0, count: binCount)
        var imaginary = [Float](repeating: 0, count: binCount)
        var power = [Float](repeating: 0, count: binCount)

        padded.withUnsafeBufferPointer { paddedBuffer in
            paddedBuffer.baseAddress!.withMemoryRebound(
                to: DSPComplex.self,
                capacity: binCount
            ) { interleaved in
                real.withUnsafeMutableBufferPointer { realBuffer in
                    imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                        var split = DSPSplitComplex(
                            realp: realBuffer.baseAddress!,
                            imagp: imaginaryBuffer.baseAddress!
                        )
                        vDSP_ctoz(interleaved, 2, &split, 1, vDSP_Length(binCount))
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        // A real-input FFT packs Nyquist into the imaginary
                        // part of bin zero. Left in place it would be squared
                        // into the DC bin and inflate the lowest mel filter.
                        imaginaryBuffer.baseAddress![0] = 0
                        power.withUnsafeMutableBufferPointer { powerBuffer in
                            vDSP_zvmags(
                                &split,
                                1,
                                powerBuffer.baseAddress!,
                                1,
                                vDSP_Length(binCount)
                            )
                        }
                    }
                }
            }
        }
        return power
    }

    private static func melFilterBank(
        binCount: Int,
        fftSize: Int,
        sampleRate: Double
    ) -> [[Float]] {
        func toMel(_ frequency: Double) -> Double {
            2_595 * log10(1 + frequency / 700)
        }
        func fromMel(_ mel: Double) -> Double {
            700 * (pow(10, mel / 2_595) - 1)
        }

        let nyquist = sampleRate / 2
        let upper = min(upperFrequency, nyquist * 0.98)
        let lower = min(lowerFrequency, upper / 2)
        let melLow = toMel(lower)
        let melHigh = toMel(upper)
        let edges = (0...(melFilterCount + 1)).map { index in
            fromMel(
                melLow + (melHigh - melLow) * Double(index) / Double(melFilterCount + 1)
            )
        }

        let binWidth = sampleRate / Double(fftSize)
        return (0..<melFilterCount).map { filterIndex in
            let left = edges[filterIndex]
            let center = edges[filterIndex + 1]
            let right = edges[filterIndex + 2]
            var weights = [Float](repeating: 0, count: binCount)
            for bin in 0..<binCount {
                let frequency = Double(bin) * binWidth
                if frequency >= left, frequency <= center, center > left {
                    weights[bin] = Float((frequency - left) / (center - left))
                } else if frequency > center, frequency <= right, right > center {
                    weights[bin] = Float((right - frequency) / (right - center))
                }
            }
            return weights
        }
    }

    /// DCT-II over the mel log energies. The transform is small enough that a
    /// direct evaluation is clearer than an FFT-based one and costs nothing at
    /// twenty-six inputs.
    private static func discreteCosineTransform(_ input: [Double]) -> [Double] {
        let count = input.count
        return (0...keptCepstralCoefficients).map { coefficient in
            var sum = 0.0
            for index in 0..<count {
                sum += input[index] * cos(
                    Double.pi * Double(coefficient) * (Double(index) + 0.5) / Double(count)
                )
            }
            return sum
        }
    }
}

/// Reads selected time spans out of a finished dictation recording.
///
/// Only the spans a caller asks for are decoded, and never more than a bounded
/// number of seconds. A twenty-minute dictation must not be pulled into memory
/// in full just to characterize the voices in it.
enum MacDictationAudioReader {
    /// Thirty seconds of speech is far more than a cepstral fingerprint needs,
    /// and caps the work regardless of how long the dictation ran.
    static let analysisBudget: TimeInterval = 30

    static func samples(
        at url: URL,
        ranges: [ClosedRange<TimeInterval>],
        budget: TimeInterval = analysisBudget
    ) -> (samples: [Float], sampleRate: Double)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0, file.length > 0 else { return nil }

        var remainingFrames = Int((budget * sampleRate).rounded())
        guard remainingFrames > 0 else { return nil }

        var collected: [Float] = []
        for range in ranges {
            guard remainingFrames > 0 else { break }
            let startFrame = AVAudioFramePosition((range.lowerBound * sampleRate).rounded())
            guard startFrame >= 0, startFrame < file.length else { continue }
            let available = Int(file.length - startFrame)
            let requested = Int(((range.upperBound - range.lowerBound) * sampleRate).rounded())
            let frameCount = min(min(requested, available), remainingFrames)
            guard frameCount > 0 else { continue }

            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            ) else {
                continue
            }
            file.framePosition = startFrame
            guard (try? file.read(into: buffer, frameCount: AVAudioFrameCount(frameCount))) != nil,
                  buffer.frameLength > 0,
                  let channels = buffer.floatChannelData else {
                continue
            }

            let readCount = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            collected.reserveCapacity(collected.count + readCount)
            for frame in 0..<readCount {
                var total: Float = 0
                for channel in 0..<channelCount {
                    total += channels[channel][frame]
                }
                collected.append(total / Float(max(1, channelCount)))
            }
            remainingFrames -= readCount
        }

        guard !collected.isEmpty else { return nil }
        return (collected, sampleRate)
    }

    /// Collapses a speaker's word spans into as few read ranges as possible.
    /// Adjacent words produce hundreds of tiny spans; merging them keeps the
    /// reader from seeking once per word, and closing small gaps preserves the
    /// natural co-articulation between them.
    static func mergedRanges(
        _ ranges: [ClosedRange<TimeInterval>],
        joiningGapsUnder gap: TimeInterval = 0.2
    ) -> [ClosedRange<TimeInterval>] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<TimeInterval>] = []
        for range in sorted {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }
            if range.lowerBound - last.upperBound <= gap {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
