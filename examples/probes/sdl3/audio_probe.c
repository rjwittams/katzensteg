/* SDL3 audio probe: plays a 440 Hz sine (amplitude 0.5, 48 kHz stereo)
 * through one SDL3 audio model, then exits.
 *
 * usage: katzensteg-audio-probe-sdl3 bound|devstream|devstream-cb [--s16] [--reopen] [--app-postmix] [--secs S]
 *   bound         SDL_OpenAudioDevice + SDL_CreateAudioStream + SDL_BindAudioStream,
 *                 fed with SDL_PutAudioStreamData
 *   devstream     SDL_OpenAudioDeviceStream without a callback, fed with Put
 *   devstream-cb  SDL_OpenAudioDeviceStream with a get callback
 *   --reopen      tear down halfway and reopen with half the device buffer
 *                 (SDL_HINT_AUDIO_DEVICE_SAMPLE_FRAMES 1024 then 512). With the
 *                 disk driver the second segment goes to
 *                 $SDL_AUDIO_DISK_OUTPUT_FILE.seg2, because reopening truncates
 *                 the first file.
 *   --app-postmix the app installs its own postmix callback after open
 * Default app format F32, --s16 for S16.
 *
 * The tone constants live in examples/probes/common/audio_tone.h. */
#include <SDL3/SDL.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "audio_tone.h"

static tone_state tone;
static int use_s16;
static SDL_AtomicInt cb_calls;
static SDL_AtomicInt app_postmix_calls;

static void SDLCALL get_callback(void *ud, SDL_AudioStream *stream, int additional, int total)
{
    (void)ud;
    (void)total;
    SDL_AddAtomicInt(&cb_calls, 1);
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
    SDL_AddAtomicInt(&app_postmix_calls, 1);
}

static bool feed(SDL_AudioStream *s, double secs)
{
    const int frame_bytes = TONE_CHANNELS * (use_s16 ? 2 : 4);
    enum { CHUNK_FRAMES = 1024, QUEUED_CHUNKS = 8 };
    const Uint64 total = (Uint64)(secs * TONE_RATE);
    Uint64 queued = 0;
    static Uint8 buf[CHUNK_FRAMES * TONE_CHANNELS * 4];
    while (queued < total) {
        if (SDL_GetAudioStreamQueued(s) < QUEUED_CHUNKS * CHUNK_FRAMES * frame_bytes) {
            int n = CHUNK_FRAMES;
            if (queued + (Uint64)n > total) n = (int)(total - queued);
            tone_fill(&tone, buf, n * frame_bytes, !use_s16, TONE_CHANNELS);
            if (!SDL_PutAudioStreamData(s, buf, n * frame_bytes)) {
                fprintf(stderr, "SDL_PutAudioStreamData: %s\n", SDL_GetError());
                return false;
            }
            queued += (Uint64)n;
        } else {
            SDL_Delay(1);
        }
    }
    SDL_FlushAudioStream(s);
    while (SDL_GetAudioStreamQueued(s) > 0) {
        SDL_Delay(1);
    }
    SDL_Delay(50); /* let the last buffer reach the device */
    return true;
}

