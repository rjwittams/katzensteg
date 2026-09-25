#if defined(__linux__)

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

extern void ks_katzensteg_log_c(const char *, const char *);

static void ks_log_symbol_failure(const char *name, const char *err) {
    char message[512];
    snprintf(message, sizeof(message), "failed to resolve real %s: %s", name, err ? err : "unknown error");
    ks_katzensteg_log_c("real_sdl", message);
}

static void *ks_required_symbol(const char *name) {
    dlerror();
    void *symbol = dlsym(RTLD_NEXT, name);
    if (!symbol) {
        const char *err = dlerror();
        ks_log_symbol_failure(name, err);
        abort();
    }
    return symbol;
}

#define KS_REAL(name, rettype, args, params) \
    rettype ks_real_##name args { \
        typedef rettype (*fn_type) args; \
        static fn_type real_fn; \
        if (!real_fn) real_fn = (fn_type)ks_required_symbol(#name); \
        return real_fn params; \
    }

#define KS_REAL_VOID(name, args, params) \
    void ks_real_##name args { \
        typedef void (*fn_type) args; \
        static fn_type real_fn; \
        if (!real_fn) real_fn = (fn_type)ks_required_symbol(#name); \
        real_fn params; \
    }

#include "real_sdl2_functions.h"

KS_REAL(dlopen, void *, (const char *path, int mode), (path, mode))

#endif
