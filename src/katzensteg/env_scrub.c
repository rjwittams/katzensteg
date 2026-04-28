#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <dlfcn.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef KS_ENV_SCRUB_API
#define KS_ENV_SCRUB_API __attribute__((visibility("hidden")))
#endif

static int entry_equals(const char *start, size_t len, const char *entry) {
    return strlen(entry) == len && strncmp(start, entry, len) == 0;
}

KS_ENV_SCRUB_API void ks_scrub_colon_env_entry(const char *name, const char *entry) {
    if (!name || !*name || !entry || !*entry) return;

    const char *value = getenv(name);
    if (!value || !*value) return;

    const size_t value_len = strlen(value);
    char *next = malloc(value_len + 1);
    if (!next) return;

    size_t write = 0;
    const char *segment = value;
    int removed = 0;
    while (1) {
        const char *end = strchr(segment, ':');
        const size_t len = end ? (size_t)(end - segment) : strlen(segment);
        if (len > 0 && entry_equals(segment, len, entry)) {
            removed = 1;
        } else if (len > 0) {
            if (write > 0) next[write++] = ':';
            memcpy(next + write, segment, len);
            write += len;
        }
        if (!end) break;
        segment = end + 1;
    }
    next[write] = '\0';

    if (removed) {
        if (write == 0) {
            unsetenv(name);
        } else {
            setenv(name, next, 1);
        }
    }
    free(next);
}

KS_ENV_SCRUB_API void ks_scrub_preload_env_for_loaded_symbol(const void *symbol) {
    Dl_info info;
    if (!symbol || dladdr(symbol, &info) == 0 || !info.dli_fname) return;

    ks_scrub_colon_env_entry("LD_PRELOAD", info.dli_fname);
    ks_scrub_colon_env_entry("DYLD_INSERT_LIBRARIES", info.dli_fname);

    char resolved[PATH_MAX];
    if (realpath(info.dli_fname, resolved)) {
        ks_scrub_colon_env_entry("LD_PRELOAD", resolved);
        ks_scrub_colon_env_entry("DYLD_INSERT_LIBRARIES", resolved);
    }
}