int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "bound";
    if (strcmp(mode, "bound") != 0 && strcmp(mode, "devstream") != 0 && strcmp(mode, "devstream-cb") != 0) {
        fprintf(stderr, "usage: %s bound|devstream|devstream-cb [--s16] [--reopen] [--app-postmix] [--secs S]\n",
                argv[0]);
        return 2;
    }
    int reopen = 0, want_postmix = 0;
    double secs = 2.0;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--s16")) use_s16 = 1;
        else if (!strcmp(argv[i], "--reopen")) reopen = 1;
        else if (!strcmp(argv[i], "--app-postmix")) want_postmix = 1;
        else if (!strcmp(argv[i], "--secs") && i + 1 < argc) secs = atof(argv[++i]);
        else {
            fprintf(stderr, "unknown argument: %s\n", argv[i]);
            return 2;
        }
    }
    if (!SDL_Init(SDL_INIT_AUDIO)) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        return 1;
    }
    const int v = SDL_GetVersion();
    printf("audio-probe sdl3 mode=%s fmt=%s reopen=%d linked SDL %d.%d.%d driver=%s\n", mode, use_s16 ? "S16" : "F32",
           reopen, SDL_VERSIONNUM_MAJOR(v), SDL_VERSIONNUM_MINOR(v), SDL_VERSIONNUM_MICRO(v),
           SDL_GetCurrentAudioDriver());
    const SDL_AudioSpec spec = { use_s16 ? SDL_AUDIO_S16 : SDL_AUDIO_F32, TONE_CHANNELS, TONE_RATE };
    const int segments = reopen ? 2 : 1;
    for (int seg = 0; seg < segments; seg++) {
        SDL_SetHint(SDL_HINT_AUDIO_DEVICE_SAMPLE_FRAMES, seg == 0 ? "1024" : "512");
        if (seg == 1) {
            const char *base = SDL_GetHint(SDL_HINT_AUDIO_DISK_OUTPUT_FILE);
            if (base) {
                char path[1024];
                snprintf(path, sizeof(path), "%s.seg2", base);
                /* An environment variable outranks a normal-priority hint. */
                SDL_SetHintWithPriority(SDL_HINT_AUDIO_DISK_OUTPUT_FILE, path, SDL_HINT_OVERRIDE);
            }
        }
        SDL_AudioDeviceID dev = 0;
        SDL_AudioStream *s = NULL;
        if (!strcmp(mode, "bound")) {
            dev = SDL_OpenAudioDevice(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec);
            s = dev ? SDL_CreateAudioStream(&spec, NULL) : NULL;
            if (!s || !SDL_BindAudioStream(dev, s)) {
                fprintf(stderr, "bound open: %s\n", SDL_GetError());
                SDL_Quit();
                return 1;
            }
        } else {
            s = SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec,
                                          !strcmp(mode, "devstream-cb") ? get_callback : NULL, NULL);
            if (!s) {
                fprintf(stderr, "SDL_OpenAudioDeviceStream: %s\n", SDL_GetError());
                SDL_Quit();
                return 1;
            }
            dev = SDL_GetAudioStreamDevice(s);
        }
        SDL_AudioSpec devspec;
        int frames = 0;
        SDL_GetAudioDeviceFormat(dev, &devspec, &frames);
        printf("seg%d logical=%u device fmt=0x%04x ch=%d freq=%d frames=%d\n", seg, dev, devspec.format,
               devspec.channels, devspec.freq, frames);
        fflush(stdout);
        if (want_postmix && !SDL_SetAudioPostmixCallback(dev, app_postmix, NULL)) {
            fprintf(stderr, "SDL_SetAudioPostmixCallback: %s\n", SDL_GetError());
        }
        if (strcmp(mode, "bound") != 0) {
            SDL_ResumeAudioStreamDevice(s);
        }
        bool ok = true;
        if (!strcmp(mode, "devstream-cb")) {
            SDL_Delay((Uint32)(secs / segments * 1000));
        } else {
            ok = feed(s, secs / segments);
        }
        if (!strcmp(mode, "bound")) {
            SDL_CloseAudioDevice(dev);
            SDL_DestroyAudioStream(s);
        } else {
            SDL_DestroyAudioStream(s); /* closes the simplified device inside SDL */
        }
        if (!ok) {
            SDL_Quit();
            return 1;
        }
    }
    printf("done get_callback_calls=%d app_postmix_calls=%d tone_frames=%llu\n", SDL_GetAtomicInt(&cb_calls),
           SDL_GetAtomicInt(&app_postmix_calls), (unsigned long long)tone.frames);
    SDL_Quit();
    return 0;
}
