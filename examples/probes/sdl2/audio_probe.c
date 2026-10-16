/* SDL2 audio probe: plays a 440 Hz sine (amplitude 0.5, 48 kHz stereo)
 * through one SDL2 audio model, then exits.
 *
 * usage: katzensteg-audio-probe callback|queue|legacy [--f32] [--reopen] [--reopen-f32] [--secs S] [--samples N]
 *   callback  SDL_OpenAudioDevice with an app callback
 *   queue     SDL_OpenAudioDevice with callback NULL, fed with SDL_QueueAudio
 *             and paced on SDL_GetQueuedAudioSize
 *   legacy    SDL_OpenAudio (device 1) with an app callback
 *   --reopen  close the device halfway and reopen it with half the buffer
 *             size (as Flycast does on timing changes). With the disk driver
 *             the second segment goes to $SDL_DISKAUDIOFILE.seg2, because
 *             reopening truncates the first file.
 *   --reopen-f32  as --reopen, reopening in F32 (a format change)
 * Default format S16 (AUDIO_S16SYS), --f32 for AUDIO_F32SYS.
 *
 * The tone constants live in examples/probes/common/audio_tone.h. */
#include <SDL.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "audio_tone.h"

static tone_state tone;
static int use_f32;
static int cb_calls;

static void SDLCALL app_callback(void *ud, Uint8 *stream, int len)
{
    (void)ud;
    cb_calls++;
    tone_fill(&tone, stream, len, use_f32, TONE_CHANNELS);
}

static SDL_AudioDeviceID open_dev(const char *mode, int samples, SDL_AudioSpec *obtained)
{
    SDL_AudioSpec want;
    SDL_zero(want);
    want.freq = TONE_RATE;
    want.format = use_f32 ? AUDIO_F32SYS : AUDIO_S16SYS;
    want.channels = TONE_CHANNELS;
    want.samples = (Uint16)samples;
    want.callback = strcmp(mode, "queue") == 0 ? NULL : app_callback;
    if (strcmp(mode, "legacy") == 0) {
        /* Without an obtained spec SDL converts from the requested format,
         * which the callback writes, and fills in want's buffer size. */
        if (SDL_OpenAudio(&want, NULL) < 0) {
            fprintf(stderr, "SDL_OpenAudio: %s\n", SDL_GetError());
            return 0;
        }
        *obtained = want;
        return 1;
    }
    /* allowed_changes 0: SDL converts from the requested format. */
    SDL_AudioDeviceID id = SDL_OpenAudioDevice(NULL, 0, &want, obtained, 0);
    if (!id) {
        fprintf(stderr, "SDL_OpenAudioDevice: %s\n", SDL_GetError());
    }
    return id;
}

static int run_segment(const char *mode, SDL_AudioDeviceID id, double secs)
{
    if (strcmp(mode, "legacy") == 0) {
        SDL_PauseAudio(0);
    } else {
        SDL_PauseAudioDevice(id, 0);
    }
    if (strcmp(mode, "queue") != 0) {
        SDL_Delay((Uint32)(secs * 1000));
        return 0;
    }
    const int frame_bytes = TONE_CHANNELS * (use_f32 ? 4 : 2);
    enum { CHUNK_FRAMES = 1024, QUEUED_CHUNKS = 8 };
    const Uint64 total = (Uint64)(secs * TONE_RATE);
    Uint64 queued = 0;
    static Uint8 buf[CHUNK_FRAMES * TONE_CHANNELS * 4];
    while (queued < total) {
        if (SDL_GetQueuedAudioSize(id) < (Uint32)(QUEUED_CHUNKS * CHUNK_FRAMES * frame_bytes)) {
            int n = CHUNK_FRAMES;
            if (queued + (Uint64)n > total) n = (int)(total - queued);
            tone_fill(&tone, buf, n * frame_bytes, use_f32, TONE_CHANNELS);
            if (SDL_QueueAudio(id, buf, (Uint32)(n * frame_bytes)) < 0) {
                fprintf(stderr, "SDL_QueueAudio: %s\n", SDL_GetError());
                return -1;
            }
            queued += (Uint64)n;
        } else {
            SDL_Delay(1);
        }
    }
    while (SDL_GetQueuedAudioSize(id) > 0) {
        SDL_Delay(1);
    }
    SDL_Delay(50); /* let the last buffer reach the device */
    return 0;
}

int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "callback";
    if (strcmp(mode, "callback") != 0 && strcmp(mode, "queue") != 0 && strcmp(mode, "legacy") != 0) {
        fprintf(stderr, "usage: %s callback|queue|legacy [--f32] [--reopen] [--reopen-f32] [--secs S] [--samples N]\n", argv[0]);
        return 2;
    }
    int reopen = 0;
    double secs = 2.0;
    int samples = 1024;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--f32")) use_f32 = 1;
        else if (!strcmp(argv[i], "--reopen")) reopen = 1;
        else if (!strcmp(argv[i], "--reopen-f32")) reopen = 2;
        else if (!strcmp(argv[i], "--secs") && i + 1 < argc) secs = atof(argv[++i]);
        else if (!strcmp(argv[i], "--samples") && i + 1 < argc) samples = atoi(argv[++i]);
        else {
            fprintf(stderr, "unknown argument: %s\n", argv[i]);
            return 2;
        }
    }
    SDL_version linked;
    SDL_GetVersion(&linked);
    if (SDL_Init(SDL_INIT_AUDIO) < 0) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        return 1;
    }
    printf("audio-probe sdl2 mode=%s fmt=%s reopen=%d linked SDL %d.%d.%d driver=%s\n", mode, use_f32 ? "F32" : "S16",
           reopen, linked.major, linked.minor, linked.patch, SDL_GetCurrentAudioDriver());
    const int segments = reopen ? 2 : 1;
    for (int seg = 0; seg < segments; seg++) {
        if (seg == 1) {
            const char *base = SDL_getenv("SDL_DISKAUDIOFILE");
            if (base) {
                char path[1024];
                snprintf(path, sizeof(path), "%s.seg2", base);
                /* Classic SDL2 reads the variable; sdl2-compat reads the hint. */
                SDL_setenv("SDL_DISKAUDIOFILE", path, 1);
                SDL_SetHint("SDL_DISKAUDIOFILE", path);
            }
        }
        if (seg == 1 && reopen == 2) use_f32 = 1;
        SDL_AudioSpec have;
        SDL_zero(have);
        const int seg_samples = seg == 0 ? samples : samples / 2;
        SDL_AudioDeviceID id = open_dev(mode, seg_samples, &have);
        if (!id) {
            SDL_Quit();
            return 1;
        }
        printf("seg%d id=%u obtained freq=%d fmt=0x%04x ch=%d samples=%d size=%u\n", seg, id, have.freq, have.format,
               have.channels, have.samples, have.size);
        fflush(stdout);
        const int rc = run_segment(mode, id, secs / segments);
        if (strcmp(mode, "legacy") == 0) {
            SDL_CloseAudio();
        } else {
            SDL_CloseAudioDevice(id);
        }
        if (rc != 0) {
            SDL_Quit();
            return 1;
        }
    }
    printf("done callback_calls=%d tone_frames=%llu\n", cb_calls, (unsigned long long)tone.frames);
    SDL_Quit();
    return 0;
}
