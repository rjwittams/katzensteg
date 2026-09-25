/* Shared body of dynapi_sdl2.c and dynapi_sdl3.c: the exported
 * SDL_DYNAPI_entry that wraps the loading SDL's jump table (see dynapi.zig),
 * and the jump-table backend for the ks_real_* functions the runtime calls.
 *
 * The including file defines:
 *   KS_DYNAPI_VERSION   SDL's SDL_DYNAPI_VERSION for its major version
 *   KS_DYNAPI_ENV       the environment variable SDL reads
 *   KS_DYNAPI_SLOT(f)   the jump-table slot of function f
 *   KS_DYNAPI_WRAPPERS  X-macro list of KS_WRAP(f) entries
 *   KS_DYNAPI_REAL      X-macro list of KS_REAL / KS_REAL_VOID entries */

#include <stdio.h>
#include <stdlib.h>

#if defined(_WIN32)
#define KS_DYNAPI_EXPORT __declspec(dllexport)
#else
#define KS_DYNAPI_EXPORT __attribute__((visibility("default")))
#endif

typedef struct {
    unsigned int slot;
    const void *function;
} ks_dynapi_wrapper;

extern int ks_dynapi_install(unsigned int expected_apiver, unsigned int apiver, void *table, unsigned int tablesize,
                             const ks_dynapi_wrapper *wrappers, unsigned int wrapper_count, const void *self_entry,
                             const char *env_name, void *const **real_out, unsigned int *real_count_out);
extern void ks_katzensteg_log_c(const char *, const char *);

/* Only the addresses of the wrappers are taken here; their real prototypes
 * are those of the SDL functions they replace. */
#define KS_WRAP(name) extern void ks_##name(void);
#include KS_DYNAPI_WRAPPERS
#undef KS_WRAP

static const ks_dynapi_wrapper ks_dynapi_wrappers[] = {
#define KS_WRAP(name) {KS_DYNAPI_SLOT(name), (const void *)&ks_##name},
#include KS_DYNAPI_WRAPPERS
#undef KS_WRAP
};

static void *const *ks_dynapi_real;
static unsigned int ks_dynapi_real_count;

KS_DYNAPI_EXPORT int SDL_DYNAPI_entry(unsigned int apiver, void *table, unsigned int tablesize) {
    return ks_dynapi_install(KS_DYNAPI_VERSION, apiver, table, tablesize, ks_dynapi_wrappers,
                             (unsigned int)(sizeof(ks_dynapi_wrappers) / sizeof(ks_dynapi_wrappers[0])),
                             (const void *)&SDL_DYNAPI_entry, KS_DYNAPI_ENV, &ks_dynapi_real, &ks_dynapi_real_count);
}

static void *ks_dynapi_real_slot(const char *name, unsigned int slot) {
    void *function = (ks_dynapi_real && slot < ks_dynapi_real_count) ? ks_dynapi_real[slot] : NULL;
    if (!function) {
        char message[256];
        snprintf(message, sizeof(message), "no real %s in the SDL dynamic API table (slot %u of %u)", name, slot,
                 ks_dynapi_real_count);
        ks_katzensteg_log_c("real_sdl", message);
        abort();
    }
    return function;
}

#define KS_REAL(name, rettype, args, params) \
    rettype ks_real_##name args { \
        typedef rettype (*fn_type) args; \
        return ((fn_type)ks_dynapi_real_slot(#name, KS_DYNAPI_SLOT(name))) params; \
    }

#define KS_REAL_VOID(name, args, params) \
    void ks_real_##name args { \
        typedef void (*fn_type) args; \
        ((fn_type)ks_dynapi_real_slot(#name, KS_DYNAPI_SLOT(name))) params; \
    }

#include KS_DYNAPI_REAL

#if !defined(_WIN32)
#include <dlfcn.h>
/* Only preload builds interpose dlopen; here the runtime's dlopen hook, which
 * nothing routes to, calls the system's directly. */
void *ks_real_dlopen(const char *path, int mode) { return dlopen(path, mode); }
#endif
