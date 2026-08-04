#!/usr/bin/env python3
"""Generate and verify SpeakPaste's deterministic macOS earcon family.

The cues intentionally use one restrained struck-tone instrument. Capture,
release, and verified delivery are single notes that rise through an E-major
arc; attention is the family's only phrase, inverted low and falling. No
samples or generative audio are used.
"""

from __future__ import annotations

import argparse
import math
import re
import shutil
import subprocess
import tempfile
import wave
from dataclasses import dataclass
from pathlib import Path

import numpy as np


SAMPLE_RATE = 44_100
ATTACK_SECONDS = 0.008
FUNDAMENTAL_TAU_SECONDS = 0.085
PARTIAL_TAU_SECONDS = 0.045
FINAL_FADE_SECONDS = 0.020
TRIM_THRESHOLD_DBFS = -60.0


@dataclass(frozen=True)
class Note:
    onset_seconds: float
    frequency_hz: float


@dataclass(frozen=True)
class Cue:
    filename: str
    notes: tuple[Note, ...]
    peak_dbfs: float
    approximate_duration_seconds: float


# Equal-tempered pitches named in the product grammar. Verification accepts
# the rounded values from the design spec (659, 988, 1,319, 330, and 247 Hz).
E5 = 659.255
B5 = 987.767
E6 = 1_318.510
E4 = 329.628
B3 = 246.942

CUES = (
    Cue("capture-live.caf", (Note(0.0, E5),), -16.0, 0.400),
    Cue("capture-released.caf", (Note(0.0, B5),), -16.0, 0.400),
    Cue(
        "delivery-verified.caf",
        (Note(0.0, E6),),
        -14.0,
        0.400,
    ),
    Cue(
        "needs-attention.caf",
        (Note(0.0, E4), Note(0.250, B3)),
        -12.0,
        0.750,
    ),
)


def amplitude_for_dbfs(dbfs: float) -> float:
    return 10.0 ** (dbfs / 20.0)


def dbfs_for_amplitude(amplitude: float) -> float:
    if amplitude <= 0:
        return -math.inf
    return 20.0 * math.log10(amplitude)


def struck_partial(
    local_time: np.ndarray,
    frequency_hz: float,
    relative_amplitude: float,
    decay_tau_seconds: float,
) -> np.ndarray:
    attack_progress = np.clip(local_time / ATTACK_SECONDS, 0.0, 1.0)
    attack = 0.5 - 0.5 * np.cos(np.pi * attack_progress)
    decay_time = np.maximum(local_time - ATTACK_SECONDS, 0.0)
    decay = np.exp(-decay_time / decay_tau_seconds)
    return (
        relative_amplitude
        * np.sin(2.0 * np.pi * frequency_hz * local_time)
        * attack
        * decay
    )


def render_note(frequency_hz: float, frame_count: int) -> np.ndarray:
    local_time = np.arange(frame_count, dtype=np.float64) / SAMPLE_RATE
    return (
        struck_partial(local_time, frequency_hz, 1.00, FUNDAMENTAL_TAU_SECONDS)
        + struck_partial(local_time, frequency_hz * 2.0, 0.10, PARTIAL_TAU_SECONDS)
        + struck_partial(local_time, frequency_hz * 3.0, 0.03, PARTIAL_TAU_SECONDS)
    )


def render_cue(cue: Cue) -> np.ndarray:
    # Render a generous tail first. The normalized signal is then cut where its
    # last sample reaches -60 dBFS and tapered to exact zero over 20 ms.
    render_seconds = max(note.onset_seconds for note in cue.notes) + 0.800
    frame_count = math.ceil(render_seconds * SAMPLE_RATE)
    signal = np.zeros(frame_count, dtype=np.float64)

    for note in cue.notes:
        onset_frame = round(note.onset_seconds * SAMPLE_RATE)
        signal[onset_frame:] += render_note(note.frequency_hz, frame_count - onset_frame)

    target_peak = amplitude_for_dbfs(cue.peak_dbfs)
    raw_peak = float(np.max(np.abs(signal)))
    if raw_peak == 0:
        raise RuntimeError(f"{cue.filename}: synthesis produced silence")
    signal *= target_peak / raw_peak

    threshold = amplitude_for_dbfs(TRIM_THRESHOLD_DBFS)
    above_threshold = np.flatnonzero(np.abs(signal) >= threshold)
    if above_threshold.size == 0:
        raise RuntimeError(f"{cue.filename}: signal never reached trim threshold")

    fade_start = int(above_threshold[-1])
    fade_frames = round(FINAL_FADE_SECONDS * SAMPLE_RATE)
    end_frame = min(signal.size, fade_start + fade_frames)
    signal = signal[:end_frame].copy()
    fade_length = signal.size - fade_start
    if fade_length > 1:
        fade = 0.5 + 0.5 * np.cos(np.linspace(0.0, np.pi, fade_length))
        signal[fade_start:] *= fade
    signal[-1] = 0.0

    quantized = np.rint(signal * 32_767.0)
    return np.clip(quantized, -32_768, 32_767).astype("<i2")


