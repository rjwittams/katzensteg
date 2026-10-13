/* Shared state for the experimental audio interposers: per-device records,
 * a preallocated tap buffer, callback timestamps and a file log.
 *
 * Environment:
 *   KATZ_LOG       log file (default /tmp/katz-audio.log)
 *   KATZ_TAP_FILE  tap prefix; each opened device writes <prefix>.<tag><seq>.raw,
 *                  .meta (format) and .cadence (one line per callback)
 *   KATZ_GAIN      linear gain applied after the tap (0 mutes, default 1)
 *
 * The audio thread only memcpy's into preallocated buffers and stores
 * timestamps; files are written after the real close returns or at exit.
 * The log is written from API calls and once per device from the audio
 * thread (first callback), never per buffer. */
#ifndef KATZ_COMMON_H
#define KATZ_COMMON_H

#define _GNU_SOURCE
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#ifndef KATZ_TAG
#define KATZ_TAG "x"
#endif

#define KATZ_MAX_DEV 32
#define KATZ_TAP_BYTES (32u << 20)
#define KATZ_MAX_CB 20000

/* Sample formats the scaler understands (SDL2 and SDL3 share these codes,
 * SDL2 adds U16). */
#define KF_U8 0x0008
#define KF_S8 0x8008
#define KF_U16LSB 0x0010
#define KF_S16LSB 0x8010
#define KF_S32LSB 0x8020
#define KF_F32LSB 0x8120

typedef struct katz_dev {
    int used;
    int seq;
    uint32_t devid;
    int format, channels, freq;
    void *app_cb;
    void *app_ud;
    void *stream; /* SDL3 simplified stream */
    int queue_mode;
    /* queue owned by the SDL2 interposer */
    pthread_mutex_t qlock;
    uint8_t *q;
    size_t qcap, qhead, qlen;
    /* tap */
    uint8_t *tap;
    size_t tap_len;
    /* cadence */
    uint64_t *cb_ns;
    int *cb_len;
    int ncb;
    atomic_long cb_tid;
    int tid_changes;
    int spec_changes;
    int flushed;
} katz_dev;

static katz_dev katz_devs[KATZ_MAX_DEV];
static pthread_mutex_t katz_lock = PTHREAD_MUTEX_INITIALIZER;
static FILE *katz_logf;
static int katz_seq;
static _Atomic float katz_gain = 1.0f;
static uint64_t katz_t0;

static inline uint64_t katz_now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static inline long katz_tid(void) { return (long)syscall(SYS_gettid); }

static void katz_log(const char *fmt, ...)
{
    pthread_mutex_lock(&katz_lock);
    if (!katz_logf) {
        const char *p = getenv("KATZ_LOG");
        katz_logf = fopen(p ? p : "/tmp/katz-audio.log", "a");
    }
    if (katz_logf) {
        va_list ap;
        va_start(ap, fmt);
        fprintf(katz_logf, "[%s %9.3fms tid=%ld] ", KATZ_TAG, (katz_now_ns() - katz_t0) / 1e6, katz_tid());
        vfprintf(katz_logf, fmt, ap);
        fputc('\n', katz_logf);
        fflush(katz_logf);
        va_end(ap);
    }
    pthread_mutex_unlock(&katz_lock);
}

static void katz_init_env(void)
{
    katz_t0 = katz_now_ns();
    const char *g = getenv("KATZ_GAIN");
    if (g) {
        atomic_store(&katz_gain, (float)atof(g));
    }
}

static katz_dev *katz_alloc(void)
{
    pthread_mutex_lock(&katz_lock);
    katz_dev *d = NULL;
    for (int i = 0; i < KATZ_MAX_DEV; i++) {
        if (!katz_devs[i].used) {
            d = &katz_devs[i];
            memset(d, 0, sizeof(*d));
            d->used = 1;
            d->seq = katz_seq++;
            break;
        }
    }
    pthread_mutex_unlock(&katz_lock);
    if (d) {
        pthread_mutex_init(&d->qlock, NULL);
        d->tap = malloc(KATZ_TAP_BYTES);
        d->cb_ns = calloc(KATZ_MAX_CB, sizeof(uint64_t));
        d->cb_len = calloc(KATZ_MAX_CB, sizeof(int));
    }
    return d;
}

static katz_dev *katz_find(uint32_t devid)
{
    for (int i = 0; i < KATZ_MAX_DEV; i++) {
        if (katz_devs[i].used && katz_devs[i].devid == devid) {
            return &katz_devs[i];
        }
    }
    return NULL;
}

static katz_dev *katz_find_stream(void *stream)
{
    for (int i = 0; i < KATZ_MAX_DEV; i++) {
        if (katz_devs[i].used && stream && katz_devs[i].stream == stream) {
            return &katz_devs[i];
        }
    }
    return NULL;
}

