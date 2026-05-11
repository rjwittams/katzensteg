# Investigate: pi-extension multi-producer pause (sonic stalls at 1-second period)

## What we want from you

Find the actual mechanism by which `sonic` (a composite-path producer launched via the pi-extension) gets its host main thread effectively paused into a precise 1-second cadence when another producer (`jsr`) is running. The investigation has so far ruled out the most obvious causes — pi event loop saturation, producer-side blocking on instrumented spans, and image-id collision in the kitty graphics state. We are stuck on guesses; we want a real explanation.

This is a hard, weird bug. The most important thing you can do is *not* trust the existing hypotheses, including the user's intuition ("pi polling/fairness order") and the assistant's intuition ("macOS background-window throttling"). Both have been advanced and neither matches the full evidence. Reason from the data.

## Repos / files

- `/Users/robert/dev/katzensteg.cheshire` — Katzensteg producer (zig + C preload).
  - `src/katzensteg/runtime.zig` — preload runtime; `renderBatchPresent` (composite path) and `presentExternalFramebuffer` (vulkan path); `pollBatchControlLocked`; `flush_frame_jsonl` span.
  - `src/katzensteg/render_batch_sink.zig` — `uploadRgba`, `flushFrame`, blocking-trace points.
  - `src/katzensteg/wm_host.zig` — the WM host. Same `--embed-jsonl` protocol as pi-extension. WM does NOT have this problem.
  - `src/katzensteg/launcher.zig` — `runTarget` with `embed_jsonl`; sets `child.env_map`.
  - `src/katzensteg/blocking_trace.zig` — `KATZENSTEG_TRACE_BLOCKING=1` + `KATZENSTEG_TRACE_BLOCKING_THRESHOLD_MS` env.
  - `tools/pi-extension/extensions/katzensteg-panel.ts` — pi-side extension. Spawns katzensteg per panel via `KatzenstegProducer`. Each producer gets its own image/placement id range (recently fixed). Floating uses `FLOATING_Z_BASE=0`, inline uses `INLINE_Z_BASE=-100`.
- `/Users/robert/dev/pi-mono` — pi (TypeScript). Loaded via `node --import tsx packages/coding-agent/src/cli.ts --extension <katzensteg-panel.ts>`.

## Reproduction

```bash
cd /Users/robert/dev/katzensteg.cheshire && zig build  # rebuild katzensteg
KATZENSTEG_TRACE_BLOCKING=1 KATZENSTEG_TRACE_BLOCKING_THRESHOLD_MS=20 \
  node --import tsx /Users/robert/dev/pi-mono/packages/coding-agent/src/cli.ts \
  --extension /Users/robert/dev/katzensteg.cheshire/tools/pi-extension/extensions/katzensteg-panel.ts
```

Inside pi:

```
/katzensteg-panel inline sonic   # opens first inline panel running sonic
/katzensteg-panel inline jsr     # opens second inline panel running jsr
```

Observe sonic's panel hitching after jsr starts. Kill jsr → sonic recovers.

Log files:

- `/tmp/katzensteg-pi-extension.log` — pi-side `debugLog()` output. Includes `producer.live.chunk seq=N profile=X bytes=B lines=L frames=F us=T` per stdout chunk (only when `lines > 0` or `us >= 1000`). Also `pi.event_loop_lag_ms=N` when event loop lag > 150ms.
- `/tmp/katzensteg-<PID>.log` — per-producer (preload runtime) log. Includes `blocking trace enabled threshold_ms=N` at startup, `batch attach …`, and any blocking spans that exceed threshold (e.g., `batch_present.render_batch_present_locked`, `upload_rgba_file_whole_pwrite`, `flush_frame_jsonl`).

## Empirical findings (as of this writing)

### Pause pattern

Sonic's chunks (as seen by pi) arrive in roughly 1-second cadence during the pause. Inter-chunk gaps measured (from `producer.live.chunk` timestamps for `profile=sonic`):

```
2026-05-11T16:27:11.869Z  gap=1004ms
2026-05-11T16:27:13.917Z  gap= 999ms
2026-05-11T16:27:14.936Z  gap=1002ms
2026-05-11T16:27:16.983Z  gap= 993ms
2026-05-11T16:27:18.002Z  gap=1002ms
…
```

11 such gaps in 14 seconds. All 993-1005ms. Periodicity is precise enough that this is almost certainly a 1Hz clock somewhere, not contention.