def write_wav(path: Path, samples: np.ndarray) -> None:
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(SAMPLE_RATE)
        output.writeframes(samples.tobytes())


def run(command: list[str]) -> str:
    completed = subprocess.run(
        command,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    return completed.stdout


def generate(output_directory: Path) -> None:
    output_directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="speakpaste-earcons-") as raw_temp:
        temp_directory = Path(raw_temp)
        for cue in CUES:
            wav_path = temp_directory / cue.filename.replace(".caf", ".wav")
            caf_path = temp_directory / cue.filename
            write_wav(wav_path, render_cue(cue))
            run(
                [
                    "afconvert",
                    str(wav_path),
                    "-o",
                    str(caf_path),
                    "-f",
                    "caff",
                    "-d",
                    f"LEI16@{SAMPLE_RATE}",
                    "-c",
                    "1",
                    "--no-filler",
                ]
            )
            caf_path.replace(output_directory / cue.filename)


def read_caf_samples(path: Path, temp_directory: Path) -> np.ndarray:
    decoded_path = temp_directory / path.with_suffix(".wav").name
    run(
        [
            "afconvert",
            str(path),
            "-o",
            str(decoded_path),
            "-f",
            "WAVE",
            "-d",
            f"LEI16@{SAMPLE_RATE}",
            "-c",
            "1",
        ]
    )
    with wave.open(str(decoded_path), "rb") as decoded:
        if decoded.getnchannels() != 1:
            raise AssertionError(f"{path.name}: expected mono audio")
        if decoded.getsampwidth() != 2:
            raise AssertionError(f"{path.name}: expected 16-bit audio")
        if decoded.getframerate() != SAMPLE_RATE:
            raise AssertionError(f"{path.name}: expected {SAMPLE_RATE} Hz")
        frames = decoded.readframes(decoded.getnframes())
    return np.frombuffer(frames, dtype="<i2").astype(np.float64) / 32_768.0


def estimate_frequency(samples: np.ndarray, onset_seconds: float, expected_hz: float) -> float:
    analysis_start = round((onset_seconds + 0.012) * SAMPLE_RATE)
    analysis_frames = round(0.150 * SAMPLE_RATE)
    windowed = samples[analysis_start : analysis_start + analysis_frames].copy()
    if windowed.size != analysis_frames:
        raise AssertionError("cue is too short for pitch verification")
    windowed -= float(np.mean(windowed))
    windowed *= np.hanning(windowed.size)

    fft_size = 131_072
    spectrum = np.abs(np.fft.rfft(windowed, n=fft_size))
    frequencies = np.fft.rfftfreq(fft_size, d=1.0 / SAMPLE_RATE)
    candidates = np.flatnonzero(
        (frequencies >= expected_hz - 25.0) & (frequencies <= expected_hz + 25.0)
    )
    peak_index = int(candidates[np.argmax(spectrum[candidates])])

    # Quadratic interpolation around the spectral maximum gives sub-bin pitch
    # estimates without pretending the 150 ms window has infinite resolution.
    if 0 < peak_index < spectrum.size - 1:
        left, center, right = np.log(np.maximum(spectrum[peak_index - 1 : peak_index + 2], 1e-15))
        denominator = left - 2.0 * center + right
        offset = 0.0 if denominator == 0 else 0.5 * (left - right) / denominator
    else:
        offset = 0.0
    return float((peak_index + offset) * SAMPLE_RATE / fft_size)


