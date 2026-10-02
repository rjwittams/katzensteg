#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "vulkan_layer_os.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

extern void ks_scrub_colon_env_entry(const char *name, const char *entry);

void *ks_layer_os_global_symbol(const char *name)
{
    return dlsym(RTLD_DEFAULT, name);
}

void *ks_layer_os_open(const char *path)
{
    return dlopen(path, RTLD_NOW | RTLD_LOCAL);
}

void *ks_layer_os_symbol(void *library, const char *name)
{
    return dlsym(library, name);
}

const char *ks_layer_os_error(char *buffer, size_t capacity)
{
    const char *error = dlerror();
    snprintf(buffer, capacity, "%s", error ? error : "unknown error");
    return buffer;
}

bool ks_layer_os_own_directory(char *buffer, size_t capacity)
{
    Dl_info info;
    if (dladdr((const void *)&ks_layer_os_own_directory, &info) == 0 || !info.dli_fname) return false;
    const char *slash = strrchr(info.dli_fname, '/');
    if (!slash) return false;
    const int written = snprintf(buffer, capacity, "%.*s", (int)(slash - info.dli_fname), info.dli_fname);
    return written > 0 && (size_t)written < capacity;
}

void ks_layer_os_scrub_list_env(const char *name, const char *entry)
{
    ks_scrub_colon_env_entry(name, entry);
}

void ks_layer_os_unsetenv(const char *name)
{
    unsetenv(name);
}

int ks_layer_os_strcasecmp(const char *a, const char *b)
{
    return strcasecmp(a, b);
}
