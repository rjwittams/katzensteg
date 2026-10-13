/* Experimental SDL2 audio interposer (LD_PRELOAD, dlsym(RTLD_NEXT)).
 *
 * Wraps SDL_OpenAudioDevice and SDL_OpenAudio: playback callbacks are
 * replaced by a trampoline that calls the app callback, taps the buffer and
 * applies KATZ_GAIN. A NULL callback (queue mode) is replaced by a drain
 * callback over a queue this library owns, and SDL_QueueAudio,
 * SDL_GetQueuedAudioSize and SDL_ClearQueuedAudio are served from it.
 * SDL_CloseAudioDevice and SDL_CloseAudio release the record after the real
 * close returns. SDL_PauseAudioDevice and SDL_PauseAudio are logged only. */
#define KATZ_TAG "sdl2-"
#include "katz_common.h"

#include <dlfcn.h>
#include <SDL.h>

#define REAL(fn)                                                         \
    static __typeof__(&fn) real_##fn;                                    \
    if (!real_##fn) real_##fn = (__typeof__(&fn))dlsym(RTLD_NEXT, #fn)

__attribute__((constructor)) static void katz_sdl2_init(void)
{
    katz_init_env();
    katz_log("SDL2 interposer loaded, gain=%.3f", (double)atomic_load(&katz_gain));
}

static void SDLCALL katz_trampoline(void *ud, Uint8 *stream, int len)
{
    katz_dev *d = ud;
    ((SDL_AudioCallback)d->app_cb)(d->app_ud, stream, len);
    katz_tap_and_scale(d, stream, len);
}

static Uint8 katz_silence(int format)
{
    return (format == AUDIO_U8 || format == AUDIO_U16LSB || format == AUDIO_U16MSB) ? 0x80 : 0x00;
}

static void SDLCALL katz_drain(void *ud, Uint8 *stream, int len)
{
    katz_dev *d = ud;
    pthread_mutex_lock(&d->qlock);
    size_t n = d->qlen < (size_t)len ? d->qlen : (size_t)len;
    for (size_t i = 0; i < n; i++) {
        stream[i] = d->q[(d->qhead + i) % d->qcap];
    }
    d->qhead = d->qcap ? (d->qhead + n) % d->qcap : 0;
    d->qlen -= n;
    pthread_mutex_unlock(&d->qlock);
    if (n < (size_t)len) {
        memset(stream + n, katz_silence(d->format), (size_t)len - n);
    }
    katz_tap_and_scale(d, stream, len);
}

/* Shared by both open paths: substitute the callback in a copy of desired. */
static katz_dev *katz_prepare(const SDL_AudioSpec *desired, SDL_AudioSpec *copy)
{
    katz_dev *d = katz_alloc();
    if (!d) {
        return NULL;
    }
    *copy = *desired;
    d->app_cb = (void *)desired->callback;
    d->app_ud = desired->userdata;
    d->queue_mode = desired->callback == NULL;
    if (d->queue_mode) {
        d->qcap = 4u << 20;
        d->q = malloc(d->qcap);
        copy->callback = katz_drain;
    } else {
        copy->callback = katz_trampoline;
    }
    copy->userdata = d;
    return d;
}

static void katz_record_spec(katz_dev *d, SDL_AudioDeviceID id, const SDL_AudioSpec *spec)
{
    d->devid = id;
    d->format = spec->format;
    d->channels = spec->channels;
    d->freq = spec->freq;
}

SDL_AudioDeviceID SDL_OpenAudioDevice(const char *device, int iscapture, const SDL_AudioSpec *desired,
                                      SDL_AudioSpec *obtained, int allowed_changes)
{
    REAL(SDL_OpenAudioDevice);
    katz_log("SDL_OpenAudioDevice(device=%s, iscapture=%d, freq=%d fmt=0x%04x ch=%d samples=%d cb=%p, obtained=%p, allowed=0x%x)",
             device ? device : "NULL", iscapture, desired ? desired->freq : 0, desired ? desired->format : 0,
             desired ? desired->channels : 0, desired ? desired->samples : 0, desired ? (void *)desired->callback : NULL,
             (void *)obtained, allowed_changes);
    if (iscapture || !desired) {
        return real_SDL_OpenAudioDevice(device, iscapture, desired, obtained, allowed_changes);
    }
    SDL_AudioSpec copy;
    katz_dev *d = katz_prepare(desired, &copy);
    if (!d) {
        return real_SDL_OpenAudioDevice(device, iscapture, desired, obtained, allowed_changes);
    }
    SDL_AudioDeviceID id = real_SDL_OpenAudioDevice(device, iscapture, &copy, obtained, allowed_changes);
    if (id == 0) {
        katz_log("  real open failed: %s", SDL_GetError());
        katz_release(d);
        return 0;
    }
    /* With obtained == NULL, SDL2 changes nothing, so desired is the format. */
    katz_record_spec(d, id, obtained ? obtained : &copy);
    katz_log("  -> id=%u seq=%d obtained freq=%d fmt=0x%04x ch=%d samples=%d size=%u queue_mode=%d", id, d->seq,
             d->freq, d->format, d->channels, obtained ? obtained->samples : copy.samples,
             obtained ? obtained->size : copy.size, d->queue_mode);
    return id;
}

int SDL_OpenAudio(SDL_AudioSpec *desired, SDL_AudioSpec *obtained)
{
    REAL(SDL_OpenAudio);
    katz_log("SDL_OpenAudio(freq=%d fmt=0x%04x ch=%d samples=%d cb=%p, obtained=%p)", desired->freq, desired->format,
             desired->channels, desired->samples, (void *)desired->callback, (void *)obtained);
    SDL_AudioSpec copy;
    katz_dev *d = katz_prepare(desired, &copy);
    if (!d) {
        return real_SDL_OpenAudio(desired, obtained);
    }
    int rc = real_SDL_OpenAudio(&copy, obtained);
    if (rc < 0) {
        katz_release(d);
        return rc;
    }
    if (!obtained) {
        /* SDL_OpenAudio writes size and silence back into desired when
         * obtained is NULL; it wrote them into our copy, so forward them. */
        desired->size = copy.size;
        desired->silence = copy.silence;
    }
    katz_record_spec(d, 1, obtained ? obtained : &copy);
    katz_log("  -> legacy id=1 seq=%d freq=%d fmt=0x%04x ch=%d", d->seq, d->freq, d->format, d->channels);
    return rc;
}

int SDL_QueueAudio(SDL_AudioDeviceID dev, const void *data, Uint32 len)
{
    katz_dev *d = katz_find(dev);
    if (!d || !d->queue_mode) {
        REAL(SDL_QueueAudio);
        katz_log("SDL_QueueAudio(dev=%u) passthrough", dev);
        return real_SDL_QueueAudio(dev, data, len);
    }
    pthread_mutex_lock(&d->qlock);
    if (d->qlen + len > d->qcap) {
        /* grow on the app thread, never on the audio thread */
        size_t ncap = d->qcap * 2;
        while (d->qlen + len > ncap) ncap *= 2;
        uint8_t *nq = malloc(ncap);
        for (size_t i = 0; i < d->qlen; i++) nq[i] = d->q[(d->qhead + i) % d->qcap];
        free(d->q);
        d->q = nq;
        d->qcap = ncap;
        d->qhead = 0;
    }
    for (Uint32 i = 0; i < len; i++) {
        d->q[(d->qhead + d->qlen + i) % d->qcap] = ((const uint8_t *)data)[i];
    }
    d->qlen += len;
    pthread_mutex_unlock(&d->qlock);
    return 0;
}

Uint32 SDL_GetQueuedAudioSize(SDL_AudioDeviceID dev)
{
    katz_dev *d = katz_find(dev);
    if (!d || !d->queue_mode) {
        REAL(SDL_GetQueuedAudioSize);
        return real_SDL_GetQueuedAudioSize(dev);
    }
    pthread_mutex_lock(&d->qlock);
    Uint32 n = (Uint32)d->qlen;
    pthread_mutex_unlock(&d->qlock);
    return n;
}

void SDL_ClearQueuedAudio(SDL_AudioDeviceID dev)
{
    katz_dev *d = katz_find(dev);
    katz_log("SDL_ClearQueuedAudio(dev=%u)", dev);
    if (!d || !d->queue_mode) {
        REAL(SDL_ClearQueuedAudio);
        real_SDL_ClearQueuedAudio(dev);
        return;
    }
    pthread_mutex_lock(&d->qlock);
    d->qlen = 0;
    d->qhead = 0;
    pthread_mutex_unlock(&d->qlock);
}

void SDL_PauseAudioDevice(SDL_AudioDeviceID dev, int pause_on)
{
    REAL(SDL_PauseAudioDevice);
    katz_log("SDL_PauseAudioDevice(dev=%u, pause_on=%d)", dev, pause_on);
    real_SDL_PauseAudioDevice(dev, pause_on);
}

void SDL_PauseAudio(int pause_on)
{
    REAL(SDL_PauseAudio);
    katz_log("SDL_PauseAudio(pause_on=%d)", pause_on);
    real_SDL_PauseAudio(pause_on);
}

void SDL_CloseAudioDevice(SDL_AudioDeviceID dev)
{
    REAL(SDL_CloseAudioDevice);
    katz_log("SDL_CloseAudioDevice(dev=%u)", dev);
    real_SDL_CloseAudioDevice(dev);
    katz_dev *d = katz_find(dev);
    if (d) {
        katz_release(d);
    }
}

void SDL_CloseAudio(void)
{
    REAL(SDL_CloseAudio);
    katz_log("SDL_CloseAudio()");
    real_SDL_CloseAudio();
    katz_dev *d = katz_find(1);
    if (d) {
        katz_release(d);
    }
}
