#ifndef KATZENSTEG_DLOPEN_MACOS_H
#define KATZENSTEG_DLOPEN_MACOS_H

#include <dlfcn.h>
#include <stdlib.h>

extern void ks_katzensteg_log_c(const char *, const char *);
extern const char *ks_select_dlopen_path(const char *path);

// dyld uses dlopen's return address to identify the caller and its search paths.
// Enter here directly from interposition/rebinding, then discard this frame with
// a guaranteed tail call. Routing through the normal Zig forwarding chain loses
// @loader_path and the caller's LC_RPATH entries, even if the path is unchanged.
void *ks_macos_dlopen(const char *path, int mode) {
    const char *selected = ks_select_dlopen_path(path);
#if defined(KS_DLOPEN_REBIND)
    typedef void *(*fn_type)(const char *, int);
    extern void *ks_real_macos_slot_dlopen;
    fn_type real_fn = (fn_type)ks_real_macos_slot_dlopen;
    if (!real_fn) real_fn = (fn_type)dlsym(RTLD_NEXT, "dlopen");
    if (!real_fn) {
        ks_katzensteg_log_c("loader", "failed to resolve real macOS dlopen");
        abort();
    }
    __attribute__((musttail)) return real_fn(selected, mode);
#else
    // dyld exempts references from the interposing image itself. dlsym can
    // instead return our replacement once interposition is active.
    __attribute__((musttail)) return dlopen(selected, mode);
#endif
}

#endif
