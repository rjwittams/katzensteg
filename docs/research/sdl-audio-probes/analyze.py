"""Analyse SDL audio probe runs: tone checks on taps and disk output, cadence.

usage: python3 -I analyze.py RUNS_DIR

For every run directory it reads probe.out, katz.log, the interposer taps
(tap.<tag><seq>.raw/.meta/.cadence) and the disk driver output (disk.raw,
disk.raw.seg2) and prints one markdown table row per tap and per disk file.
"""

import json
import os
import re
import sys

import numpy as np

FREQ = 440.0
AMP = 0.5
RATE = 48000
EXPECTED_RMS = AMP / np.sqrt(2)


def decode(path, fmt, channels):
    raw = np.fromfile(path, dtype=np.uint8)
    if fmt == 0x8120:
        data = raw[: len(raw) // 4 * 4].view(np.float32).astype(np.float64)
    elif fmt == 0x8010:
        data = raw[: len(raw) // 2 * 2].view(np.int16).astype(np.float64) / 32768.0
    else:
        raise ValueError(f"format 0x{fmt:04x}")
    return data[: len(data) // channels * channels].reshape(-1, channels)


def guess_disk_format(path):
    """Disk output carries no header: F32 if it decodes as sane floats."""
    raw = np.fromfile(path, dtype=np.uint8)
    if len(raw) % 4 == 0 and len(raw):
        f = raw.view(np.float32)
        if np.all(np.isfinite(f)) and np.max(np.abs(f)) <= 1.5:
            return 0x8120
    return 0x8010


def tone_stats(frames):
    """Statistics over the active (non-silent) region of channel 0."""
    if frames.size == 0:
        return {"frames": 0, "active": 0, "rms": 0.0, "peak": 0.0, "freq": 0.0, "glitches": 0, "dropouts": 0,
                "ch_match": True}
    x = frames[:, 0]
    nz = np.nonzero(np.abs(x) > 1e-4)[0]
    stats = {"frames": int(len(x)), "ch_match": bool(np.allclose(frames[:, 0], frames[:, -1]))}
    if len(nz) == 0:
        stats.update(active=0, rms=0.0, peak=0.0, freq=0.0, glitches=0, dropouts=0)
        return stats
    a = x[nz[0]: nz[-1] + 1]
    stats["active"] = int(len(a))
    stats["rms"] = float(np.sqrt(np.mean(a * a)))
    stats["peak"] = float(np.max(np.abs(a)))
    spec = np.abs(np.fft.rfft(a * np.hanning(len(a))))
    k = int(np.argmax(spec[1:]) + 1)
    stats["freq"] = float(k * RATE / len(a))
    d2 = np.abs(a[2:] - 2 * a[1:-1] + a[:-2])
    stats["glitches"] = int(np.sum(d2 > 0.01))
    # interior runs of >= 32 exact zeros: dropouts inside the tone
    z = (a == 0.0).astype(np.int8)
    edges = np.diff(np.concatenate(([0], z, [0])))
    starts, ends = np.nonzero(edges == 1)[0], np.nonzero(edges == -1)[0]
    stats["dropouts"] = int(np.sum((ends - starts) >= 32))
    return stats


def cadence(path, fmt, channels):
    rows = [line.split() for line in open(path) if line.strip()]
    if len(rows) < 3:
        return None
    t = np.array([int(r[0]) for r in rows], dtype=np.float64) / 1e6  # ms
    n = np.array([int(r[1]) for r in rows], dtype=np.float64)
    bps = channels * (4 if fmt == 0x8120 else 2) * RATE / 1000.0  # bytes per ms
    dt = np.diff(t)
    period = float(np.median(n) / bps)
    span = t[-1] - t[0]
    return {
        "calls": len(rows),
        "len_median": int(np.median(n)),
        "len_set": sorted({int(v) for v in n})[:4],
        "period_ms": period,
        "interval_median_ms": float(np.median(dt)),
        "interval_max_ms": float(np.max(dt)),
        "burst_frac": float(np.mean(dt < 0.5)),
        "rate_ratio": float(np.sum(n[:-1]) / bps / span) if span > 0 else 0.0,
    }


def parse_meta(path):
    meta = {}
    for tok in open(path).read().split():
        k, v = tok.split("=")
        meta[k] = int(v, 0)
    return meta


def log_summary(path):
    if not os.path.exists(path):
        return {}
    counts = {}
    tags = set()
    for line in open(path):
        m = re.match(r"\[(\S+?)-\s", line)
        if m:
            tags.add(m.group(1))
        m = re.search(r"\] (?:observe )?(SDL_\w+)\(", line)
        if m and m.group(1) != "SDL_DYNAPI_entry":
            key = f"{line[1:line.index('-')]}:{m.group(1)}"
            counts[key] = counts.get(key, 0) + 1
        if "SDL_DYNAPI_entry from" in line:
            counts["sdl3dyn:SDL_DYNAPI_entry"] = counts.get("sdl3dyn:SDL_DYNAPI_entry", 0) + 1
    return {"tags": sorted(tags), "calls": counts}


def fmt_stats(s):
    if s["active"] == 0:
        return "silent"
    return (f"rms {s['rms']:.4f} ({s['rms'] / EXPECTED_RMS:.3f}x), {s['freq']:.1f} Hz, "
            f"{s['active']} frames, glitches {s['glitches']}, dropouts {s['dropouts']}")


def main(runs):
    summary = {}
    print("| run | exit | source | content | cadence |")
    print("| --- | --- | --- | --- | --- |")
    for name in sorted(os.listdir(runs)):
        d = os.path.join(runs, name)
        if not os.path.isdir(d):
            continue
        out = open(os.path.join(d, "probe.out")).read() if os.path.exists(os.path.join(d, "probe.out")) else ""
        m = re.findall(r"exit=(\d+)", out)
        code = m[-1] if m else "?"
        entry = {"exit": code, "log": log_summary(os.path.join(d, "katz.log")), "taps": {}, "disk": {}}
        for f in sorted(os.listdir(d)):
            p = os.path.join(d, f)
            if f.startswith("tap.") and f.endswith(".raw"):
                stem = p[:-4]
                meta = parse_meta(stem + ".meta")
                s = tone_stats(decode(p, meta["format"], meta["channels"]))
                c = cadence(stem + ".cadence", meta["format"], meta["channels"]) if os.path.exists(stem + ".cadence") else None
                entry["taps"][f] = {"meta": meta, "stats": s, "cadence": c}
                cad = "n/a" if not c else (
                    f"{c['calls']} calls x {c['len_median']} B, period {c['period_ms']:.2f} ms, "
                    f"median gap {c['interval_median_ms']:.2f} ms, max gap {c['interval_max_ms']:.1f} ms, "
                    f"bursts {c['burst_frac']:.0%}, data/wall {c['rate_ratio']:.3f}")
                print(f"| {name} | {code} | {f[4:-4]} fmt=0x{meta['format']:04x} ch={meta['channels']} {meta['freq']} Hz"
                      f" tid_changes={meta['tid_changes']} | {fmt_stats(s)} | {cad} |")
            elif f.startswith("disk.raw"):
                fmtc = guess_disk_format(p)
                s = tone_stats(decode(p, fmtc, 2))
                entry["disk"][f] = {"format": fmtc, "stats": s}
                print(f"| {name} | {code} | {f} ({os.path.getsize(p)} B, read as 0x{fmtc:04x}) | {fmt_stats(s)} | |")
        # Byte-exact check: is each tap a contiguous run of the disk output?
        for tap_name, tap in entry["taps"].items():
            seg = tap_name.split(".")[1][-1]
            disk_name = "disk.raw" if seg == "0" else "disk.raw.seg2"
            dp = os.path.join(d, disk_name)
            if not os.path.exists(dp):
                continue
            tb = open(os.path.join(d, tap_name), "rb").read()
            db = open(dp, "rb").read()
            probe = tb[: min(len(tb), 65536)]
            off = db.find(probe) if probe.strip(b"\0") else -1
            exact = off >= 0 and db[off: off + len(tb)] == tb
            tap["disk_exact"] = exact
            if exact:
                print(f"| {name} | {code} | {tap_name[4:-4]} vs {disk_name} | tap bytes == disk bytes at offset {off} "
                      f"({len(tb)} of {len(db)} B) | |")
        calls = entry["log"].get("calls", {})
        print(f"| {name} | {code} | log | " + ", ".join(f"{k} x{v}" for k, v in sorted(calls.items())) + " | |")
        summary[name] = entry
    with open(os.path.join(runs, "summary.json"), "w") as fh:
        json.dump(summary, fh, indent=1)


if __name__ == "__main__":
    main(sys.argv[1])