During those sonic-silent windows, `jsr` is at 60fps (≈60 chunks per silent window). Pi's event loop is plainly not stalled — see below.

### What we have ruled out (or have strong evidence against)

- **Pi event loop saturation**: With `setImmediate`-based heartbeat measuring loop lag, we saw one ~3.8s lag at startup (likely tsx warm-up) and otherwise no events > 150ms during the hitches. jsr keeps flowing at 60Hz right through sonic's pauses.
- **Pi backpressuring the producer pipe**: Would manifest as `flush_frame_jsonl` spans firing on sonic. At threshold 20ms we see zero such spans on sonic during hitches.
- **Disk contention on `file_whole` upload**: Would symmetrically affect both producers. jsr is fine.
- **Kitty image-id range collisions across producers**: Recently fixed. Each `KatzenstegProducer` now allocates its own 10k-wide range. Issue persists after the fix.
- **Per-frame producer spans (`batch_present`, `upload_rgba_*`)**: With `KATZENSTEG_TRACE_BLOCKING_THRESHOLD_MS=20`, no significant spans appear during sonic hitches. Producer isn't blocked in any *instrumented* path — but it also isn't producing frames during the pause, so spans simply aren't firing.
- **Window-policy = mirror causing OS focus interaction**: theory only, not validated. Plausible but the user is unconvinced because (a) WM, which is the same `--embed-jsonl` consumer protocol, doesn't show this, and (b) it doesn't explain order-/producer-specificity (see below).

### The puzzle that breaks every simple theory

The user reports:

- `sonic` alone via pi-extension: fine, 60fps.
- `jsr` alone: fine.
- `jsr` then `sonic`: fine.
- `sonic` then `jsr`: sonic hitches with 1-second periodicity.
- `rrds` (OpenGL) then `sonic`: fine.
- `jsr` then `sonic` then `jsr`: sonic hitches; killing the second jsr stops sonic hitching.
- All of the above repeated under WM (same `--embed-jsonl` protocol, different consumer process): fine.

The order/producer specificity is the part no current theory accounts for cleanly. A generic mechanism (OS throttle, fairness bias, pipe contention) would not produce exactly this asymmetric matrix.

It is plausible that two different things are happening (e.g., the 1Hz cadence has one cause, the order-dependence has another). Treat that as a serious possibility.

## What to investigate

You are encouraged to use any approach you find useful. Some prompts:

1. **Compare what pi spawns vs what WM spawns**, all the way through to the target process. Same binary, same `--embed-jsonl`, same profile. What's different about the *environment* (env vars, fd inheritance, stdio configuration, parent-process state, NSApp/CFRunLoop attributes on macOS) of the target when spawned from pi vs from WM? Specifically: pi spawns `katzensteg` from `node`; WM is itself a native binary spawning `katzensteg` from a libxev event loop. The katzensteg launcher then `posix_spawn`s the actual target (e.g. retroarch).
2. **What is a 1-second period that sonic specifically would observe?** macOS' DispatchSource keep-alive on background windows is one. SDL/SDL2 vsync fallbacks under specific conditions are another. RetroArch's frame-throttle when audio sync fails. Look at sonic's process behaviour during a hitch — is it spinning, sleeping, blocked on a syscall, or genuinely descheduled?
3. **What does pi do that WM does not** at the consumer side, that could affect the producer's main thread *only*? Stdin write timing, control message volume, frame_batch read-rate, fd numbering, signal mask, etc.
4. **Is sonic's main thread actually paused, or is it producing frames that pi isn't reading?** With `flush_frame_jsonl` never firing, the producer isn't blocked on its stdout. So either sonic isn't reaching `flushFrame`, or it is and the writes complete instantly. We need to disambiguate. Adding a *count* (not a duration) of `renderBatchPresent` entries on the producer side would be a clean discriminator — log it periodically regardless of blocking trace threshold.
5. **macOS-specific tooling**: `dtrace`, `sample <pid>` while the pause is happening, `Activity Monitor`'s "Sample Process", or `lldb` attach + backtrace.

## What we'd like back

- A concrete cause, expressed in terms of which code path on which side is responsible and (if possible) why.
- A minimum-diff fix or workaround you'd propose.
- If you can't fully localize: the next two measurements you would take, and why those would discriminate the remaining hypotheses.

## Style guidance for your reply

- Skip the speculation pyramid. Ground claims in evidence (log excerpts, source-line citations, `sample` output).
- Don't restate what we already know; build on it.
- Be specific about file paths and line numbers when proposing changes.
