# SDL Audio Interception Probes

Experiments for rjwittams/katzensteg#154, following the interception set in
`docs/research/sdl-audio-interception.md` (branch
`research/sdl-audio-interception`, #146) and feeding the open questions in
#148. Everything here is standalone C under
`docs/research/sdl-audio-probes/`; nothing in `src/`, `build.zig` or
`profiles/` changed, and Katzensteg's own libraries were not used (no Zig
toolchain on the test host).

## Answer for #148: intercept at the SDL2 layer everywhere?

**Yes, for SDL2 applications, on both classic SDL2 and sdl2-compat.** The SDL2
trampoline and owned queue saw every sample the device played in every
SDL2 run: the tap was byte-identical to the disk driver's output in all seven
gain-1 SDL2 runs (classic and sdl2-compat; callback, queue and `SDL_OpenAudio`).
Gain 0 silenced the device output but not the tap, callback cadence matched
the device period, and the hooks re-attached across close and reopen. An
`LD_PRELOAD` SDL3 interposer never saw sdl2-compat's internal SDL3 calls
(sdl2-compat `dlopen`s SDL3 `RTLD_LOCAL` and resolves through `dlsym` on that
handle), so the SDL2 layer is the only preload layer that sees SDL2 audio and
there is no double tap.

Two conditions make it safe, and both were broken on purpose here:

1. **Do not also activate the SDL3 layer through `SDL3_DYNAMIC_API` in an
   sdl2-compat process.** SDL3's jump table does route sdl2-compat's internal
   calls, so the SDL3 hooks then see the same audio a second time: with
   `KATZ_GAIN=0.5` in both layers the device output was 0.25x and there were
   two taps of the same signal.
2. **Do not put an SDL2 interposer and an SDL3 interposer with plain
   unversioned exports in one process.** `SDL_OpenAudioDevice`,
   `SDL_CloseAudioDevice` and others have the same name and different ABIs in
   SDL2 and SDL3, and every such combination crashed (table below).
   Katzensteg's `katzensteg_sdl3_linux.map` exports unversioned `SDL_*` by
   design, so the same hazard applies to `libkatzensteg-sdl2` +
   `libkatzensteg-sdl3`. Symbol versioning fixes it (shown below).

The SDL2 layer missed no audio in any tested case. Cases that were not tested
and could miss it: an app that `dlopen`s libSDL2 and calls `dlsym(handle, ...)`
(bypasses `LD_PRELOAD`, not `SDL_DYNAMIC_API`), and real backends other than
the disk driver.

## Versions

| Component | Version | Commit |
| --- | --- | --- |
| SDL2 | `release-2.32.10` | `5d249570393f7a37e037abf22cd6012a4cc56a71` |
| SDL3 | `release-3.4.16` | `fa2c02bb6e21974a89ea9824bc53c9932abe5f9c` |
| sdl2-compat | `release-2.32.74` (reports 2.32.74) | `e4df8a55f20da762290a78c2bbe8f8d89d01486a` |
| Host | Ubuntu 24.04, glibc 2.39, gcc 13.3.0, cmake 3.28.3, numpy 2.5.3 | |

All three were built from source as shared libraries into separate prefixes,
audio only (video, joystick, HIDAPI off). sdl2-compat was built against the
SDL3 prefix, and its `libSDL2-2.0.so.0` was selected with `LD_LIBRARY_PATH`.

## What was built