def verify(output_directory: Path) -> None:
    results: dict[str, tuple[float, float, float]] = {}
    pitch_lines: list[str] = []

    with tempfile.TemporaryDirectory(prefix="speakpaste-earcon-check-") as raw_temp:
        temp_directory = Path(raw_temp)
        for cue in CUES:
            path = output_directory / cue.filename
            if not path.is_file():
                raise AssertionError(f"missing cue: {path}")

            afinfo = run(["afinfo", str(path)])
            if "File type ID:   caff" not in afinfo:
                raise AssertionError(f"{cue.filename}: expected CAF container")
            if not re.search(r"Data format:\s+1 ch,\s+44100 Hz, Int16", afinfo):
                raise AssertionError(f"{cue.filename}: expected mono 44.1 kHz Int16 LPCM")
            duration_match = re.search(r"estimated duration:\s+([0-9.]+) sec", afinfo)
            if duration_match is None:
                raise AssertionError(f"{cue.filename}: afinfo did not report duration")
            duration = float(duration_match.group(1))
            if abs(duration - cue.approximate_duration_seconds) > 0.100:
                raise AssertionError(
                    f"{cue.filename}: duration {duration:.3f}s is not approximately "
                    f"{cue.approximate_duration_seconds:.3f}s"
                )

            samples = read_caf_samples(path, temp_directory)
            if samples[-1] != 0.0:
                raise AssertionError(f"{cue.filename}: final sample must be zero")
            if abs(float(np.mean(samples))) > amplitude_for_dbfs(-70.0):
                raise AssertionError(f"{cue.filename}: unexpected DC offset")
            peak_dbfs = dbfs_for_amplitude(float(np.max(np.abs(samples))))
            if abs(peak_dbfs - cue.peak_dbfs) > 0.12:
                raise AssertionError(
                    f"{cue.filename}: peak {peak_dbfs:.2f} dBFS, expected {cue.peak_dbfs:.2f} dBFS"
                )
            rms_dbfs = dbfs_for_amplitude(float(np.sqrt(np.mean(np.square(samples)))))
            results[cue.filename] = (duration, peak_dbfs, rms_dbfs)

            for note in cue.notes:
                measured_hz = estimate_frequency(samples, note.onset_seconds, note.frequency_hz)
                if abs(measured_hz - note.frequency_hz) > 2.0:
                    raise AssertionError(
                        f"{cue.filename}: measured {measured_hz:.1f} Hz, "
                        f"expected {note.frequency_hz:.1f} Hz"
                    )
                pitch_lines.append(
                    f"  {cue.filename}@{note.onset_seconds:.3f}s: {measured_hz:.1f} Hz"
                )

    capture_rms = results["capture-live.caf"][2]
    release_rms = results["capture-released.caf"][2]
    if abs(capture_rms - release_rms) > 0.15:
        raise AssertionError(
            "capture-pair RMS values differ by more than 0.15 dB: "
            f"{capture_rms:.2f}, {release_rms:.2f}"
        )

    success_names = (
        "capture-live.caf",
        "capture-released.caf",
        "delivery-verified.caf",
    )
    crest_factors = [
        results[name][1] - results[name][2]
        for name in success_names
    ]
    crest_center = sum(crest_factors) / len(crest_factors)
    if any(abs(value - crest_center) > 1.0 for value in crest_factors):
        raise AssertionError(
            "single-ping crest factors differ by more than +/-1 dB: "
            + ", ".join(f"{value:.2f}" for value in crest_factors)
        )

    print("Verified SpeakPaste earcon family:")
    for cue in CUES:
        duration, peak_dbfs, rms_dbfs = results[cue.filename]
        print(
            f"  {cue.filename}: {duration:.3f}s, "
            f"peak {peak_dbfs:.2f} dBFS, RMS {rms_dbfs:.2f} dBFS"
        )
    print("Measured fundamentals:")
    print("\n".join(pitch_lines))


def verify_deterministic_pcm(output_directory: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="speakpaste-earcon-repeat-") as raw_repeat:
        repeat_directory = Path(raw_repeat) / "cues"
        original_decode_directory = Path(raw_repeat) / "decoded-original"
        repeated_decode_directory = Path(raw_repeat) / "decoded-repeat"
        original_decode_directory.mkdir()
        repeated_decode_directory.mkdir()
        generate(repeat_directory)
        for cue in CUES:
            installed_pcm = read_caf_samples(
                output_directory / cue.filename,
                original_decode_directory,
            )
            repeated_pcm = read_caf_samples(
                repeat_directory / cue.filename,
                repeated_decode_directory,
            )
            if not np.array_equal(installed_pcm, repeated_pcm):
                raise AssertionError(f"{cue.filename}: repeated synthesis changed decoded PCM")
    print("Repeated synthesis produced byte-identical decoded PCM.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--verify-only",
        action="store_true",
        help="verify existing CAF files without regenerating them",
    )
    parser.add_argument(
        "--output-directory",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "SpeakPasteMac" / "Sounds",
        help="directory containing the four CAF files",
    )
    args = parser.parse_args()

    for required_tool in ("afconvert", "afinfo"):
        if shutil.which(required_tool) is None:
            raise SystemExit(f"required macOS tool is missing: {required_tool}")

    if not args.verify_only:
        generate(args.output_directory)
    verify(args.output_directory)
    if not args.verify_only:
        verify_deterministic_pcm(args.output_directory)


if __name__ == "__main__":
    main()
