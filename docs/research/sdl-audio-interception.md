# SDL Audio Interception Points

Research for rjwittams/katzensteg#146, part of flotilla-org/jackstay#97 ("Sound
across Katzensteg, Jackstay and porthole"). The question: which SDL audio
functions Katzensteg must intercept, per SDL major version and per injection
mechanism, to see, scale, mute and reroute an application's sound.

Katzensteg has no audio interposition today. Sources are pinned to the same SDL
releases the dynamic API slot tables are generated from (SDL 2.32.10 and SDL
3.4.16, see `src/katzensteg/sdl2_dynapi_slots.h:1-3` and
`src/katzensteg/sdl3_dynapi_slots.h:1-3`), sdl2-compat `release-2.32.74` and
RetroArch `v1.22.2`.

Link prefixes used below:

- SDL2: `https://github.com/libsdl-org/SDL/blob/release-2.32.10/`
- SDL3: `https://github.com/libsdl-org/SDL/blob/release-3.4.16/`
- sdl2-compat: `https://github.com/libsdl-org/sdl2-compat/blob/release-2.32.74/`
- RetroArch: `https://github.com/libretro/RetroArch/blob/v1.22.2/`

## Answer In Brief

| Goal | SDL2 (classic or sdl2-compat) | SDL3 |
| --- | --- | --- |
| (a) gain and mute | Wrap the app callback passed to `SDL_OpenAudio` / `SDL_OpenAudioDevice` with a Katzensteg trampoline that scales the buffer after the app fills it. Queue-mode apps need Katzensteg to own the queue (`SDL_QueueAudio`, `SDL_GetQueuedAudioSize`, `SDL_ClearQueuedAudio`). | A Katzensteg postmix callback (`SDL_SetAudioPostmixCallback`) on every logical device the app opens, or `SDL_SetAudioDeviceGain` on those devices. |
| (b) virtual paced device | Cheapest: force the `dummy` driver (`SDL_AUDIODRIVER=dummy`) and keep the (a)/(c) hooks. Clock-exact: Katzensteg owns the device ID and drives the app callback from its own thread, which pulls in the whole SDL2 device API (pause, lock, status, close, queue). | Cheapest: `SDL_AUDIO_DRIVER=dummy`. Clock-exact: leave the app's streams unbound and pull them with `SDL_GetAudioStreamData` on Katzensteg's clock, which pulls in open, bind, pause/resume, stream-device and destroy APIs. |
| (c) tap PCM and format | Same trampoline: after the app callback returns, the buffer holds `callbackspec.size` bytes in the obtained spec. | Same postmix callback: always `SDL_AUDIO_F32`, with the device's current channels and rate passed per call. |

The minimal SDL2 choke points are the two open functions, because the callback
pointer only enters SDL there. The minimal SDL3 choke points are the two open
functions plus `SDL_SetAudioPostmixCallback`, because the postmix callback sees
the final mix of each logical device and may modify it in place.

## How Interception Reaches Audio Calls

