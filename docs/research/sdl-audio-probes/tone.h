/* Shared tone generator for the SDL audio probes: a continuous-phase sine
 * written as interleaved S16 or F32 frames. */
#ifndef KATZ_PROBE_TONE_H
#define KATZ_PROBE_TONE_H

#include <math.h>
#include <stdint.h>
#include <string.h>

#define TONE_FREQ 440.0
#define TONE_AMPLITUDE 0.5 /* of full scale */
#define TONE_RATE 48000
#define TONE_CHANNELS 2

typedef struct {
    double phase; /* radians */
    uint64_t frames;
} tone_state;

/* is_float: 1 for F32, 0 for S16 (native endian). */
static inline void tone_fill(tone_state *t, void *dst, int bytes, int is_float, int channels)
{
    const double step = 2.0 * M_PI * TONE_FREQ / TONE_RATE;
    const int frame_bytes = channels * (is_float ? 4 : 2);
    const int frames = bytes / frame_bytes;
    for (int i = 0; i < frames; i++) {
        const double v = TONE_AMPLITUDE * sin(t->phase);
        t->phase += step;
        if (t->phase > 2.0 * M_PI) {
            t->phase -= 2.0 * M_PI;
        }
        for (int c = 0; c < channels; c++) {
            if (is_float) {
                ((float *)dst)[i * channels + c] = (float)v;
            } else {
                ((int16_t *)dst)[i * channels + c] = (int16_t)lrint(v * 32767.0);
            }
        }
    }
    t->frames += (uint64_t)frames;
    if (bytes > frames * frame_bytes) {
        memset((uint8_t *)dst + frames * frame_bytes, 0, (size_t)(bytes - frames * frame_bytes));
    }
}

#endif
