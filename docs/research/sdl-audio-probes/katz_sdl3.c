/* Experimental SDL3 audio interposer.
 *
 * Built twice from this file:
 *   katz_sdl3_preload.so  LD_PRELOAD, real functions from dlsym(RTLD_NEXT)
 *   katz_sdl3_dynapi.so   SDL3_DYNAMIC_API, exports only SDL_DYNAPI_entry,
 *                         fills the table from the loading SDL3 and swaps
 *                         the wrapped slots (the same scheme as
 *                         src/katzensteg/dynapi.zig)
 *
 * Wraps SDL_OpenAudioDevice and SDL_OpenAudioDeviceStream (install a
 * postmix on each playback logical device), SDL_SetAudioPostmixCallback
 * (chain the app's postmix instead of letting it replace ours),
 *   katz_sdl3_symver.so   LD_PRELOAD, wrappers exported only as the hidden
 *                         version SDL_x@SDL3_0.0.0 (not @@), real functions
 *                         from dlvsym(RTLD_NEXT, name, "SDL3_0.0.0"); SDL2
 *                         callers (unversioned references) skip them
 *
 * Wraps SDL_OpenAudioDevice and SDL_OpenAudioDeviceStream (install a
 * postmix on each playback logical device), SDL_SetAudioPostmixCallback
 * (chain the app's postmix instead of letting it replace ours),
 * SDL_CloseAudioDevice and SDL_DestroyAudioStream (lifetime). The postmix
 * calls the app postmix, taps the F32 buffer, then applies KATZ_GAIN.
 * KATZ_SDL3_OBSERVE adds log-only wrappers for SDL3 functions sdl2-compat
 * uses internally (SDL_CreateAudioStream, SDL_BindAudioStream,
 * SDL_SetAudioStreamGetCallback, SDL_PutAudioStreamData), to see whether a
 * preload is reached by them. */
#ifdef KATZ_DYNAPI
#define KATZ_TAG "sdl3dyn-"
#elif defined(KATZ_SYMVER)
#define KATZ_TAG "sdl3v-"
#else
#define KATZ_TAG "sdl3-"
#endif
#include "katz_common.h"

#include <dlfcn.h>
#ifdef KATZ_DYNAPI
/* keep the wrappers out of the dynamic symbol table: only SDL_DYNAPI_entry */
#define SDL_DECLSPEC
#endif
#include <SDL3/SDL.h>

#ifdef KATZ_DYNAPI
enum {
#define SDL_DYNAPI_PROC(rc, fn, params, args, ret) KSLOT_##fn,
#include "SDL_dynapi_procs.h"
#undef SDL_DYNAPI_PROC
    KSLOT_COUNT
};
static void **katz_real_table;
#define REAL(fn) ((__typeof__(&fn))katz_real_table[KSLOT_##fn])
#define KATZ_EXPORT
#define WRAP(fn) fn
#else
#define REAL(fn) ((__typeof__(&fn))katz_dlnext(#fn))
#define KATZ_EXPORT
#ifdef KATZ_SYMVER
#define WRAP(fn) katz3_##fn
#define SYMVER(fn) __asm__(".symver katz3_" #fn ", " #fn "@SDL3_0.0.0");
#else
#define WRAP(fn) fn
#endif
static void *katz_dlnext(const char *name)
{
#ifdef KATZ_SYMVER
    void *p = dlvsym(RTLD_NEXT, name, "SDL3_0.0.0");
#else
    void *p = dlsym(RTLD_NEXT, name);
#endif
    if (!p) {
        katz_log("dlsym(RTLD_NEXT, %s) failed", name);
    }
    return p;
}
#endif

#ifndef SYMVER
#define SYMVER(fn)
#endif
SYMVER(SDL_OpenAudioDevice)
SYMVER(SDL_OpenAudioDeviceStream)
SYMVER(SDL_SetAudioPostmixCallback)
SYMVER(SDL_CloseAudioDevice)
SYMVER(SDL_DestroyAudioStream)
SYMVER(SDL_Quit)

__attribute__((constructor)) static void katz_sdl3_init(void)
{
    katz_init_env();
    katz_log("SDL3 interposer loaded (%s), gain=%.3f",
#ifdef KATZ_DYNAPI
             "SDL3_DYNAMIC_API",
#else
             "LD_PRELOAD",
#endif
             (double)atomic_load(&katz_gain));
}

