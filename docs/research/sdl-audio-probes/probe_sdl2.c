/* SDL2 audio probe: plays a 440 Hz sine (amplitude 0.5, 48 kHz stereo).
 *
 * usage: probe_sdl2 callback|queue|legacy [--f32] [--reopen] [--secs S] [--samples N]
 *   callback  SDL_OpenAudioDevice with an app callback
 *   queue     SDL_OpenAudioDevice with callback NULL, paced on SDL_GetQueuedAudioSize
 *   legacy    SDL_OpenAudio (device 1) with an app callback
 *   --reopen  close the device halfway and reopen it with half the buffer
 *             size (as Flycast does on timing changes); the second segment's
 *             disk output goes to $SDL_DISKAUDIOFILE.seg2
 * Default format S16 (AUDIO_S16SYS), --f32 for AUDIO_F32SYS. */
#include <SDL.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

#include "tone.h"

static tone_state tone;
static int use_f32;
static long cb_tid;
static int cb_calls;

static void SDLCALL app_callback(void *ud, Uint8 *stream, int len)
{
    (void)ud;
    if (!cb_tid) {
        cb_tid = (long)syscall(SYS_gettid);
    }
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
        if (SDL_OpenAudio(&want, obtained) < 0) {
            fprintf(stderr, "SDL_OpenAudio: %s\n", SDL_GetError());
            return 0;
        }
        return 1;
    }
    SDL_AudioDeviceID id = SDL_OpenAudioDevice(NULL, 0, &want, obtained, 0);
    if (!id) {
        fprintf(stderr, "SDL_OpenAudioDevice: %s\n", SDL_GetError());
    }
    return id;
}

static void run_segment(const char *mode, SDL_AudioDeviceID id, double secs)
{
    const int is_legacy = strcmp(mode, "legacy") == 0;
    if (is_legacy) {
        SDL_PauseAudio(0);
    } else {
        SDL_PauseAudioDevice(id, 0);
    }
    if (strcmp(mode, "queue") == 0) {
        const int frame_bytes = TONE_CHANNELS * (use_f32 ? 4 : 2);
        const int chunk_frames = 1024;
        const Uint64 total = (Uint64)(secs * TONE_RATE);
        Uint64 queued = 0;
        static Uint8 buf[1024 * 8];
        while (queued < total) {
            if (SDL_GetQueuedAudioSize(id) < (Uint32)(4 * chunk_frames * frame_bytes)) {
                int n = chunk_frames;
                if (queued + (Uint64)n > total) n = (int)(total - queued);
                tone_fill(&tone, buf, n * frame_bytes, use_f32, TONE_CHANNELS);
                SDL_QueueAudio(id, buf, (Uint32)(n * frame_bytes));
                queued += (Uint64)n;
            } else {
                SDL_Delay(1);
            }
        }
        while (SDL_GetQueuedAudioSize(id) > 0) {
            SDL_Delay(1);
        }
        SDL_Delay(50); /* let the last buffer reach the device */
    } else {
        SDL_Delay((Uint32)(secs * 1000));
    }
}

int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "callback";
    int reopen = 0;
    double secs = 2.0;
    int samples = 1024;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--f32")) use_f32 = 1;
        else if (!strcmp(argv[i], "--reopen")) reopen = 1;
        else if (!strcmp(argv[i], "--secs") && i + 1 < argc) secs = atof(argv[++i]);
        else if (!strcmp(argv[i], "--samples") && i + 1 < argc) samples = atoi(argv[++i]);
    }
    SDL_version linked;
    SDL_GetVersion(&linked);
    if (SDL_Init(SDL_INIT_AUDIO) < 0) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        return 1;
    }
    printf("probe_sdl2 mode=%s fmt=%s reopen=%d linked SDL %d.%d.%d driver=%s main_tid=%ld\n", mode,
           use_f32 ? "F32" : "S16", reopen, linked.major, linked.minor, linked.patch, SDL_GetCurrentAudioDriver(),
           (long)syscall(SYS_gettid));
    const int segments = reopen ? 2 : 1;
    for (int seg = 0; seg < segments; seg++) {
        if (seg == 1) {
            const char *base = getenv("SDL_DISKAUDIOFILE");
            if (base) {
                char path[1024];
                snprintf(path, sizeof(path), "%s.seg2", base);
                SDL_setenv("SDL_DISKAUDIOFILE", path, 1);
                SDL_SetHint("SDL_DISKAUDIOFILE", path);
            }
        }
        SDL_AudioSpec have;
        SDL_zero(have);
        const int seg_samples = seg == 0 ? samples : samples / 2;
        SDL_AudioDeviceID id = open_dev(mode, seg_samples, &have);
        if (!id) {
            return 1;
        }
        printf("seg%d id=%u obtained freq=%d fmt=0x%04x ch=%d samples=%d size=%u\n", seg, id, have.freq, have.format,
               have.channels, have.samples, have.size);
        run_segment(mode, id, secs / segments);
        if (strcmp(mode, "legacy") == 0) {
            SDL_CloseAudio();
        } else {
            SDL_CloseAudioDevice(id);
        }
    }
    printf("app callback calls=%d cb_tid=%ld tone_frames=%llu\n", cb_calls, cb_tid, (unsigned long long)tone.frames);
    SDL_Quit();
    return 0;
}