| File | Purpose |
| --- | --- |
| `probe_sdl2.c` | SDL2 probe: `callback` (`SDL_OpenAudioDevice` with callback), `queue` (NULL callback, `SDL_QueueAudio` paced on `SDL_GetQueuedAudioSize`), `legacy` (`SDL_OpenAudio`), `--f32`, `--reopen` |
| `probe_sdl3.c` | SDL3 probe: `bound` (open + create + bind + put), `devstream` (`SDL_OpenAudioDeviceStream`, put), `devstream-cb` (get callback), `--s16`, `--reopen`, `--app-postmix` |
| `tone.h` | 440 Hz sine, amplitude 0.5 of full scale, 48 kHz stereo, continuous phase |
| `katz_common.h` | Per-device records, preallocated tap buffer, callback timestamps, file log, in-place gain for U8/S8/U16/S16/S32/F32 |
| `katz_sdl2.c` | SDL2 interposer: `SDL_OpenAudioDevice`, `SDL_OpenAudio` (trampoline, or owned queue plus drain callback for NULL callbacks), `SDL_QueueAudio`, `SDL_GetQueuedAudioSize`, `SDL_ClearQueuedAudio`, `SDL_CloseAudioDevice`, `SDL_CloseAudio`; pause calls logged |
| `katz_sdl3.c` | SDL3 interposer: `SDL_OpenAudioDevice`, `SDL_OpenAudioDeviceStream` (install postmix), `SDL_SetAudioPostmixCallback` (chain the app's), `SDL_CloseAudioDevice`, `SDL_DestroyAudioStream`, `SDL_Quit`; optional log-only wrappers for the SDL3 calls sdl2-compat makes. Built three ways: plain preload, `SDL3_DYNAMIC_API` library, and a preload whose exports are versioned |
| `katz_sdl3_symver.map`, `katz_sdl2_ver.map` | Version scripts for the coexistence experiment |
| `probes.sh` | `fetch`, `deps`, `build`, `run` |
| `analyze.py` | RMS, dominant frequency, glitch and dropout counts, byte-exact tap versus disk comparison, cadence statistics |
| `results.md` | Full analyser output of the run reported here (200 rows) |

The tap order is: app callback (or app postmix) runs, the buffer is copied to
the tap, then gain is applied in place. The audio thread only copies into
preallocated buffers and records timestamps; files are written after the real
close returns or at exit.

All runs use the disk driver (`SDL_AUDIODRIVER=disk` + `SDL_DISKAUDIOFILE` for
SDL2; `SDL_AUDIO_DRIVER=disk` + `SDL_AUDIO_DISK_OUTPUT_FILE` for SDL3;
sdl2-compat maps both SDL2 names). Each run is 2 s.

## Results per probe model

Expected tone RMS is 0.3536. "Exact" means the tap bytes appear unchanged and
contiguous in the disk output of the gain-1 run (offset = bytes the disk
driver wrote before the first callback). Glitches (second-difference jumps)
and dropouts (interior zero runs) were 0 in every tap and every non-silent
disk file.

| Model | Runtime and hook | Tap (gain 1) | Gain 0: disk / tap | Cadence: calls x bytes, median gap vs period, data/wall |
| --- | --- | --- | --- | --- |
| SDL2 callback | SDL2, preload | 0.3536 rms, 440.0 Hz, exact at +4096 | silent / tone | 93 x 4096 B, 21.29 vs 21.33 ms, 1.000 |
| SDL2 callback | sdl2-compat, preload | 0.3536, 439.8-440.0 Hz, exact at 0 | silent / tone | 93-94 x 4096 B, 21.30 vs 21.33 ms, 0.991-0.995 |
| SDL2 queue S16 | SDL2, owned queue | 0.3535, 440.0 Hz, exact at +4096 | silent / tone | 96 x 4096 B, 21.27-21.29 ms, 1.000 |
| SDL2 queue F32 | SDL2, owned queue | 0.3536, 440.0 Hz, exact at +8192 | silent / tone | 96 x 8192 B, 21.36 ms, 0.98-1.00 |
| SDL2 queue S16 | sdl2-compat, owned queue | 0.3535, 440.0 Hz, exact at 0 | silent / tone | 96 x 4096 B, 21.29 ms, 0.994-1.001 |
| SDL2 `SDL_OpenAudio` | SDL2, preload | 0.3536, 440.0 Hz, exact at +4096 | silent / tone | 93 x 4096 B, 21.28-21.30 ms, 1.001 |
| SDL2 `SDL_OpenAudio` | sdl2-compat, preload | 0.3536, 439.8-440.0 Hz, exact at 0 | silent / tone | 93-94 x 4096 B, 21.32-21.33 ms, 0.99-1.00 |
| SDL3 bound F32 | SDL3, preload and dynapi | 0.3536, 440.0 Hz, exact at 0 | silent / tone | 96-97 x 8192 B, 21.27-21.32 ms, 0.995-1.001 |
| SDL3 bound, S16 app | SDL3, preload | postmix F32 0.3535, 440.0 Hz | silent / tone | 97 x 8192 B, 21.29 ms, 0.997 |
| SDL3 device stream | SDL3, preload and dynapi | 0.3536, 440.0 Hz, exact at 0 | silent / tone | 96 x 8192 B, 21.27-21.30 ms, 0.994-1.003 |
| SDL3 device stream + get callback | SDL3, preload and dynapi | 0.3536, 439.8 Hz, exact at +8192 | silent / tone | 93-94 x 8192 B, 21.33 ms, 0.996-0.999 |
| SDL3 app postmix chained | SDL3 bound (preload), device stream (dynapi) | tone | silent / tone; app postmix ran 96 and 97 times on the device thread | as above |

Close and reopen (`--reopen`, gain 0; second open uses half the buffer, as
Flycast does on timing changes): every model on every runtime produced two
records, both taps were clean tone (0.3535-0.3536 rms, 0 glitches) and both
disk segments were silent. Buffers went from 4096 to 2048 B (SDL2 S16) and
from 8192 to 4096 B (SDL3 postmix) as requested. Hook logs show one open and
one close (or destroy) per segment.

Lifetime: the plain `SDL_OpenAudioDevice` wrapper was never called for
`SDL_OpenAudioDeviceStream` (its internal open is invisible to both preload and
dynapi), and `SDL_DestroyAudioStream` on a device stream released the record
without any `SDL_CloseAudioDevice` call, as the research note predicted. No
record was left for the `SDL_Quit` or exit fallback in any run.

## sdl2-compat double interception

SDL2 probe on sdl2-compat, `KATZ_GAIN=0.5` in every interposer, so device
output at 0.5x means one layer scaled and 0.25x means two. `k2` is
`katz_sdl2.so` (unversioned exports), `k2v` the same with a private default
version, `k3` the plain SDL3 preload, `k3v` the SDL3 preload exported only as
hidden `SDL_x@SDL3_0.0.0`, `dyn3` the `SDL3_DYNAMIC_API` library. Callback and
queue modes gave the same outcome in every row.

| Injection | Exit | SDL2 hook | SDL3 hook saw compat's SDL3 calls | Disk output |
| --- | --- | --- | --- | --- |
| `LD_PRELOAD=k3` | SIGSEGV | none | n/a | none |
| `LD_PRELOAD=k2:k3` | SIGSEGV | open logged, then crash | n/a | none |
| `LD_PRELOAD=k3:k2` | SIGSEGV | none | n/a | none |
| `LD_PRELOAD=k3v` | 0 | none | **no** (not even the log-only `SDL_CreateAudioStream`, `SDL_BindAudioStream`, `SDL_SetAudioStreamGetCallback`, `SDL_PutAudioStreamData` wrappers) | 1.000x |
| `LD_PRELOAD=k2:k3v`, `k3v:k2`, `k2v:k3v` | 0 | yes | no | 0.500x |
| `SDL3_DYNAMIC_API=dyn3` | 0 | none | **yes**: `SDL_OpenAudioDevice` (S16 spec, logical 21), `SDL_CloseAudioDevice`, `SDL_DestroyAudioStream`, `SDL_Quit`; postmix installed and tapped | 0.500x |
| `LD_PRELOAD=k2` + `SDL3_DYNAMIC_API=dyn3` | 0 | yes | yes | **0.250x** (two taps, gain applied twice) |

The crashes are ABI collisions, confirmed with gdb. With `k3` first, the SDL2
app's `SDL_OpenAudioDevice(NULL, 0, &want, &have, 0)` bound to the SDL3
wrapper, which forwarded `(devid=0, spec=NULL)` to sdl2-compat and crashed in
`PrepareAudiospec`. With `k2` first, `k2`'s `dlsym(RTLD_NEXT,
"SDL_OpenAudioDevice")` found `k3`'s wrapper, not libSDL2.

Both interposers in other processes:

| Process | Injection | Exit | Result |
| --- | --- | --- | --- |
| native SDL3 bound | `k2:k3v` | SIGSEGV | the SDL3 app's reference to `SDL_OpenAudioDevice@SDL3_0.0.0` bound to `k2`'s unversioned SDL2 wrapper (gdb: `katz_sdl2.c` called with `device=0xffffffff`) |
| native SDL3 bound | `k3v:k2` | 0 | SDL3 postmix installed, 0.500x |
| native SDL3 bound | `k2v:k3v` | 0 | SDL3 postmix installed, 0.500x |
| native SDL3 device stream | `k3v:k2v` | 0 | 0.500x |
| classic SDL2 callback | `k2v:k3v` | 0 | SDL2 trampoline, 0.500x |
| sdl2-compat callback | `k2v:k3v` | 0 | SDL2 trampoline only, 0.500x |

So one process can carry both an SDL2 and an SDL3 interposer, in any order,
when (a) the SDL3 wrappers are exported only as the hidden, non-default
version `SDL3_0.0.0` at version index 3 or higher (glibc 2.39 lets an
unversioned reference bind to a hidden definition at index 2, which the first
attempt hit, hence the `KATZ_PAD_0` node), with real functions from
`dlvsym(RTLD_NEXT, name, "SDL3_0.0.0")`, and (b) the SDL2 wrappers carry a
named default version of their own, so versioned SDL3 references skip them.
An SDL3 app that resolves SDL without symbol versions (for example
`dlopen` + `dlsym`) was not tested against `k3v`.

## Surprises and notes

- **sdl2-compat starts the callback almost at once.** The first SDL2 callback
  ran 0.3 ms after unpause on sdl2-compat versus 21.3 ms on classic SDL2,
  which first sleeps one device period. On
  sdl2-compat the SDL2 callback runs on SDL3's device thread (one thread per
  device, no thread changes in any run). sdl2-compat sets
  `SDL_HINT_AUDIO_DEVICE_SAMPLE_FRAMES` to the app's `samples`, so every SDL3
  request matched one SDL2 buffer and no back-to-back callback bursts were
  seen. The bridge loop (`SDL2AudioDeviceCallbackBridge`) can still burst when
  SDL3 asks for more than one buffer, for example after resampling; not
  observed here.
- **sdl2-compat opened the SDL3 device in the app format.** An S16 SDL2 app
  got an S16 SDL3 device; the SDL2 tap was byte-identical to the disk file
  with no leading silence. The SDL3 postmix on the same device saw F32 at
  8192 B per 1024 frames, as documented.
- **The tap has no timeline for pauses.** Classic SDL2 (all three models) and
  the SDL3 device stream with a get callback wrote one buffer of silence to the device before the first
  callback (the exact-match offsets of 4096 and 8192 B), and that buffer never
  reaches the tap, because SDL2 skips the callback while paused and SDL3 skips
  postmix for paused logical devices. A publisher that needs A/V sync must
  timestamp buffers, not count them.
- **Disk and dummy drivers sleep truncated milliseconds.** With 512-frame
  buffers (10.67 ms) the measured median gaps were 10.23-10.34 ms and data/wall
  1.007-1.040, so the device ran up to 4% fast. With 1024 frames (21.33 ms) it
  stayed within 2% (0.98-1.00), because the sleep of 21 ms plus the write
  and callback work came close to the period.
- **App postmix chaining works by re-registering.** The wrapper clears the
  slot, stores the app's callback and installs its own again; SDL blocks until
  the device is between iterations. The app postmix ran on the device thread
  on every iteration, and the gain-0 output stayed silent.
- **`dlvsym(RTLD_NEXT, ..., "SDL3_0.0.0")` skipped `k2`'s unversioned
  definition** (`k3v:k2` worked) even though a normal versioned reference from
  the SDL3 app did bind to it (`k2:k3v` crashed). Observed on glibc 2.39 only.
- **`allowed_changes` was not exercised.** The disk driver accepts any spec,
  so the obtained spec equalled the desired one in every run. sdl2-compat
  forces `allowed_changes = 0` in source (`OpenAudioDeviceLocked`). The
  `SDL_OpenAudio(desired, NULL)` path, where the wrapper must copy `size` and
  `silence` back into the app's `desired`, is handled in `katz_sdl2.c` but was
  not exercised by a probe.
- **Locking.** The owned SDL2 queue here uses a mutex shared by the app thread
  and the drain callback. That was fine for a probe, but the real
  implementation should use the lock-free ring the research note asks for.
  App `SDL_LockAudioDevice` calls were not wrapped and were not needed.

## Not run

Real backends (PulseAudio, PipeWire, ALSA), capture devices, multiple
simultaneous devices, sdl2-compat's own `SDL_DYNAMIC_API`, macOS
(`DYLD_INSERT_LIBRARIES`, two-level namespace), apps that `dlopen` SDL,
Katzensteg's real `libkatzensteg-sdl2` and `libkatzensteg-sdl3` (no Zig on
the host), and real applications such as RetroArch or Flycast.

## Reproduce

```bash
cd docs/research/sdl-audio-probes
export WORK=$HOME/sdl-audio-probes   # scratch area for sources, builds and runs
./probes.sh fetch    # clones the three tags (depth 1)
./probes.sh deps     # builds SDL2, SDL3, sdl2-compat into $WORK/prefix
./probes.sh build    # probes and interposers into $WORK/out
./probes.sh run      # all runs into $WORK/runs, prints the results table
```

Each run directory holds `cmd`, `probe.out`, `katz.log` (every intercepted
call with thread id and milliseconds since load), `tap.<layer><seq>.raw`,
`.meta`, `.cadence` and the disk output. A single run by hand, for example
the double-interception case:

```bash
LD_LIBRARY_PATH=$WORK/prefix/compat/lib:$WORK/prefix/sdl3/lib \
SDL_AUDIODRIVER=disk SDL_DISKAUDIOFILE=/tmp/disk.raw \
KATZ_LOG=/tmp/katz.log KATZ_TAP_FILE=/tmp/tap KATZ_GAIN=0.5 \
LD_PRELOAD=$WORK/out/katz_sdl2.so SDL3_DYNAMIC_API=$WORK/out/katz_sdl3_dynapi.so \
$WORK/out/probe_sdl2 callback
```