static void SDLCALL katz_postmix(void *ud, const SDL_AudioSpec *spec, float *buffer, int buflen)
{
    katz_dev *d = ud;
    if (d->channels && (spec->channels != d->channels || spec->freq != d->freq)) {
        d->spec_changes++;
    }
    d->format = KF_F32LSB; /* postmix is always F32 */
    d->channels = spec->channels;
    d->freq = spec->freq;
    if (d->app_cb) {
        ((SDL_AudioPostmixCallback)d->app_cb)(d->app_ud, spec, buffer, buflen);
    }
    katz_tap_and_scale(d, (uint8_t *)buffer, buflen);
}

static void katz_install(katz_dev *d, SDL_AudioDeviceID logical)
{
    d->devid = logical;
    SDL_AudioSpec spec;
    int frames = 0;
    if (REAL(SDL_GetAudioDeviceFormat)(logical, &spec, &frames)) {
        d->channels = spec.channels;
        d->freq = spec.freq;
        d->format = KF_F32LSB;
        katz_log("  logical=%u device format fmt=0x%04x ch=%d freq=%d frames=%d", logical, spec.format, spec.channels,
                 spec.freq, frames);
    }
    if (!REAL(SDL_SetAudioPostmixCallback)(logical, katz_postmix, d)) {
        katz_log("  SetAudioPostmixCallback(%u) failed: %s", logical, REAL(SDL_GetError)());
    } else {
        katz_log("  installed postmix on logical=%u seq=%d", logical, d->seq);
    }
}

KATZ_EXPORT SDL_AudioDeviceID WRAP(SDL_OpenAudioDevice)(SDL_AudioDeviceID devid, const SDL_AudioSpec *spec)
{
    SDL_AudioDeviceID id = REAL(SDL_OpenAudioDevice)(devid, spec);
    katz_log("SDL_OpenAudioDevice(devid=0x%x, spec=%p fmt=0x%04x ch=%d freq=%d) -> %u", devid, (void *)spec,
             spec ? spec->format : 0, spec ? spec->channels : 0, spec ? spec->freq : 0, id);
    if (id && REAL(SDL_IsAudioDevicePlayback)(id)) {
        katz_dev *d = katz_alloc();
        if (d) {
            katz_install(d, id);
        }
    }
    return id;
}

KATZ_EXPORT SDL_AudioStream *WRAP(SDL_OpenAudioDeviceStream)(SDL_AudioDeviceID devid, const SDL_AudioSpec *spec,
                                                      SDL_AudioStreamCallback callback, void *userdata)
{
    SDL_AudioStream *s = REAL(SDL_OpenAudioDeviceStream)(devid, spec, callback, userdata);
    SDL_AudioDeviceID logical = s ? REAL(SDL_GetAudioStreamDevice)(s) : 0;
    katz_log("SDL_OpenAudioDeviceStream(devid=0x%x, fmt=0x%04x ch=%d freq=%d, cb=%p) -> stream=%p logical=%u", devid,
             spec ? spec->format : 0, spec ? spec->channels : 0, spec ? spec->freq : 0, (void *)callback, (void *)s,
             logical);
    if (logical && REAL(SDL_IsAudioDevicePlayback)(logical)) {
        katz_dev *d = katz_alloc();
        if (d) {
            d->stream = s;
            katz_install(d, logical);
        }
    }
    return s;
}

KATZ_EXPORT bool WRAP(SDL_SetAudioPostmixCallback)(SDL_AudioDeviceID devid, SDL_AudioPostmixCallback callback,
                                             void *userdata)
{
    katz_dev *d = katz_find(devid);
    katz_log("SDL_SetAudioPostmixCallback(devid=%u, cb=%p) tracked=%d", devid, (void *)callback, d != NULL);
    if (!d) {
        return REAL(SDL_SetAudioPostmixCallback)(devid, callback, userdata);
    }
    /* Swap the app's postmix under the device lock by re-installing ours:
     * SDL blocks until the device is between iterations. */
    REAL(SDL_SetAudioPostmixCallback)(devid, NULL, NULL);
    d->app_cb = (void *)callback;
    d->app_ud = userdata;
    return REAL(SDL_SetAudioPostmixCallback)(devid, katz_postmix, d);
}

KATZ_EXPORT void WRAP(SDL_CloseAudioDevice)(SDL_AudioDeviceID devid)
{
    katz_log("SDL_CloseAudioDevice(devid=%u)", devid);
    REAL(SDL_CloseAudioDevice)(devid);
    katz_dev *d = katz_find(devid);
    if (d) {
        katz_release(d);
    }
}

KATZ_EXPORT void WRAP(SDL_DestroyAudioStream)(SDL_AudioStream *stream)
{
    katz_dev *d = katz_find_stream(stream);
    katz_log("SDL_DestroyAudioStream(%p) simplified_tracked=%d", (void *)stream, d != NULL);
    REAL(SDL_DestroyAudioStream)(stream);
    if (d) {
        katz_release(d); /* its logical device closed inside SDL */
    }
}

