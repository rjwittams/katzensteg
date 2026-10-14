"""Tone checks for SDL audio probe output, without numpy.

Ported from the research analyser (docs/research/sdl-audio-probes/analyze.py).
The probes (examples/probes/*/audio_probe.c) play the tone described by
examples/probes/common/audio_tone.h; these constants must match it.

Raw sink files carry no header, so `decode_raw` takes the SDL format code and
`guess_format` recognises F32 the way the research analyser did.
"""

import array
import math
import sys

FREQ = 440.0
AMPLITUDE = 0.5
RATE = 48000
CHANNELS = 2
EXPECTED_RMS = AMPLITUDE / math.sqrt(2)

AUDIO_S16 = 0x8010
AUDIO_F32 = 0x8120

# Activity threshold and the glitch/dropout rules match analyze.py.
SILENCE = 1e-4
GLITCH_D2 = 0.01
DROPOUT_ZEROS = 32


def _native(values):
    if sys.byteorder != "little":
        values.byteswap()
    return values


def decode_raw(data, fmt, channels=CHANNELS):
    """Return one list of floats in [-1, 1] per channel (little-endian input)."""
    if fmt == AUDIO_F32:
        values = array.array("f")
        values.frombytes(data[: len(data) // 4 * 4])
        samples = list(_native(values))
    elif fmt == AUDIO_S16:
        values = array.array("h")
        values.frombytes(data[: len(data) // 2 * 2])
        samples = [v / 32768.0 for v in _native(values)]
    else:
        raise ValueError(f"unsupported format 0x{fmt:04x}")
    frames = len(samples) // channels
    return [samples[c: frames * channels: channels] for c in range(channels)]


def guess_format(data):
    """Sink output carries no header: F32 if it decodes as sane floats."""
    if data and len(data) % 4 == 0:
        values = array.array("f")
        values.frombytes(data)
        if all(math.isfinite(v) and abs(v) <= 1.5 for v in _native(values)):
            return AUDIO_F32
    return AUDIO_S16


def _rising_crossings(x):
    """Interpolated sample positions where x crosses zero going up."""
    out = []
    for i in range(1, len(x)):
        a, b = x[i - 1], x[i]
        if a < 0.0 <= b:
            out.append(i - 1 + (-a) / (b - a))
    return out


def _goertzel_rms(x, freq):
    """RMS of the component of x at `freq`, over a whole number of cycles."""
    period = RATE / freq
    n = int(int(len(x) / period) * period)
    if n == 0:
        return 0.0
    w = 2.0 * math.pi * freq / RATE
    coeff = 2.0 * math.cos(w)
    s1 = s2 = 0.0
    for v in x[:n]:
        s1, s2 = v + coeff * s1 - s2, s1
    power = s1 * s1 + s2 * s2 - coeff * s1 * s2
    return math.sqrt(2.0 * power) / n


def tone_stats(channels):
    """Statistics over the active (non-silent) region of channel 0.

    rms, peak and freq describe the tone; purity is the fraction of its power
    at FREQ; glitches counts sample-to-sample discontinuities; dropouts counts
    interior runs of DROPOUT_ZEROS or more exact zeros; ch_match is whether
    every channel equals channel 0.
    """
    x = channels[0] if channels else []
    stats = {"frames": len(x), "active": 0, "rms": 0.0, "peak": 0.0, "freq": 0.0, "purity": 0.0,
             "glitches": 0, "dropouts": 0, "ch_match": all(c == x for c in channels[1:])}
    active = [i for i, v in enumerate(x) if abs(v) > SILENCE]
    if not active:
        return stats
    a = x[active[0]: active[-1] + 1]
    stats["active"] = len(a)
    mean_square = sum(v * v for v in a) / len(a)
    stats["rms"] = math.sqrt(mean_square)
    stats["peak"] = max(abs(v) for v in a)
    crossings = _rising_crossings(a)
    if len(crossings) >= 2:
        stats["freq"] = (len(crossings) - 1) * RATE / (crossings[-1] - crossings[0])
    if mean_square > 0.0:
        stats["purity"] = _goertzel_rms(a, FREQ) ** 2 / mean_square
    stats["glitches"] = sum(1 for i in range(2, len(a)) if abs(a[i] - 2 * a[i - 1] + a[i - 2]) > GLITCH_D2)
    run = 0
    for v in a:
        if v == 0.0:
            run += 1
            continue
        if run >= DROPOUT_ZEROS:
            stats["dropouts"] += 1
        run = 0
    return stats


def describe(stats):
    if stats["active"] == 0:
        return f"silent ({stats['frames']} frames)"
    return (f"rms {stats['rms']:.4f} ({stats['rms'] / EXPECTED_RMS:.3f}x), {stats['freq']:.2f} Hz, "
            f"purity {stats['purity']:.3f}, peak {stats['peak']:.3f}, {stats['active']} active of "
            f"{stats['frames']} frames, glitches {stats['glitches']}, dropouts {stats['dropouts']}, "
            f"channels match {stats['ch_match']}")


def analyze_file(path, fmt=None):
    """Decode a raw sink file and return (format, stats)."""
    with open(path, "rb") as fh:
        data = fh.read()
    fmt = fmt if fmt is not None else guess_format(data)
    return fmt, tone_stats(decode_raw(data, fmt))


if __name__ == "__main__":
    for arg in sys.argv[1:]:
        fmt, stats = analyze_file(arg)
        print(f"{arg} (read as 0x{fmt:04x}): {describe(stats)}")
