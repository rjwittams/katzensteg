/* SDL3 audio probe: plays a 440 Hz sine (amplitude 0.5, 48 kHz stereo).
 *
 * usage: probe_sdl3 bound|devstream|devstream-cb [--s16] [--reopen] [--app-postmix] [--secs S]
 *   bound         SDL_OpenAudioDevice + SDL_CreateAudioStream + SDL_BindAudioStream,
 *                 fed with SDL_PutAudioStreamData
 *   devstream     SDL_OpenAudioDeviceStream without a callback, fed with Put
 *   devstream-cb  SDL_OpenAudioDeviceStream with a get callback
 *   --reopen      tear down halfway and reopen with half the device buffer
 *                 (SDL_HINT_AUDIO_DEVICE_SAMPLE_FRAMES 1024 then 512); the second
 *                 segment's disk output goes to $SDL_AUDIO_DISK_OUTPUT_FILE.seg2
 *   --app-postmix the app installs its own postmix (counts calls) after open
 * Default app format F32, --s16 for S16. */
#include <SDL3/SDL.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

#include "tone.h"

static tone_state tone;
static int use_s16;
static long cb_tid;
static int cb_calls;
static int app_postmix_calls;
static long app_postmix_tid;

static void SDLCALL get_callback(void *ud, SDL_AudioStream *stream, int additional, int total)
{
    (void)ud;
    (void)total;
    if (!cb_tid) {
        cb_tid = (long)syscall(SYS_gettid);
    }
    cb_calls++;
    const int frame_bytes = TONE_CHANNELS * (use_s16 ? 2 : 4);
    static Uint8 buf[1 << 16];
    while (additional > 0) {
        int n = additional < (int)sizeof(buf) ? additional : (int)sizeof(buf);
        n -= n % frame_bytes;
        if (n <= 0) n = frame_bytes;
        tone_fill(&tone, buf, n, !use_s16, TONE_CHANNELS);
        SDL_PutAudioStreamData(stream, buf, n);
        additional -= n;
    }
}

static void SDLCALL app_postmix(void *ud, const SDL_AudioSpec *spec, float *buffer, int buflen)
{
    (void)ud;
    (void)spec;
    (void)buffer;
    (void)buflen;
    if (!app_postmix_tid) {
        app_postmix_tid = (long)syscall(SYS_gettid);
    }
    app_postmix_calls++;
}

static void feed(SDL_AudioStream *s, double secs)
{
    const int frame_bytes = TONE_CHANNELS * (use_s16 ? 2 : 4);
    const int chunk_frames = 1024;
    const Uint64 total = (Uint64)(secs * TONE_RATE);
    Uint64 queued = 0;
    static Uint8 buf[1024 * 8];
    while (queued < total) {
        if (SDL_GetAudioStreamQueued(s) < 4 * chunk_frames * frame_bytes) {
            int n = chunk_frames;
            if (queued + (Uint64)n > total) n = (int)(total - queued);
            tone_fill(&tone, buf, n * frame_bytes, !use_s16, TONE_CHANNELS);
            SDL_PutAudioStreamData(s, buf, n * frame_bytes);
            queued += (Uint64)n;
        } else {
            SDL_Delay(1);
        }
    }
    SDL_FlushAudioStream(s);
    while (SDL_GetAudioStreamQueued(s) > 0) {
        SDL_Delay(1);
    }
    SDL_Delay(50);
}

int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "bound";
    int reopen = 0, want_postmix = 0;
    double secs = 2.0;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--s16")) use_s16 = 1;
        else if (!strcmp(argv[i], "--reopen")) reopen = 1;
        else if (!strcmp(argv[i], "--app-postmix")) want_postmix = 1;
        else if (!strcmp(argv[i], "--secs") && i + 1 < argc) secs = atof(argv[++i]);
    }
    if (!SDL_Init(SDL_INIT_AUDIO)) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        return 1;
    }
    const int v = SDL_GetVersion();
    printf("probe_sdl3 mode=%s fmt=%s reopen=%d linked SDL %d.%d.%d driver=%s main_tid=%ld\n", mode,
           use_s16 ? "S16" : "F32", reopen, SDL_VERSIONNUM_MAJOR(v), SDL_VERSIONNUM_MINOR(v), SDL_VERSIONNUM_MICRO(v),
           SDL_GetCurrentAudioDriver(), (long)syscall(SYS_gettid));
    const SDL_AudioSpec spec = { use_s16 ? SDL_AUDIO_S16 : SDL_AUDIO_F32, TONE_CHANNELS, TONE_RATE };
    const int segments = reopen ? 2 : 1;
    for (int seg = 0; seg < segments; seg++) {
        SDL_SetHint(SDL_HINT_AUDIO_DEVICE_SAMPLE_FRAMES, seg == 0 ? "1024" : "512");
        if (seg == 1) {
            const char *base = getenv("SDL_AUDIO_DISK_OUTPUT_FILE");
            if (base) {
                char path[1024];
                snprintf(path, sizeof(path), "%s.seg2", base);
                SDL_SetHint(SDL_HINT_AUDIO_DISK_OUTPUT_FILE, path);
            }
        }
        SDL_AudioDeviceID dev = 0;
        SDL_AudioStream *s = NULL;
        if (!strcmp(mode, "bound")) {
            dev = SDL_OpenAudioDevice(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec);
            s = dev ? SDL_CreateAudioStream(&spec, NULL) : NULL;
            if (!s || !SDL_BindAudioStream(dev, s)) {
                fprintf(stderr, "bound open: %s\n", SDL_GetError());
                return 1;
            }
        } else {
            s = SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec,
                                          !strcmp(mode, "devstream-cb") ? get_callback : NULL, NULL);
            if (!s) {
                fprintf(stderr, "SDL_OpenAudioDeviceStream: %s\n", SDL_GetError());
                return 1;
            }
            dev = SDL_GetAudioStreamDevice(s);
        }
        SDL_AudioSpec devspec;
        int frames = 0;
        SDL_GetAudioDeviceFormat(dev, &devspec, &frames);
        printf("seg%d logical=%u device fmt=0x%04x ch=%d freq=%d frames=%d\n", seg, dev, devspec.format,
               devspec.channels, devspec.freq, frames);
        if (want_postmix && !SDL_SetAudioPostmixCallback(dev, app_postmix, NULL)) {
            fprintf(stderr, "app SetAudioPostmixCallback: %s\n", SDL_GetError());
        }
        if (strcmp(mode, "bound") != 0) {
            SDL_ResumeAudioStreamDevice(s);
        }
        if (!strcmp(mode, "devstream-cb")) {
            SDL_Delay((Uint32)(secs / segments * 1000));
        } else {
            feed(s, secs / segments);
        }
        if (!strcmp(mode, "bound")) {
            SDL_CloseAudioDevice(dev);
            SDL_DestroyAudioStream(s);
        } else {
            SDL_DestroyAudioStream(s); /* closes the simplified device inside SDL */
        }
    }
    printf("app get-callback calls=%d cb_tid=%ld app_postmix calls=%d tid=%ld tone_frames=%llu\n", cb_calls, cb_tid,
           app_postmix_calls, app_postmix_tid, (unsigned long long)tone.frames);
    SDL_Quit();
    return 0;
}