KATZ_EXPORT void WRAP(SDL_Quit)(void)
{
    katz_log("SDL_Quit()");
    REAL(SDL_Quit)();
    for (int i = 0; i < KATZ_MAX_DEV; i++) {
        if (katz_devs[i].used) {
            katz_log("dev seq=%d id=%u closed by SDL_Quit without a visible close", katz_devs[i].seq, katz_devs[i].devid);
            katz_release(&katz_devs[i]);
        }
    }
}

#if defined(KATZ_SDL3_OBSERVE) && !defined(KATZ_DYNAPI)
#ifdef KATZ_SYMVER
SYMVER(SDL_CreateAudioStream)
SYMVER(SDL_BindAudioStream)
SYMVER(SDL_SetAudioStreamGetCallback)
SYMVER(SDL_PutAudioStreamData)
#endif
static atomic_int katz_put_calls;

KATZ_EXPORT SDL_AudioStream *WRAP(SDL_CreateAudioStream)(const SDL_AudioSpec *src, const SDL_AudioSpec *dst)
{
    katz_log("observe SDL_CreateAudioStream(src fmt=0x%04x)", src ? src->format : 0);
    return REAL(SDL_CreateAudioStream)(src, dst);
}

KATZ_EXPORT bool WRAP(SDL_BindAudioStream)(SDL_AudioDeviceID devid, SDL_AudioStream *stream)
{
    katz_log("observe SDL_BindAudioStream(devid=%u, %p)", devid, (void *)stream);
    return REAL(SDL_BindAudioStream)(devid, stream);
}

KATZ_EXPORT bool WRAP(SDL_SetAudioStreamGetCallback)(SDL_AudioStream *stream, SDL_AudioStreamCallback cb, void *ud)
{
    katz_log("observe SDL_SetAudioStreamGetCallback(%p, cb=%p)", (void *)stream, (void *)cb);
    return REAL(SDL_SetAudioStreamGetCallback)(stream, cb, ud);
}

KATZ_EXPORT bool WRAP(SDL_PutAudioStreamData)(SDL_AudioStream *stream, const void *buf, int len)
{
    if (atomic_fetch_add(&katz_put_calls, 1) == 0) {
        katz_log("observe SDL_PutAudioStreamData(%p, len=%d) first call", (void *)stream, len);
    }
    return REAL(SDL_PutAudioStreamData)(stream, buf, len);
}
#endif

#ifdef KATZ_DYNAPI
typedef Sint32 (*katz_entry_fn)(Uint32, void *, Uint32);

__attribute__((visibility("default"))) Sint32 SDL_DYNAPI_entry(Uint32 apiver, void *table, Uint32 tablesize)
{
    Dl_info info;
    if (!dladdr(table, &info)) {
        return -1;
    }
    void *h = dlopen(info.dli_fname, RTLD_LAZY | RTLD_NOLOAD);
    if (!h) {
        return -1;
    }
    katz_entry_fn real_entry = (katz_entry_fn)dlsym(h, "SDL_DYNAPI_entry");
    dlclose(h);
    if (!real_entry || tablesize < KSLOT_COUNT * sizeof(void *)) {
        return -1;
    }
    katz_real_table = calloc(tablesize / sizeof(void *), sizeof(void *));
    if (real_entry(apiver, katz_real_table, tablesize) < 0) {
        return -1;
    }
    void **t = table;
    memcpy(t, katz_real_table, tablesize);
    t[KSLOT_SDL_OpenAudioDevice] = (void *)WRAP(SDL_OpenAudioDevice);
    t[KSLOT_SDL_OpenAudioDeviceStream] = (void *)WRAP(SDL_OpenAudioDeviceStream);
    t[KSLOT_SDL_SetAudioPostmixCallback] = (void *)WRAP(SDL_SetAudioPostmixCallback);
    t[KSLOT_SDL_CloseAudioDevice] = (void *)WRAP(SDL_CloseAudioDevice);
    t[KSLOT_SDL_DestroyAudioStream] = (void *)WRAP(SDL_DestroyAudioStream);
    t[KSLOT_SDL_Quit] = (void *)WRAP(SDL_Quit);
    katz_log("SDL_DYNAPI_entry from %s: apiver=%u tablesize=%u slots=%d, wrapped 6", info.dli_fname, apiver, tablesize,
             (int)KSLOT_COUNT);
    return 0;
}
#endif
