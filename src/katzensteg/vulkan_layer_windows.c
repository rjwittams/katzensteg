#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <psapi.h>

#include "vulkan_layer_os.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define KS_MAX_MODULES 1024

void *ks_layer_os_global_symbol(const char *name)
{
    /* Windows has no global symbol namespace; search the loaded modules in
       load order, as dlsym(RTLD_DEFAULT) would. */
    HMODULE modules[KS_MAX_MODULES];
    DWORD needed = 0;
    if (!K32EnumProcessModules(GetCurrentProcess(), modules, sizeof(modules), &needed)) return NULL;
    DWORD count = needed / sizeof(HMODULE);
    if (count > KS_MAX_MODULES) count = KS_MAX_MODULES;
    for (DWORD i = 0; i < count; i++) {
        FARPROC symbol = GetProcAddress(modules[i], name);
        if (symbol) return (void *)symbol;
    }
    return NULL;
}

void *ks_layer_os_open(const char *path)
{
    return (void *)LoadLibraryA(path);
}

void *ks_layer_os_symbol(void *library, const char *name)
{
    return (void *)GetProcAddress((HMODULE)library, name);
}

const char *ks_layer_os_error(char *buffer, size_t capacity)
{
    snprintf(buffer, capacity, "Win32 error %lu", (unsigned long)GetLastError());
    return buffer;
}

bool ks_layer_os_own_directory(char *buffer, size_t capacity)
{
    HMODULE self = NULL;
    if (!GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                            (LPCSTR)(const void *)&ks_layer_os_own_directory, &self))
        return false;
    if (capacity > MAXDWORD) capacity = MAXDWORD;
    const DWORD len = GetModuleFileNameA(self, buffer, (DWORD)capacity);
    if (len == 0 || len >= capacity) return false;
    char *slash = strrchr(buffer, '\\');
    char *forward = strrchr(buffer, '/');
    if (forward > slash) slash = forward;
    if (!slash) return false;
    *slash = '\0';
    return true;
}

/* Child processes inherit the Win32 environment block, which is also what the
   Vulkan loader reads, so read and write that; keep this module's C runtime
   copy in step for getenv. A NULL value removes the variable. */
static void set_process_env(const char *name, const char *value)
{
    SetEnvironmentVariableA(name, value);
    _putenv_s(name, value ? value : "");
}

void ks_layer_os_scrub_list_env(const char *name, const char *entry)
{
    if (!name || !*name || !entry || !*entry) return;
    const DWORD needed = GetEnvironmentVariableA(name, NULL, 0);
    if (needed <= 1) return;
    char *value = malloc(needed);
    char *next = malloc(needed);
    if (!value || !next || GetEnvironmentVariableA(name, value, needed) >= needed) {
        free(value);
        free(next);
        return;
    }

    const size_t entry_len = strlen(entry);
    size_t write = 0;
    bool removed = false;
    const char *segment = value;
    for (;;) {
        const char *end = strchr(segment, ';');
        const size_t len = end ? (size_t)(end - segment) : strlen(segment);
        if (len == entry_len && strncmp(segment, entry, len) == 0) {
            removed = true;
        } else if (len > 0) {
            if (write > 0) next[write++] = ';';
            memcpy(next + write, segment, len);
            write += len;
        }
        if (!end) break;
        segment = end + 1;
    }
    next[write] = '\0';
    if (removed) set_process_env(name, write > 0 ? next : NULL);
    free(value);
    free(next);
}

void ks_layer_os_unsetenv(const char *name)
{
    set_process_env(name, NULL);
}

int ks_layer_os_strcasecmp(const char *a, const char *b)
{
    return _stricmp(a, b);
}