static void katz_scale(int format, uint8_t *buf, int len, float g)
{
    if (g == 1.0f) {
        return;
    }
    switch (format) {
    case KF_U8:
        for (int i = 0; i < len; i++) buf[i] = (uint8_t)(128 + (int)((buf[i] - 128) * g));
        break;
    case KF_S8:
        for (int i = 0; i < len; i++) ((int8_t *)buf)[i] = (int8_t)(((int8_t *)buf)[i] * g);
        break;
    case KF_U16LSB:
        for (int i = 0; i < len / 2; i++) ((uint16_t *)buf)[i] = (uint16_t)(32768 + (int)((((uint16_t *)buf)[i] - 32768) * g));
        break;
    case KF_S16LSB:
        for (int i = 0; i < len / 2; i++) ((int16_t *)buf)[i] = (int16_t)(((int16_t *)buf)[i] * g);
        break;
    case KF_S32LSB:
        for (int i = 0; i < len / 4; i++) ((int32_t *)buf)[i] = (int32_t)(((int32_t *)buf)[i] * (double)g);
        break;
    case KF_F32LSB:
        for (int i = 0; i < len / 4; i++) ((float *)buf)[i] *= g;
        break;
    default:
        break; /* unknown: leave alone (an experiment, not production) */
    }
}

/* Audio thread: tap the unscaled buffer, then apply gain in place. */
static void katz_tap_and_scale(katz_dev *d, uint8_t *buf, int len)
{
    long tid = katz_tid();
    long prev = atomic_exchange(&d->cb_tid, tid);
    if (prev == 0) {
        katz_log("dev seq=%d id=%u first audio callback len=%d", d->seq, d->devid, len);
    } else if (prev != tid) {
        d->tid_changes++;
    }
    if (d->ncb < KATZ_MAX_CB) {
        d->cb_ns[d->ncb] = katz_now_ns();
        d->cb_len[d->ncb] = len;
        d->ncb++;
    }
    if (d->tap && d->tap_len + (size_t)len <= KATZ_TAP_BYTES) {
        memcpy(d->tap + d->tap_len, buf, (size_t)len);
        d->tap_len += (size_t)len;
    }
    katz_scale(d->format, buf, len, atomic_load(&katz_gain));
}

static void katz_flush(katz_dev *d)
{
    if (d->flushed) {
        return;
    }
    d->flushed = 1;
    const char *prefix = getenv("KATZ_TAP_FILE");
    if (prefix) {
        char path[1024];
        snprintf(path, sizeof(path), "%s.%s%d.raw", prefix, KATZ_TAG, d->seq);
        FILE *f = fopen(path, "wb");
        if (f) {
            fwrite(d->tap, 1, d->tap_len, f);
            fclose(f);
        }
        snprintf(path, sizeof(path), "%s.%s%d.meta", prefix, KATZ_TAG, d->seq);
        f = fopen(path, "w");
        if (f) {
            fprintf(f, "format=0x%04x channels=%d freq=%d bytes=%zu callbacks=%d tid_changes=%d spec_changes=%d queue_mode=%d\n",
                    d->format, d->channels, d->freq, d->tap_len, d->ncb, d->tid_changes, d->spec_changes, d->queue_mode);
            fclose(f);
        }
        snprintf(path, sizeof(path), "%s.%s%d.cadence", prefix, KATZ_TAG, d->seq);
        f = fopen(path, "w");
        if (f) {
            for (int i = 0; i < d->ncb; i++) {
                fprintf(f, "%llu %d\n", (unsigned long long)d->cb_ns[i], d->cb_len[i]);
            }
            fclose(f);
        }
    }
    katz_log("dev seq=%d id=%u flushed tap=%zu bytes callbacks=%d cb_tid=%ld tid_changes=%d spec_changes=%d",
             d->seq, d->devid, d->tap_len, d->ncb, (long)atomic_load(&d->cb_tid), d->tid_changes, d->spec_changes);
}

static void katz_release(katz_dev *d)
{
    katz_flush(d);
    free(d->tap);
    free(d->cb_ns);
    free(d->cb_len);
    free(d->q);
    pthread_mutex_lock(&katz_lock);
    d->used = 0;
    pthread_mutex_unlock(&katz_lock);
}

__attribute__((destructor)) static void katz_fini(void)
{
    for (int i = 0; i < KATZ_MAX_DEV; i++) {
        if (katz_devs[i].used && !katz_devs[i].flushed) {
            katz_log("dev seq=%d id=%u still open at exit (no visible close)", katz_devs[i].seq, katz_devs[i].devid);
            katz_flush(&katz_devs[i]);
        }
    }
}

#endif