Katzensteg's wrappers are shared by every mechanism. Preload builds resolve the
real functions with `dlsym(RTLD_NEXT)` (`src/katzensteg/real_sdl_linux.c:18`),
macOS adds `DYLD_INTERPOSE` entries and the rebinder
(`src/katzensteg/interpose_macos.c:155`, `src/katzensteg/preload_macos_rebind.c`),
and dynamic API builds substitute slots in SDL's jump table
(`src/katzensteg/dynapi.zig:1-16`, `docs/launcher.md:62-80`). Adding an audio
function therefore means: an entry in `real_sdl{2,3}_functions.h`, a `KS_WRAP`
line in `interpose_sdl{2,3}_dynapi_functions.h`, an export in
`interpose_linux.c` / `interpose_sdl3_linux.c` and the macOS equivalents, and a
regenerated slot header from `scripts/katzensteg/gen_dynapi_slots.py`. Every
audio function listed below exists in the dynamic API tables
(SDL2 [`src/dynapi/SDL_dynapi_procs.h#L107-L131`](https://github.com/libsdl-org/SDL/blob/release-2.32.10/src/dynapi/SDL_dynapi_procs.h#L107-L131),
[`#L622-L641`](https://github.com/libsdl-org/SDL/blob/release-2.32.10/src/dynapi/SDL_dynapi_procs.h#L622-L641);
SDL3 [`src/dynapi/SDL_dynapi_procs.h#L692-L693`](https://github.com/libsdl-org/SDL/blob/release-3.4.16/src/dynapi/SDL_dynapi_procs.h#L692-L693),
[`#L823-L828`](https://github.com/libsdl-org/SDL/blob/release-3.4.16/src/dynapi/SDL_dynapi_procs.h#L823-L828)).

Two rules apply to both mechanisms:

- **Internal SDL calls are invisible.** Inside SDL, public names are macros for
  the `_REAL` functions
  ([SDL2 `src/dynapi/SDL_dynapi_overrides.h#L81`](https://github.com/libsdl-org/SDL/blob/release-2.32.10/src/dynapi/SDL_dynapi_overrides.h#L81)
  maps `SDL_OpenAudioDevice` to `SDL_OpenAudioDevice_REAL`), so neither the jump
  table nor symbol interposition sees them. Concretely: SDL2 `SDL_OpenAudio`
  calls the static `open_audio_device` directly
  ([`src/audio/SDL_audio.c#L1571-L1603`](https://github.com/libsdl-org/SDL/blob/release-2.32.10/src/audio/SDL_audio.c#L1571-L1603)),
  `SDL_PauseAudio` calls `SDL_PauseAudioDevice(1, ...)` internally
  ([`#L1642-L1645`](https://github.com/libsdl-org/SDL/blob/release-2.32.10/src/audio/SDL_audio.c#L1642-L1645)),
  SDL3 `SDL_OpenAudioDeviceStream` calls `SDL_OpenAudioDevice` internally
  ([`src/audio/SDL_audio.c#L2222-L2226`](https://github.com/libsdl-org/SDL/blob/release-3.4.16/src/audio/SDL_audio.c#L2222-L2226)),
  and SDL3 `SDL_DestroyAudioStream` closes a simplified stream's device
  internally
  ([`src/audio/SDL_audiocvt.c#L1524-L1528`](https://github.com/libsdl-org/SDL/blob/release-3.4.16/src/audio/SDL_audiocvt.c#L1524-L1528)).
  Each public entry point must be wrapped on its own, and lifetime tracking
  must tolerate devices that close without a visible close call (also
  `SDL_QuitSubSystem(SDL_INIT_AUDIO)` and `SDL_Quit`).
- **SDL2 and SDL3 share names with different ABIs.** `SDL_OpenAudioDevice`,
  `SDL_PauseAudioDevice`, `SDL_CloseAudioDevice`, `SDL_GetAudioDeviceName` and
  `SDL_MixAudio` exist in both with different signatures (SDL2
  `SDL_PauseAudioDevice(SDL_AudioDeviceID, int)` returns void, SDL2 procs
  [`#L119`](https://github.com/libsdl-org/SDL/blob/release-2.32.10/src/dynapi/SDL_dynapi_procs.h#L119);
  SDL3 `SDL_PauseAudioDevice(SDL_AudioDeviceID)` returns bool, SDL3 procs
  [`#L708`](https://github.com/libsdl-org/SDL/blob/release-3.4.16/src/dynapi/SDL_dynapi_procs.h#L708)).
  Audio wrappers belong in the per-ABI adapters (`preload.zig` and
  `preload_sdl3.zig`, `sdl2/abi.zig` and `sdl3/abi.zig`), like the existing
  video wrappers.

## SDL2

### Device model

An SDL2 output device is driven by a single SDL thread, `SDL_RunAudio`, at
time-critical priority
([`src/audio/SDL_audio.c#L672-L691`](https://github.com/libsdl-org/SDL/blob/release-2.32.10/src/audio/SDL_audio.c#L672-L691)).
Each iteration it locks `device->mixer_lock` and either writes silence (paused)
or calls the app callback with `callbackspec.size` bytes
([`#L729-L738`](https://github.com/libsdl-org/SDL/blob/release-2.32.10/src/audio/SDL_audio.c#L729-L738)).
If the obtained spec differs from the hardware, SDL converts through an internal
`SDL_AudioStream` after the callback
([`#L740-L776`](https://github.com/libsdl-org/SDL/blob/release-2.32.10/src/audio/SDL_audio.c#L740-L776)).

Queue mode is the same machinery: when `desired->callback` is NULL, SDL installs
its own `SDL_BufferQueueDrainCallback` as the callback
([`#L1495-L1504`](https://github.com/libsdl-org/SDL/blob/release-2.32.10/src/audio/SDL_audio.c#L1495-L1504)),
and `SDL_QueueAudio` refuses any device whose callback is not that one
([`#L590-L610`](https://github.com/libsdl-org/SDL/blob/release-2.32.10/src/audio/SDL_audio.c#L590-L610)).

So everything an SDL2 app plays passes through exactly one place: the buffer
the callback slot fills, in the obtained (callback) format, before SDL's own
conversion.

### Function inventory

| Function | Role for Katzensteg | Needed for |
| --- | --- | --- |
| `SDL_OpenAudioDevice` | Callback pointer, userdata, desired and obtained spec, `iscapture`, `allowed_changes` enter here ([`#L1605-L1611`](https://github.com/libsdl-org/SDL/blob/release-2.32.10/src/audio/SDL_audio.c#L1605-L1611)). Substitute a trampoline callback. | a, b, c |
| `SDL_OpenAudio` | Legacy open, always device ID 1 ([`#L1571-L1603`](https://github.com/libsdl-org/SDL/blob/release-2.32.10/src/audio/SDL_audio.c#L1571-L1603)). Does not route through the public `SDL_OpenAudioDevice`. | a, b, c |
| `SDL_QueueAudio`, `SDL_GetQueuedAudioSize`, `SDL_ClearQueuedAudio` | Queue-mode output ([`#L590-L670`](https://github.com/libsdl-org/SDL/blob/release-2.32.10/src/audio/SDL_audio.c#L590-L670)). Must be served by Katzensteg once it replaces the NULL callback. | a, b, c for queue-mode apps |
| `SDL_DequeueAudio` | Capture-side queue only ([`#L612-L628`](https://github.com/libsdl-org/SDL/blob/release-2.32.10/src/audio/SDL_audio.c#L612-L628)). Pass through. | none |
| `SDL_CloseAudioDevice`, `SDL_CloseAudio` | Release Katzensteg's per-device record after the real close returns (the callback can run until then). | lifetime |
| `SDL_PauseAudioDevice`, `SDL_PauseAudio` | Sets `paused` under the device lock ([`#L1632-L1645`](https://github.com/libsdl-org/SDL/blob/release-2.32.10/src/audio/SDL_audio.c#L1632-L1645)). Observe only; never use it to mute (see pitfalls). | b only |
| `SDL_LockAudioDevice`, `SDL_UnlockAudioDevice`, `SDL_LockAudio`, `SDL_UnlockAudio` | Take `mixer_lock`, skipped when already on the audio thread ([`#L299-L325`](https://github.com/libsdl-org/SDL/blob/release-2.32.10/src/audio/SDL_audio.c#L299-L325), [`#L1647-L1673`](https://github.com/libsdl-org/SDL/blob/release-2.32.10/src/audio/SDL_audio.c#L1647-L1673)). The trampoline runs inside this lock, so app locking keeps working unwrapped. | b only |
| `SDL_GetAudioDeviceStatus`, `SDL_GetAudioStatus` | Status of an ID. | b only |
| `SDL_InitSubSystem(SDL_INIT_AUDIO)`, `SDL_Init` | Already wrapped (`src/katzensteg/preload.zig:418-428`). Audio driver selection reads the `SDL_AUDIODRIVER` hint at audio init ([`#L969`](https://github.com/libsdl-org/SDL/blob/release-2.32.10/src/audio/SDL_audio.c#L969)), and `SDL_OpenAudio` initializes audio itself ([`#L1575-L1580`](https://github.com/libsdl-org/SDL/blob/release-2.32.10/src/audio/SDL_audio.c#L1575-L1580)), so a forced driver is best set in the launcher environment. | b (driver choice) |
| `SDL_GetNumAudioDevices`, `SDL_GetAudioDeviceName`, `SDL_GetAudioDeviceSpec`, `SDL_GetDefaultAudioInfo` | Enumeration. Only needed to advertise a named virtual device or to map name-based opens. | b, optional |
| `SDL_MixAudio` | Mixes in device 1's callback format ([`#L1788-L1795`](https://github.com/libsdl-org/SDL/blob/release-2.32.10/src/audio/SDL_audio.c#L1788-L1795)). Only matters if Katzensteg replaces device 1 entirely. | b, optional |
| `SDL_NewAudioStream` family, `SDL_MixAudioFormat`, `SDL_BuildAudioCVT`, `SDL_ConvertAudio` | Standalone conversion and mixing helpers (procs [`#L122-L125`](https://github.com/libsdl-org/SDL/blob/release-2.32.10/src/dynapi/SDL_dynapi_procs.h#L122-L125), [`#L680-L686`](https://github.com/libsdl-org/SDL/blob/release-2.32.10/src/dynapi/SDL_dynapi_procs.h#L680-L686)). Not bound to devices; their output still reaches a device through the callback or the queue. | none |

`SDL_MixAudioFormat` is not a usable gain primitive for Katzensteg: it mixes
additively into `dst` and its volume is capped at `SDL_MIX_MAXVOLUME` (128)
([`include/SDL_audio.h#L1121-L1140`](https://github.com/libsdl-org/SDL/blob/release-2.32.10/include/SDL_audio.h#L1121-L1140)).
An in-place per-format scaler (U8, S8, S16, S32, F32, both endians, plus U16
for SDL2) is simpler and owned by Katzensteg.

### Queue-mode choice

Two options for apps that use `SDL_QueueAudio`:

1. **Wrap `SDL_QueueAudio` only.** Scale and tap at enqueue time. Small, but a
   gain change only applies to audio queued after it, so a mute lags by the
   app's queue depth.
2. **Own the queue.** At open, replace the NULL callback with a Katzensteg
   drain callback over a Katzensteg queue, and implement `SDL_QueueAudio`,
   `SDL_GetQueuedAudioSize` and `SDL_ClearQueuedAudio` for that device (the
   real `SDL_QueueAudio` would now refuse it). Gain is immediate, the tap sees
   what is actually played, and the same code is the core of a virtual device.
   `SDL_GetQueuedAudioSize` must stay accurate because apps pace on it.

Option 2 is the recommendation.

## SDL3

### Device model

SDL3 opens logical devices on physical devices; each logical device has bound
`SDL_AudioStream`s, a gain and an optional postmix callback. The playback
thread mixes, per unpaused logical device, all bound streams with the logical
device gain applied, then calls that device's postmix callback on the result
and mixes it into the final buffer
([`src/audio/SDL_audio.c#L1182-L1300`](https://github.com/libsdl-org/SDL/blob/release-3.4.16/src/audio/SDL_audio.c#L1182-L1300)).
The postmix buffer is always `SDL_AUDIO_F32` in the device's current channels
and rate, may be modified in place, and the spec can change between calls
([`include/SDL3/SDL_audio.h#L2060-L2149`](https://github.com/libsdl-org/SDL/blob/release-3.4.16/include/SDL3/SDL_audio.h#L2060-L2149)).
Device gain is read each iteration, so changes are immediate
([`SDL_audio.c#L1218`](https://github.com/libsdl-org/SDL/blob/release-3.4.16/src/audio/SDL_audio.c#L1218),
[`#L1266`](https://github.com/libsdl-org/SDL/blob/release-3.4.16/src/audio/SDL_audio.c#L1266)),
but gain only works on logical devices
([`SDL_audio.h#L881-L913`](https://github.com/libsdl-org/SDL/blob/release-3.4.16/include/SDL3/SDL_audio.h#L881-L913)).

`SDL_OpenAudioDeviceStream` is a convenience that opens a logical device,
creates one stream, binds it, marks both "simplified", starts paused and
installs the app's get callback on the stream
([`#L2222-L2286`](https://github.com/libsdl-org/SDL/blob/release-3.4.16/src/audio/SDL_audio.c#L2222-L2286)).
Plain `SDL_OpenAudioDevice` starts unpaused
([`#L1884-L1920`](https://github.com/libsdl-org/SDL/blob/release-3.4.16/src/audio/SDL_audio.c#L1884-L1920)).

### Function inventory

| Function | Role for Katzensteg | Needed for |
| --- | --- | --- |
| `SDL_OpenAudioDevice` | Returns a logical device ID. Record it; install Katzensteg's postmix (or set gain). | a, b, c |
| `SDL_OpenAudioDeviceStream` | Returns a stream; its logical device is `SDL_GetAudioStreamDevice(stream)` ([`#L2202`](https://github.com/libsdl-org/SDL/blob/release-3.4.16/src/audio/SDL_audio.c#L2202)). Record and install postmix. | a, b, c |
| `SDL_SetAudioPostmixCallback` | One postmix slot per logical device ([`#L2005-L2025`](https://github.com/libsdl-org/SDL/blob/release-3.4.16/src/audio/SDL_audio.c#L2005-L2025)). If Katzensteg uses postmix, it must wrap this so an app postmix is chained, not allowed to replace Katzensteg's. | a, c |
| `SDL_SetAudioDeviceGain`, `SDL_GetAudioDeviceGain` | Wrap only if Katzensteg uses device gain: store the app's gain, apply `app_gain * katzensteg_gain`, report the app's value back ([`#L1987-L2000`](https://github.com/libsdl-org/SDL/blob/release-3.4.16/src/audio/SDL_audio.c#L1987-L2000)). | a (gain route) |
| `SDL_CloseAudioDevice`, `SDL_DestroyAudioStream` | Lifetime. A simplified stream's destroy closes its device without a public close call. | lifetime |
| `SDL_SetAudioStreamGain` | Per-stream gain, applied before device gain. App-owned; leave alone. | none |
| `SDL_BindAudioStream(s)`, `SDL_UnbindAudioStream(s)`, `SDL_PauseAudioDevice`, `SDL_ResumeAudioDevice`, `SDL_PauseAudioStreamDevice`, `SDL_ResumeAudioStreamDevice`, `SDL_GetAudioStreamDevice`, `SDL_AudioDevicePaused` | Only needed if Katzensteg replaces the device and pulls streams itself. | b only |
| `SDL_PutAudioStreamData`, `SDL_PutAudioStreamDataNoCopy`, `SDL_PutAudioStreamPlanarData`, `SDL_SetAudioStreamGetCallback` | App feeding paths. Not choke points: unbound streams (converters) also use them, and bound data surfaces in postmix anyway. | none |
| `SDL_GetAudioPlaybackDevices`, `SDL_GetAudioDeviceName`, `SDL_GetAudioDeviceFormat` | Enumeration, only for a named virtual device. | b, optional |
| `SDL_MixAudio`, `SDL_ConvertAudioSamples` | Helpers. | none |

Postmix versus gain: postmix is one hook for both gain and tap (copy, then
scale or zero in place), and lets Katzensteg publish the unmuted mix while
muting locally. Device gain is cheaper, but postmix runs after gain
([`SDL_audio.h#L2075-L2077`](https://github.com/libsdl-org/SDL/blob/release-3.4.16/include/SDL3/SDL_audio.h#L2075-L2077)),
so a gain-muted device taps silence. Any postmix disables SDL's single-stream
`simple_copy` fast path
([`SDL_audio.c#L227-L236`](https://github.com/libsdl-org/SDL/blob/release-3.4.16/src/audio/SDL_audio.c#L227-L236)),
which is a small CPU cost, not a behaviour change.

## sdl2-compat

sdl2-compat exports the SDL2 ABI and implements it over SDL3:

- It `dlopen`s `libSDL3` with `RTLD_LOCAL` and resolves every SDL3 function
  with `dlsym` on that handle
  ([`src/sdl2_compat.c#L456-L457`](https://github.com/libsdl-org/sdl2-compat/blob/release-2.32.74/src/sdl2_compat.c#L456-L457),
  [`#L1128`](https://github.com/libsdl-org/sdl2-compat/blob/release-2.32.74/src/sdl2_compat.c#L1128)).
- An SDL2 audio device is an SDL3 logical device from `SDL3_OpenAudioDevice`,
  paused to match SDL2, plus an SDL2 audio stream (wrapping an SDL3 stream)
  bound to it
  ([`#L7957-L8013`](https://github.com/libsdl-org/sdl2-compat/blob/release-2.32.74/src/sdl2_compat.c#L7957-L8013)).
- The app's SDL2 callback is driven from an SDL3 get callback,
  `SDL2AudioDeviceCallbackBridge`, which calls it in `obtained->size` chunks
  and puts the result into the stream
  ([`#L7855-L7880`](https://github.com/libsdl-org/sdl2-compat/blob/release-2.32.74/src/sdl2_compat.c#L7855-L7880)).
- `allowed_changes` is forced to 0, so the obtained spec always equals the
  desired spec and SDL3 converts
  ([`#L7897-L7901`](https://github.com/libsdl-org/sdl2-compat/blob/release-2.32.74/src/sdl2_compat.c#L7897-L7901)).
- `SDL_QueueAudio` is `SDL3_PutAudioStreamData`
  ([`#L8325-L8341`](https://github.com/libsdl-org/sdl2-compat/blob/release-2.32.74/src/sdl2_compat.c#L8325-L8341)),
  `SDL_LockAudioDevice` is `SDL3_LockAudioStream`
  ([`#L8408-L8412`](https://github.com/libsdl-org/sdl2-compat/blob/release-2.32.74/src/sdl2_compat.c#L8408-L8412)),
  and `SDL_PauseAudioDevice` pauses the SDL3 device and clears callback streams
  ([`#L8369-L8390`](https://github.com/libsdl-org/sdl2-compat/blob/release-2.32.74/src/sdl2_compat.c#L8369-L8390)).
- sdl2-compat has its own SDL2 dynamic API with `SDL_DYNAPI_entry`
  ([`src/dynapi/SDL_dynapi.c#L351-L353`](https://github.com/libsdl-org/sdl2-compat/blob/release-2.32.74/src/dynapi/SDL_dynapi.c#L351-L353)).

Consequences for which layer to hook:

- **Hook the SDL2 ABI.** `libkatzensteg-sdl2` preload and `SDL_DYNAMIC_API`
  both see the same SDL2 entry points on classic SDL2 and on sdl2-compat, and
  the callback trampoline works the same on both. On sdl2-compat the
  trampoline runs inside the bridge, under the SDL3 stream lock, on SDL3's
  device thread.
- **SDL3 symbol preload does not see sdl2-compat's SDL3 calls.** They are
  resolved by `dlsym` on sdl2-compat's private `RTLD_LOCAL` handle, which
  searches that library's own dependency scope, not preloaded objects. This is
  expected from loader semantics and should be confirmed with a probe.
- **`SDL3_DYNAMIC_API` would see them.** SDL3's exported functions dispatch
  through its jump table, so an SDL3 dynapi Katzensteg loaded under sdl2-compat
  could use SDL3 postmix or gain for an SDL2 app. This is a second way in, not
  a reason to drop the SDL2-layer hooks, which also cover classic SDL2.
- Where SDL2 is provided by sdl2-compat (for example on macOS hosts), the
  per-chunk callback bridge means callback cadence and size follow SDL3's
  requests, not SDL2's device period.

## RetroArch

RetroArch's `sdl2` audio driver is SDL2 (or SDL 1.2 when built without
`HAVE_SDL2`); there is no SDL3 audio driver in `v1.22.2`
([`audio/drivers/sdl_audio.c#L741-L745`](https://github.com/libretro/RetroArch/blob/v1.22.2/audio/drivers/sdl_audio.c#L741-L745)).
It uses the callback model with its own FIFO, not `SDL_QueueAudio`:

- Opens with `SDL_OpenAudioDevice(NULL, false, &spec, &obtained, 0)`, so
  `allowed_changes` is 0, requesting `AUDIO_F32SYS` stereo at the core rate
  ([`#L529-L547`](https://github.com/libretro/RetroArch/blob/v1.22.2/audio/drivers/sdl_audio.c#L529-L547)).
  SDL 1.2 builds use `SDL_OpenAudio` with `AUDIO_S16SYS`.
- The callback drains the FIFO, signals a condition variable and fills any
  underrun with silence
  ([`#L457-L468`](https://github.com/libretro/RetroArch/blob/v1.22.2/audio/drivers/sdl_audio.c#L457-L468)).
- `sdl_audio_write` takes `SDL_LockAudioDevice` around FIFO writes and, in
  blocking mode, waits on that condition variable until the callback frees
  space
  ([`#L604-L658`](https://github.com/libretro/RetroArch/blob/v1.22.2/audio/drivers/sdl_audio.c#L604-L658)).
  With audio sync on, the callback cadence is RetroArch's emulation clock.
- Start and stop are `SDL_PauseAudioDevice`
  ([`#L660-L682`](https://github.com/libretro/RetroArch/blob/v1.22.2/audio/drivers/sdl_audio.c#L660-L682));
  init uses `SDL_WasInit` / `SDL_InitSubSystem(SDL_INIT_AUDIO)`
  ([`#L495-L517`](https://github.com/libretro/RetroArch/blob/v1.22.2/audio/drivers/sdl_audio.c#L495-L517));
  enumeration uses `SDL_GetNumAudioDevices` / `SDL_GetAudioDeviceName`
  ([`#L470-L493`](https://github.com/libretro/RetroArch/blob/v1.22.2/audio/drivers/sdl_audio.c#L470-L493)).
- The microphone driver opens a capture device with a callback and
  `SDL_AUDIO_ALLOW_FREQUENCY_CHANGE | SDL_AUDIO_ALLOW_FORMAT_CHANGE`
  ([`#L179-L195`](https://github.com/libretro/RetroArch/blob/v1.22.2/audio/drivers/sdl_audio.c#L179-L195)).
  Katzensteg should pass capture devices through.

The RetroArch profile must select the `sdl2` audio driver; its other drivers
(PulseAudio, ALSA, PipeWire and so on) bypass SDL entirely. The SDL2 open
trampoline covers it fully; no queue functions are involved.

## Pitfalls

- **Never mute by pausing or by stopping callbacks.** SDL2 pause skips the
  callback ([`SDL_audio.c#L733-L737`](https://github.com/libsdl-org/SDL/blob/release-2.32.10/src/audio/SDL_audio.c#L733-L737)),
  and apps that pace on the callback stall: RetroArch's blocking write waits
  for the callback's signal. Mute is gain 0 with the callback still running.
- **Audio thread constraints.** The SDL2 trampoline runs on a time-critical
  thread holding `mixer_lock`; the SDL3 postmix runs with the device lock held
  ([`SDL_audio.c#L1186`](https://github.com/libsdl-org/SDL/blob/release-3.4.16/src/audio/SDL_audio.c#L1186)).
  No allocation, no blocking, no file logging per buffer; publish through a
  lock-free ring that a Katzensteg thread drains. Gain must be an atomic the
  trampoline reads.
- **Apps write into the stream from the callback.** In SDL3 the get callback
  calls `SDL_PutAudioStreamData` from SDL's thread; in sdl2-compat this is how
  every SDL2 callback works. Taps on put functions would see data at enqueue
  time, not play time, which is another reason to tap at postmix or the SDL2
  callback output.
- **Format negotiation.** The SDL2 callback buffer is in `callbackspec`, the
  obtained spec, which differs from desired only where `allowed_changes`
  permitted it ([`SDL_audio.c#L1444-L1476`](https://github.com/libsdl-org/SDL/blob/release-2.32.10/src/audio/SDL_audio.c#L1444-L1476)).
  The wrapper must read the obtained spec after the real open. If the app
  passes `obtained == NULL`, the wrapper must not substitute its own pointer:
  `SDL_OpenAudio` treats a non-NULL `obtained` as `SDL_AUDIO_ALLOW_ANY_CHANGE`
  and NULL as no changes
  ([`#L1586-L1598`](https://github.com/libsdl-org/SDL/blob/release-2.32.10/src/audio/SDL_audio.c#L1586-L1598)),
  so it would change the format the app receives. Read the spec from
  `desired` (format, channels, rate unchanged; size and silence written back)
  instead. SDL3 postmix receives the spec on every call and it can change.
- **Multiple devices per app.** SDL2 allows several open device IDs, with
  `SDL_OpenAudio` fixed at ID 1 and legacy calls (`SDL_PauseAudio`,
  `SDL_LockAudio`, `SDL_CloseAudio`, `SDL_GetAudioStatus`, `SDL_MixAudio`)
  meaning ID 1. SDL3 apps can open many logical devices and bind many streams.
  Katzensteg's audio state must be a per-device table, and published audio is
  either per device or a Katzensteg-side mix.
- **Capture devices.** Both versions use the same open calls for recording.
  The wrapper must check `iscapture` (SDL2) or `SDL_IsAudioDevicePlayback`
  (SDL3) and leave recording devices alone.
- **Dummy driver drift.** SDL2's dummy output has no device buffer, so SDL
  sleeps `samples * 1000 / freq` integer milliseconds per buffer
  ([`SDL_audio.c#L268-L271`](https://github.com/libsdl-org/SDL/blob/release-2.32.10/src/audio/SDL_audio.c#L268-L271),
  [`#L782-L785`](https://github.com/libsdl-org/SDL/blob/release-2.32.10/src/audio/SDL_audio.c#L782-L785));
  SDL3's dummy computes the same truncated `io_delay`
  ([`src/audio/dummy/SDL_dummyaudio.c#L32-L58`](https://github.com/libsdl-org/SDL/blob/release-3.4.16/src/audio/dummy/SDL_dummyaudio.c#L32-L58)).
  1024 frames at 48 kHz is 21.33 ms played as 21 ms, about 1.6% fast. SDL3
  adds `SDL_AUDIO_DUMMY_TIMESCALE`
  ([`include/SDL3/SDL_hints.h#L526`](https://github.com/libsdl-org/SDL/blob/release-3.4.16/include/SDL3/SDL_hints.h#L526)).
  The driver hint is `SDL_AUDIODRIVER` in SDL2
  ([`include/SDL_hints.h#L3049`](https://github.com/libsdl-org/SDL/blob/release-2.32.10/include/SDL_hints.h#L3049))
  and `SDL_AUDIO_DRIVER` in SDL3
  ([`include/SDL3/SDL_hints.h#L513`](https://github.com/libsdl-org/SDL/blob/release-3.4.16/include/SDL3/SDL_hints.h#L513)).
- **Postmix ordering.** `SDL_SetAudioPostmixCallback` blocks until the device
  is between iterations
  ([`SDL_audio.h#L2133-L2135`](https://github.com/libsdl-org/SDL/blob/release-3.4.16/include/SDL3/SDL_audio.h#L2133-L2135)).
  Install it from the open wrapper, not from the audio thread.

## Recommended Minimal Interception Set

### SDL2 (classic SDL2 and sdl2-compat)

Same set for preload (Linux `LD_PRELOAD`, macOS `DYLD_INSERT_LIBRARIES` plus
rebinder) and `SDL_DYNAMIC_API`, in `libkatzensteg-sdl2*`:

1. `SDL_OpenAudioDevice`, `SDL_OpenAudio`: for playback devices, record the
   device and its obtained spec, substitute a trampoline callback that calls
   the app callback then taps and scales; for NULL callbacks, substitute a
   Katzensteg drain callback.
2. `SDL_QueueAudio`, `SDL_GetQueuedAudioSize`, `SDL_ClearQueuedAudio`: serve
   from Katzensteg's queue for devices it took over; pass through otherwise.
3. `SDL_CloseAudioDevice`, `SDL_CloseAudio`, and the existing
   `SDL_QuitSubSystem` / `SDL_Quit` wrappers: free records after the real call.

That is seven new functions and covers (a) and (c). For (b), start with the
launcher setting `SDL_AUDIODRIVER=dummy`; a clock-exact virtual device adds
`SDL_PauseAudio(Device)`, `SDL_LockAudio(Device)`, `SDL_UnlockAudio(Device)`,
`SDL_GetAudioStatus`, `SDL_GetAudioDeviceStatus`, `SDL_MixAudio` and optionally
enumeration.

### SDL3

Same set for preload and `SDL3_DYNAMIC_API`, in `libkatzensteg-sdl3*`:

1. `SDL_OpenAudioDevice`, `SDL_OpenAudioDeviceStream`: record playback logical
   devices, install Katzensteg's postmix (tap, then scale in place).
2. `SDL_SetAudioPostmixCallback`: chain an app postmix behind Katzensteg's.
3. `SDL_CloseAudioDevice`, `SDL_DestroyAudioStream`, plus the existing quit
   wrappers: lifetime.

Five new functions for (a) and (c). For (b), start with
`SDL_AUDIO_DRIVER=dummy`; a clock-exact device adds the bind, unbind,
pause/resume (device and stream-device) and `SDL_GetAudioStreamDevice` family
and pulls streams with `SDL_GetAudioStreamData`, which runs the app's get
callbacks
([`src/audio/SDL_audiocvt.c#L1375-L1393`](https://github.com/libsdl-org/SDL/blob/release-3.4.16/src/audio/SDL_audiocvt.c#L1375-L1393)).

### sdl2-compat specifically

Use the SDL2 set. Optionally, `SDL3_DYNAMIC_API` with the SDL3 set gives
SDL3-native gain and postmix for SDL2 apps on sdl2-compat; preloading the SDL3
library does not.

## Open Questions For #148 ("Katzensteg audio model")

1. Is "real device plus gain and tap" enough for console takeover and WM
   per-window volume, with the virtual device only for headless or remote
   sessions?
2. For (b), is SDL's dummy-driver wall clock acceptable, or must the device be
   paced by Katzensteg or Jackstay's clock (needed for A/V sync with presented
   frames, and for apps such as RetroArch whose emulation speed follows the
   callback)? If clock-exact, is that worth owning the full SDL2 device-ID API?
3. Where does the clock live when audio is published to Jackstay and also
   played locally: the local device, Katzensteg, or the Jackstay consumer?
4. Published format: forward the app's obtained format with a spec header
   (matching the "pass the original format through" rule for Vulkan frames in
   `CLAUDE.md`), or normalize to F32 at the publisher? SDL3 postmix already
   gives F32; SDL2 gives the app format.
5. Per-device or per-app stream to Jackstay when an app opens several devices,
   and who mixes?
6. Does muting for console takeover also need to silence the tap, or only the
   local output?
7. Which mechanism is primary for sdl2-compat hosts: the SDL2-layer trampoline
   everywhere, or `SDL3_DYNAMIC_API` when available?
8. Do we need a probe app per model (SDL2 callback, SDL2 queue, SDL3 bound
   stream, SDL3 `SDL_OpenAudioDeviceStream`) in `probes.json` before
   implementation, and a check that SDL3 preload misses sdl2-compat's
   internal SDL3 calls?
9. Lock-free ring sizing and the drop policy when the consumer stalls, so the
   audio thread never blocks.
