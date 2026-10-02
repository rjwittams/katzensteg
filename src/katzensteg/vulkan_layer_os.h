/* Operating-system services used by the Vulkan capture layer
   (vulkan_layer.c). vulkan_layer_posix.c implements them with dlfcn and the
   POSIX environment; vulkan_layer_windows.c with the Win32 loader and
   environment. */
#ifndef KATZENSTEG_VULKAN_LAYER_OS_H
#define KATZENSTEG_VULKAN_LAYER_OS_H

#include <stdbool.h>
#include <stddef.h>

#if defined(_WIN32)
#define KS_LAYER_EXPORT __declspec(dllexport)
#define KS_LAYER_OS_PATH_SEPARATOR '\\'
#else
#define KS_LAYER_EXPORT __attribute__((visibility("default")))
#define KS_LAYER_OS_PATH_SEPARATOR '/'
#endif

#ifndef KS_LAYER_OS_HIDDEN
#define KS_LAYER_OS_HIDDEN __attribute__((visibility("hidden")))
#endif

/* A symbol exported by any module already loaded in the process, like
   dlsym(RTLD_DEFAULT). This is how the layer finds the Katzensteg runtime
   that the SDL adapter library carries. */
KS_LAYER_OS_HIDDEN void *ks_layer_os_global_symbol(const char *name);

/* Load a library by path or name; NULL on failure. */
KS_LAYER_OS_HIDDEN void *ks_layer_os_open(const char *path);
KS_LAYER_OS_HIDDEN void *ks_layer_os_symbol(void *library, const char *name);

/* The reason the last ks_layer_os_open failed, written into buffer. */
KS_LAYER_OS_HIDDEN const char *ks_layer_os_error(char *buffer, size_t capacity);

/* The directory that holds the layer library, without a trailing separator. */
KS_LAYER_OS_HIDDEN bool ks_layer_os_own_directory(char *buffer, size_t capacity);

/* Remove entry from the list variable name (':'-separated on POSIX,
   ';'-separated on Windows, as the Vulkan loader reads them), so child
   processes do not load the layer. */
KS_LAYER_OS_HIDDEN void ks_layer_os_scrub_list_env(const char *name, const char *entry);
KS_LAYER_OS_HIDDEN void ks_layer_os_unsetenv(const char *name);

KS_LAYER_OS_HIDDEN int ks_layer_os_strcasecmp(const char *a, const char *b);

#endif
