# RetroArch sdl2 audio driver under audio sync

Research for [rjwittams/katzensteg#147](https://github.com/rjwittams/katzensteg/issues/147), part of map flotilla-org/jackstay#97 (sound across Katzensteg, Jackstay and porthole). Decision already taken: `profiles/retroarch.json` forces `audio_driver = "sdl2"` so Katzensteg intercepts SDL audio, and when audio is not played locally Katzensteg presents a virtual SDL audio device paced by the monotonic clock at the nominal sample rate.

## Sources and versions

Three RetroArch trees matter, and they behave differently:

| Tree | Where | sdl2 audio file |
| --- | --- | --- |
| Our fork, `rjwittams/RetroArch` `macos-sdl2-window-contexts` @ `e10a5ce` (what `profiles/retroarch.json` runs, see `docs/external-projects.md:50`) | [fork] | `audio/drivers/sdl_audio.c` |
| Latest release `v1.22.2` (what Homebrew cask and distros ship) | [rel] | `audio/drivers/sdl_audio.c` |
| Upstream `master` @ `92173ac` (2026-10-10, unreleased) | [master] | `audio/drivers/sdl2_audio.c` (split into sdl1/sdl2/sdl3 files) |

[fork]: https://github.com/rjwittams/RetroArch/blob/e10a5ce5cb3521288a58798398d6df0ed784c70b
[rel]: https://github.com/libretro/RetroArch/blob/v1.22.2
[master]: https://github.com/libretro/RetroArch/blob/92173ac20116e2ce90d79243d85f062f1e67fa64

The fork's `sdl_audio.c` differs from v1.22.2 only by OOM null checks ([fork sdl_audio.c](https://github.com/rjwittams/RetroArch/blob/e10a5ce5cb3521288a58798398d6df0ed784c70b/audio/drivers/sdl_audio.c) vs [rel sdl_audio.c](https://github.com/libretro/RetroArch/blob/v1.22.2/audio/drivers/sdl_audio.c), diffed locally). Everything below about "release" applies to the fork. Note that the profiles pass `-c /tmp/retroarch-*.cfg`, which replaces the user config, so every setting not seeded is a compiled-in default (`profiles/retroarch.json:41-71`, `:128-188`).

## 1. Pacing: does audio_sync block on sdl2 like on native drivers?

Yes, it blocks, but the release driver has no dynamic rate control (DRC).

**Release / fork (`sdl_audio.c`)**

- Open: requests `AUDIO_F32SYS`, 2 channels, `spec.freq = audio_out_rate`, `spec.samples = next_pow2(rate * latency/4 / 1000)`, `allowed_changes = 0` so SDL converts and `obtained == desired` ([rel sdl_audio.c:36-41, 522-543](https://github.com/libretro/RetroArch/blob/v1.22.2/audio/drivers/sdl_audio.c#L522-L543)).
- FIFO in front of the device: `samples * 4 * bytes_per_sample` bytes, i.e. two device periods of stereo float, prefilled with silence ([rel sdl_audio.c:586-595](https://github.com/libretro/RetroArch/blob/v1.22.2/audio/drivers/sdl_audio.c#L586-L595)). The log line claims `samples*4` ms of latency but the FIFO really holds 2 periods; master's comment confirms "42.7 ms reported against a 64 ms setting" ([master sdl2_audio.c:745-752](https://github.com/libretro/RetroArch/blob/92173ac20116e2ce90d79243d85f062f1e67fa64/audio/drivers/sdl2_audio.c#L745-L752)).
- Callback (SDL's audio thread): reads up to `len` from the FIFO, `scond_signal`s, zero-fills on underrun ([rel sdl_audio.c:457-468](https://github.com/libretro/RetroArch/blob/v1.22.2/audio/drivers/sdl_audio.c#L457-L468)).
- Blocking write: loops `SDL_LockAudioDevice`, check `FIFO_WRITE_AVAIL`; if zero, unlock and `scond_wait` with no predicate and no timeout; else write what fits and unlock ([rel sdl_audio.c:604-658](https://github.com/libretro/RetroArch/blob/v1.22.2/audio/drivers/sdl_audio.c#L604-L658)). The signal is raised without the waiter's lock, so a wakeup can be lost and the writer then waits out one extra period; master documents and fixes exactly this ([master sdl2_audio.c:821-849](https://github.com/libretro/RetroArch/blob/92173ac20116e2ce90d79243d85f062f1e67fa64/audio/drivers/sdl2_audio.c#L821-L849)). If callbacks stop, the release writer blocks forever.
- `write_avail` is a stub returning 0 and `buffer_size` is absent (NULL) ([rel sdl_audio.c:721-750](https://github.com/libretro/RetroArch/blob/v1.22.2/audio/drivers/sdl_audio.c#L721-L750); [fork sdl_audio.c:772-800](https://github.com/rjwittams/RetroArch/blob/e10a5ce5cb3521288a58798398d6df0ed784c70b/audio/drivers/sdl_audio.c#L772-L800)).
- DRC is only enabled when the driver provides `buffer_size`; otherwise RetroArch logs `Rate control was desired, but driver does not support needed features.` ([rel audio_driver.c:817-836](https://github.com/libretro/RetroArch/blob/v1.22.2/audio/audio_driver.c#L817-L836)). So with sdl2 on release, `audio_rate_control` is silently off and the resampler ratio stays fixed at `out_rate / input_rate` ([rel audio_driver.c:784-785](https://github.com/libretro/RetroArch/blob/v1.22.2/audio/audio_driver.c#L784-L785)).

**Native drivers on the same release** (alsa, pulse, pipewire, coreaudio) all implement `write_avail` and `buffer_size` ([alsa.c:540-541](https://github.com/libretro/RetroArch/blob/v1.22.2/audio/drivers/alsa.c#L540-L541), [pulse.c:428-429](https://github.com/libretro/RetroArch/blob/v1.22.2/audio/drivers/pulse.c#L428-L429), [pipewire.c:888-889](https://github.com/libretro/RetroArch/blob/v1.22.2/audio/drivers/pipewire.c#L888-L889), [coreaudio.c:428-429](https://github.com/libretro/RetroArch/blob/v1.22.2/audio/drivers/coreaudio.c#L428-L429)), so they get DRC. They still block when full under `audio_sync`; the difference is that DRC nudges the ratio so the buffer floats near half and blocking becomes rare.

**DRC math** (when active): on every flush, `direction = (write_avail - buffer_size/2) / (buffer_size/2)`, `ratio = ratio_orig * (1 + audio_rate_control_delta * direction)` ([rel audio_driver.c:512-531](https://github.com/libretro/RetroArch/blob/v1.22.2/audio/audio_driver.c#L512-L531)). Default delta 0.005, i.e. at most +/-0.5% ([rel config.def.h:1214-1216](https://github.com/libretro/RetroArch/blob/v1.22.2/config.def.h#L1214-L1216)); default on for non-console builds ([config.def.h:1207-1212](https://github.com/libretro/RetroArch/blob/v1.22.2/config.def.h#L1207-L1212)). Libretro's description of the method: adjust resampling so the buffer is never under- or overrun, "thus avoiding blocking on audio", intended for when video vsync is the master clock ([libretro docs, dynamic-rate-control.md](https://raw.githubusercontent.com/libretro/docs/master/docs/development/cores/dynamic-rate-control.md)).

**Upstream master (`sdl2_audio.c`)** rewrites the driver: lock-free SPSC ring, eventcount park with a 256 ms stall timeout, FIFO sized to the full `audio_latency` (min two periods), device period `prev_pow2(rate * latency/4)` with a 64-frame floor, real `write_avail`/`buffer_size`, plus `wait_writable`, `frames_consumed` (counts callback bytes, silence included, as device time) and `underruns` ([master sdl2_audio.c:40, 53-60, 609-624, 745-791, 793-862, 932-1047](https://github.com/libretro/RetroArch/blob/92173ac20116e2ce90d79243d85f062f1e67fa64/audio/drivers/sdl2_audio.c#L932-L1047)). DRC therefore works with sdl2 on master ([master audio_driver.c:4805-4818](https://github.com/libretro/RetroArch/blob/92173ac20116e2ce90d79243d85f062f1e67fa64/audio/audio_driver.c#L4805-L4818)), with delta scaled down when `ratio > 1` and a slow "sink rate estimate" bias that compares `frames_consumed` with the host clock ([master audio_driver.c:1351-1426, 1428-1440](https://github.com/libretro/RetroArch/blob/92173ac20116e2ce90d79243d85f062f1e67fa64/audio/audio_driver.c#L1351-L1440)). Master also defaults to a threaded audio pipeline when the driver has `wait_writable` ([master config.def.h:1427](https://github.com/libretro/RetroArch/blob/92173ac20116e2ce90d79243d85f062f1e67fa64/config.def.h#L1427), [master audio_driver.c:4377-4400](https://github.com/libretro/RetroArch/blob/92173ac20116e2ce90d79243d85f062f1e67fa64/audio/audio_driver.c#L4377-L4400)) and may open S16 per `audio_format_negotiation` and multichannel layouts ([master sdl2_audio.c:671-686](https://github.com/libretro/RetroArch/blob/92173ac20116e2ce90d79243d85f062f1e67fa64/audio/drivers/sdl2_audio.c#L671-L686)). If the fork rebases onto a release containing this, the virtual device sees different formats, period sizes and lock behaviour.

**Write granularity.** Cores use the batch callback; RetroArch flushes each batch in pieces of at most 1024 frames ([rel audio_driver.c:900-935](https://github.com/libretro/RetroArch/blob/v1.22.2/audio/audio_driver.c#L900-L935)). Genesis Plus GX pushes one batch per frame at 44100 Hz ([GPGX libretro.c:204, 3167-3168](https://github.com/libretro/Genesis-Plus-GX/blob/393f70cd64c7334564c19a424c383f53986c13f4/libretro/libretro.c#L3167-L3168)), roughly 736 core frames, about 800 output frames at 48 kHz.

## 2. Interaction with video sync

**Input rate skew.** Unless `vrr_runloop_enable` ("Sync to Exact Content Framerate") is on, RetroArch rescales the core's audio rate to `sample_rate * refresh / core_fps` when `|1 - core_fps/refresh| <= audio_max_timing_skew` (default 0.05) ([rel retroarch.c:1308-1336, 1394-1411](https://github.com/libretro/RetroArch/blob/v1.22.2/retroarch.c#L1308-L1411); [config.def.h:1218-1220](https://github.com/libretro/RetroArch/blob/v1.22.2/config.def.h#L1218-L1220)). `video_refresh_rate` defaults to 60 on desktop ([config.def.h:1050](https://github.com/libretro/RetroArch/blob/v1.22.2/config.def.h#L1050)). Consequence with a device draining exactly 48000 frames/s and no DRC: the emulator runs at exactly `refresh` (60 fps), not the core's fps. GPGX NTSC is about 59.92 fps ([GPGX libretro.c:3167](https://github.com/libretro/Genesis-Plus-GX/blob/393f70cd64c7334564c19a424c383f53986c13f4/libretro/libretro.c#L3167)), Flycast NTSC 59.9453 ([Flycast libretro.cpp:744-753](https://github.com/flyinghead/flycast/blob/ed953fcbfdd1b8a7521d2966b13cc700c7e2d233/shell/libretro/libretro.cpp#L744-L753)), so they run 0.13% / 0.09% fast. Inaudible and invisible, but it means "nominal" is the configured refresh, not the core.

**With `vrr_runloop_enable = true`** the audio input rate is the core's own rate, and the runloop adds a sleep-based frame limiter at core fps on top of audio blocking ([rel retroarch.c:1396-1398](https://github.com/libretro/RetroArch/blob/v1.22.2/retroarch.c#L1396-L1398), [rel runloop.c:7438-7510](https://github.com/libretro/RetroArch/blob/v1.22.2/runloop.c#L7438-L7510)). Two clocks: the limiter (monotonic, `cpu_features_get_time_usec`) and the audio device. With a virtual device paced on the same monotonic clock at nominal rate they agree. With a real device and no DRC (release sdl2) they diverge by the device's ppm error: if the device is fast, the FIFO slowly empties and underruns periodically.

**vsync.** The sdl2 video driver requests `SDL_RENDERER_PRESENTVSYNC` when `video_vsync` (default true) ([rel sdl2_gfx.c:191-196](https://github.com/libretro/RetroArch/blob/v1.22.2/gfx/drivers/sdl2_gfx.c#L191-L196); [config.def.h:371](https://github.com/libretro/RetroArch/blob/v1.22.2/config.def.h#L371)). Which clock dominates is simply whichever call blocks longer:

- Katzensteg present non-blocking (current assumption): audio blocking is the only pacer. Emulation is gated by callback arrivals.
- Katzensteg present blocking (backpressure from the terminal or a real vsync): with release sdl2 there is no DRC to reconcile the two clocks, so the slower one wins and the other side under- or overruns. Native drivers would hide this with DRC within +/-0.5%.

**video_frame_delay** (default 0, [config.def.h:406](https://github.com/libretro/RetroArch/blob/v1.22.2/config.def.h#L406)) inserts a sleep after each frame to move input polling closer to the next vblank ([rel runloop.c:7516-7519](https://github.com/libretro/RetroArch/blob/v1.22.2/runloop.c#L7516-L7519), [gfx/video_driver.c:4647](https://github.com/libretro/RetroArch/blob/v1.22.2/gfx/video_driver.c#L4647)). Without a blocking present it only eats into the FIFO headroom. Leave at 0.

**Runahead** runs the core N+1 times per frame with audio suspended for all but the last run ([rel runahead.c:1188-1211](https://github.com/libretro/RetroArch/blob/v1.22.2/runahead.c#L1188-L1211)), so audio volume per displayed frame is unchanged; it only costs CPU, which shrinks the margin to refill after a late callback.

**Burst pacing.** Because the FIFO is kept full and each callback frees one whole period, emulated frames are released in lumps aligned to callbacks. At defaults (48 kHz, 64 ms latency) the release period is `next_pow2(768) = 1024` frames = 21.3 ms, holding about 1.28 emulated frames, so the emulator alternates between producing 1 and 2 frames per callback. With non-blocking presentation those lumps become visible frame-time jitter. A smaller period (lower `audio_latency`) directly smooths this.

## 3. Buffering and latency

| Setting | Default | Effect with release sdl2 |
| --- | --- | --- |
| `audio_out_rate` | 48000 ([config.def.h:1186](https://github.com/libretro/RetroArch/blob/v1.22.2/config.def.h#L1186)) | `spec.freq`; obtained rate written back ([rel audio_driver.c:745-747](https://github.com/libretro/RetroArch/blob/v1.22.2/audio/audio_driver.c#L745-L747)) |
| `audio_latency` | 64 ms ([config.def.h:1200](https://github.com/libretro/RetroArch/blob/v1.22.2/config.def.h#L1200)); core may raise it ([rel audio_driver.c:653-656](https://github.com/libretro/RetroArch/blob/v1.22.2/audio/audio_driver.c#L653-L656)) | period = next_pow2(rate*latency/4000); FIFO = 2 periods |
| `audio_resampler` | `sinc` on desktop ([rel configuration.c:589-593](https://github.com/libretro/RetroArch/blob/v1.22.2/configuration.c#L589-L593)), quality normal ([config.def.h:1714-1720](https://github.com/libretro/RetroArch/blob/v1.22.2/config.def.h#L1714-L1720)) | always runs: 44100 (skewed) to 48000 |
| `audio_sync` | true ([config.def.h:1205](https://github.com/libretro/RetroArch/blob/v1.22.2/config.def.h#L1205)) | false sets nonblock + 2048-sample chunks ([rel audio_driver.c:760-770](https://github.com/libretro/RetroArch/blob/v1.22.2/audio/audio_driver.c#L760-L770)), leaving no pacer if present does not block |

Worked numbers at 48 kHz (release): latency 64 gives 1024-frame period (21.3 ms) and 42.7 ms FIFO; latency 32 gives 512 (10.7 ms) and 21.3 ms; latency 16 gives 256 (5.3 ms) and 10.7 ms, which is smaller than one GPGX frame's write (about 800 frames), still correct because the write loops, but leaves almost no jitter margin. On master the FIFO is the whole setting and the period is a quarter rounded down.

`SET_SYSTEM_AV_INFO` from a core reinitialises the audio driver (video too unless timings allow skipping it) ([rel runloop.c:2637-2697](https://github.com/libretro/RetroArch/blob/v1.22.2/runloop.c#L2637-L2697)). Flycast calls it at runtime when its SPG timing or framebuffer size changes ([Flycast libretro.cpp:763-800](https://github.com/flyinghead/flycast/blob/ed953fcbfdd1b8a7521d2966b13cc700c7e2d233/shell/libretro/libretro.cpp#L763-L800)), so the virtual device will see `SDL_CloseAudioDevice` + `SDL_QuitSubSystem(SDL_INIT_AUDIO)` then a fresh init/open mid-game ([rel sdl_audio.c:691-713](https://github.com/libretro/RetroArch/blob/v1.22.2/audio/drivers/sdl_audio.c#L691-L713), [:506-516](https://github.com/libretro/RetroArch/blob/v1.22.2/audio/drivers/sdl_audio.c#L506-L516)).

## 4. Requirements for a clock-paced virtual SDL device

Derived from the release driver's contract (what our fork runs today):

1. **Callback on its own thread, always.** RetroArch's writer blocks on a condvar until the callback runs. Calling the callback from an app-thread SDL entry point (PollEvent, etc.) deadlocks once the FIFO fills.
2. **Never stop calling back while unpaused.** Release has no timeout: no callbacks means the emulator hangs. Keep the clock running when no sink (Jackstay, local device) is attached; discard the samples. Honour `SDL_PauseAudioDevice` (RetroArch pauses for menu/stop, [rel sdl_audio.c:660-682](https://github.com/libretro/RetroArch/blob/v1.22.2/audio/drivers/sdl_audio.c#L660-L682)).
3. **Real `SDL_LockAudioDevice` semantics.** The release writer mutates the non-thread-safe `fifo_buffer_t` under `SDL_LockAudioDevice`, relying on SDL holding the same lock around the callback. Master no longer relies on it.
4. **Honour `obtained == desired`.** `allowed_changes = 0`: grant F32 stereo at the requested freq and the requested `samples`, and fill `size`, `silence`. RetroArch takes `obtained.freq` as the output rate.
5. **Absolute-deadline scheduling.** Schedule callback k at `t0 + k * samples / freq` on the monotonic clock, not `last + period`, so the long-run drain rate is exactly nominal. That is what makes the emulator run at exactly `refresh` fps (or core fps with `vrr_runloop_enable`) and keeps master's sink estimate near 0 ppm.
6. **Jitter tolerance is about one period.** A late callback just blocks the emulator longer; it catches up because it runs faster than real time. Underrun (zero fill) only happens if the emulator cannot refill within the remaining FIFO, about 1 period with the release 2-period FIFO.
7. **Too fast / too slow drain.** Release sdl2 has no DRC, so emulation speed tracks the drain rate one to one: 0.5% fast drain means 0.5% fast game. Master's DRC would absorb up to +/-0.5% (`audio_rate_control_delta`), beyond that the buffer pins and blocking or underruns return. `audio_max_timing_skew` (5%) is unrelated to the device: it bounds the static refresh-vs-core rescale.
8. **Catch-up policy after a stall.** Firing several overdue callbacks back to back drains the FIFO and makes the emulator burst several frames; rebasing `t0` drops wall time instead. This choice is open (see below).
9. **Survive reopen.** Close, `SDL_QuitSubSystem(AUDIO)`, `SDL_InitSubSystem(AUDIO)`, open again, possibly every few seconds with Flycast.
10. **Device enumeration.** Release calls `SDL_GetNumAudioDevices` / `SDL_GetAudioDeviceName` for the menu list but always opens the default (NULL) device ([rel sdl_audio.c:470-493, 543](https://github.com/libretro/RetroArch/blob/v1.22.2/audio/drivers/sdl_audio.c#L470-L493)).

## 5. Recommended `profiles/retroarch.json` seed additions

Add to both `config.retroarch_sdl2` and `config.retroarch_vulkan` seed content:

```
audio_driver = "sdl2"
audio_sync = "true"
audio_out_rate = "48000"
audio_latency = "32"
vrr_runloop_enable = "false"
video_frame_delay = "0"
run_ahead_enabled = "false"
```

Rationale:

- `audio_sync = true` is the default but must stay on: with non-blocking presentation it is the only pacer.
- `audio_out_rate = 48000` pins the virtual device's nominal rate explicitly (also the likely Jackstay/porthole wire rate; to confirm in #149).
- `audio_latency = 32` halves the callback period to 10.7 ms (release) to reduce lumpy frame release, while keeping a 21.3 ms FIFO. Tune against measured callback jitter.
- `vrr_runloop_enable = false` keeps a single pacer (audio). The cost is running at `video_refresh_rate` (60) instead of the core's 59.92/59.945; set `video_refresh_rate` to the core fps per game profile if exactness matters. Turn it on only if Katzensteg's virtual clock is the sole sink, where both clocks agree.
- Leave `audio_rate_control` at default (true): inert on the fork/release sdl2 driver, useful if the fork moves to a release with the master driver.
- Consider `video_vsync = "false"` only after deciding whether Katzensteg present ever blocks; with a non-blocking present it changes nothing, with a blocking one it removes a second unreconciled clock. For `jsr`/`spyro` (Vulkan via `sdl_vk`) this also changes the swapchain present mode, so test with the capture layer before seeding.

## 6. Availability and platform caveats

- Linux autotools: `HAVE_SDL2=auto`, and the sdl audio driver is compiled whenever SDL2 (or SDL1) is ([rel qb/config.params.sh:50](https://github.com/libretro/RetroArch/blob/v1.22.2/qb/config.params.sh#L50), [qb/config.libs.sh:275](https://github.com/libretro/RetroArch/blob/v1.22.2/qb/config.libs.sh#L275), [Makefile.common:1629-1661](https://github.com/libretro/RetroArch/blob/v1.22.2/Makefile.common#L1629-L1661)). Any build that already serves our `video_driver = "sdl2"` profiles has the sdl2 audio driver. Distro build flags were not verified (Arch, Debian, Fedora packaging hosts refused fetches).
- macOS official build: the Xcode project only defines `HAVE_COREAUDIO`/`HAVE_COREAUDIO3`, no `HAVE_SDL2` ([rel pkg/apple/BaseConfig.xcconfig:27, 105](https://github.com/libretro/RetroArch/blob/v1.22.2/pkg/apple/BaseConfig.xcconfig#L27)); `griffin.c` includes `sdl_audio.c` only under `HAVE_SDL2` ([rel griffin/griffin.c:897-898](https://github.com/libretro/RetroArch/blob/v1.22.2/griffin/griffin.c#L897-L898)). The Homebrew cask installs that buildbot DMG ([homebrew-cask retroarch.rb](https://github.com/Homebrew/homebrew-cask/blob/master/Casks/r/retroarch.rb)). So stock macOS RetroArch has no sdl2 audio (nor sdl2 video); our fork built with SDL2 is required, as it already is for video.
- sdl2-compat: Homebrew's `sdl2` is an alias of `sdl2-compat` ([homebrew-core Aliases/sdl2](https://github.com/Homebrew/homebrew-core/blob/main/Aliases/sdl2)). Under sdl2-compat, an SDL2 callback device is bridged from an SDL3 stream callback that calls the SDL2 callback repeatedly in `spec.size` chunks until SDL3's requested amount is met ([sdl2-compat release-2.32.74 sdl2_compat.c:7855-7880](https://github.com/libsdl-org/sdl2-compat/blob/release-2.32.74/src/sdl2_compat.c#L7855-L7880)), so local playback cadence follows SDL3's device period with bursts. This matters only if Katzensteg forwards to the real SDL for local playback; the virtual device replaces this path entirely, but Katzensteg's interposer must sit in front of sdl2-compat (dynapi or preload) for `SDL_OpenAudioDevice`, `SDL_LockAudioDevice`, `SDL_PauseAudioDevice`, `SDL_CloseAudioDevice`, the enumeration calls and `SDL_Init/QuitSubSystem(SDL_INIT_AUDIO)`.
- The release mic path on Apple requires the sdl2 audio driver to be selected ([master sdl2_audio.c:220-229](https://github.com/libretro/RetroArch/blob/92173ac20116e2ce90d79243d85f062f1e67fa64/audio/drivers/sdl2_audio.c#L220-L229)); irrelevant unless capture is in scope.

## Open questions for #149 "Virtual paced audio device"

1. Catch-up policy after a scheduling stall: fire overdue callbacks back to back (exact long-run time, frame burst) or rebase the deadline (drop time, smooth video)? Threshold?
2. Callback granularity: honour SDL2's one-`spec.size`-per-callback contract, or deliver smaller `len` more often to smooth frame release? RetroArch's callback accepts any `len`, other SDL apps may not.
3. Which period and FIFO to target: accept RetroArch's requested `samples`, or ship `audio_latency = 32` (or 16) and measure jitter on Linux and macOS?
4. Single pacer or two: keep `vrr_runloop_enable = false` (run at `video_refresh_rate`), or set per-game `video_refresh_rate` to core fps? Does Katzensteg ever block in present, and if so, which clock wins?
5. When local playback is also wanted, who reconciles virtual clock vs real device ppm drift: Katzensteg (resample to the device), RetroArch (needs DRC, i.e. master driver), or Jackstay?
6. Behaviour while no sink is attached and while RetroArch pauses the device: keep ticking and discard, or pause the clock (and how that interacts with RetroArch's unbounded release-era wait)?
7. Reopen handling for Flycast `SET_SYSTEM_AV_INFO`: keep one continuous clock across close/open so the published stream has no gap, or restart?
8. Should the fork track upstream master's sdl2 driver (DRC, stall timeout, frames_consumed, S16/multichannel) before or after the virtual device lands? If so the device must also support S16 and >2 channels.
9. `SDL_LockAudioDevice` implementation: real per-device mutex held around each callback, as the release driver needs; any interaction with Katzensteg's own locks?
10. Nominal rate on the wire to Jackstay/porthole: 48000 fixed, or whatever RetroArch opens?
