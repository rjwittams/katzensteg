#if defined(__APPLE__)

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

struct SDL_Window;
struct SDL_Renderer;
struct SDL_Texture;
struct SDL_Surface;
struct SDL_Cursor;
struct SDL_Rect;
struct SDL_Point;
struct SDL_FPoint;
struct SDL_FRect;
struct SDL_FColor;
struct SDL_RendererInfo;
struct SDL_Color;
union SDL_Event;

extern void ks_katzensteg_log_c(const char *, const char *);

static void ks_missing_real_symbol(const char *name) {
    char message[512];
    snprintf(message, sizeof(message), "failed to resolve real macOS SDL symbol: %s", name);
    ks_katzensteg_log_c("real_sdl", message);
    abort();
}

static void *ks_resolve_default_symbol(const char *name) {
    dlerror();
    void *symbol = dlsym(RTLD_DEFAULT, name);
    if (!symbol) {
        const char *err = dlerror();
        char message[512];
        snprintf(message, sizeof(message), "dlsym(RTLD_DEFAULT, %s) failed: %s", name, err ? err : "unknown error");
        ks_katzensteg_log_c("real_sdl", message);
    }
    return symbol;
}

#define KS_REAL_SLOT(name) void *ks_real_macos_slot_##name = NULL

#define KS_REAL(name, rettype, args, params) \
    KS_REAL_SLOT(name); \
    rettype ks_real_##name args { \
        typedef rettype (*fn_type) args; \
        fn_type real_fn = (fn_type)ks_real_macos_slot_##name; \
        if (!real_fn) { \
            real_fn = (fn_type)ks_resolve_default_symbol(#name); \
            ks_real_macos_slot_##name = (void *)real_fn; \
        } \
        if (!real_fn) ks_missing_real_symbol(#name); \
        return real_fn params; \
    }

#define KS_REAL_VOID(name, args, params) \
    KS_REAL_SLOT(name); \
    void ks_real_##name args { \
        typedef void (*fn_type) args; \
        fn_type real_fn = (fn_type)ks_real_macos_slot_##name; \
        if (!real_fn) { \
            real_fn = (fn_type)ks_resolve_default_symbol(#name); \
            ks_real_macos_slot_##name = (void *)real_fn; \
        } \
        if (!real_fn) ks_missing_real_symbol(#name); \
        real_fn params; \
    }

KS_REAL(SDL_Init, _Bool, (unsigned int flags), (flags))
KS_REAL(SDL_InitSubSystem, _Bool, (unsigned int flags), (flags))
KS_REAL(SDL_SetHint, _Bool, (const char *name, const char *value), (name, value))
KS_REAL_VOID(SDL_QuitSubSystem, (unsigned int flags), (flags))
KS_REAL_VOID(SDL_Quit, (void), ())
KS_REAL(SDL_CreateWindow, struct SDL_Window *, (const char *title, int w, int h, unsigned long long flags), (title, w, h, flags))
KS_REAL(SDL_GetWindowID, unsigned int, (struct SDL_Window *window), (window))
KS_REAL(SDL_GetWindowFlags, unsigned long long, (struct SDL_Window *window), (window))
KS_REAL(SDL_SetWindowSize, _Bool, (struct SDL_Window *window, int w, int h), (window, w, h))
KS_REAL(SDL_ShowWindow, _Bool, (struct SDL_Window *window), (window))
KS_REAL(SDL_HideWindow, _Bool, (struct SDL_Window *window), (window))
KS_REAL(SDL_MinimizeWindow, _Bool, (struct SDL_Window *window), (window))
KS_REAL(SDL_RestoreWindow, _Bool, (struct SDL_Window *window), (window))
KS_REAL(SDL_RaiseWindow, _Bool, (struct SDL_Window *window), (window))
KS_REAL_VOID(SDL_DestroyWindow, (struct SDL_Window *window), (window))
KS_REAL(SDL_CreateRenderer, struct SDL_Renderer *, (struct SDL_Window *window, const char *name), (window, name))
KS_REAL(SDL_GetRendererInfo, int, (struct SDL_Renderer *renderer, struct SDL_RendererInfo *info), (renderer, info))
KS_REAL_VOID(SDL_DestroyRenderer, (struct SDL_Renderer *renderer), (renderer))
KS_REAL(SDL_CreateTexture, struct SDL_Texture *, (struct SDL_Renderer *renderer, unsigned int format, int access, int w, int h), (renderer, format, access, w, h))
KS_REAL(SDL_CreateTextureFromSurface, struct SDL_Texture *, (struct SDL_Renderer *renderer, struct SDL_Surface *surface), (renderer, surface))
KS_REAL_VOID(SDL_DestroyTexture, (struct SDL_Texture *texture), (texture))
KS_REAL(SDL_UpdateTexture, _Bool, (struct SDL_Texture *texture, const struct SDL_Rect *rect, const void *pixels, int pitch), (texture, rect, pixels, pitch))
KS_REAL(SDL_UpdateYUVTexture, _Bool, (struct SDL_Texture *texture, const struct SDL_Rect *rect, const unsigned char *yplane, int ypitch, const unsigned char *uplane, int upitch, const unsigned char *vplane, int vpitch), (texture, rect, yplane, ypitch, uplane, upitch, vplane, vpitch))
KS_REAL(SDL_UpdateNVTexture, _Bool, (struct SDL_Texture *texture, const struct SDL_Rect *rect, const unsigned char *yplane, int ypitch, const unsigned char *uvplane, int uvpitch), (texture, rect, yplane, ypitch, uvplane, uvpitch))
KS_REAL(SDL_LockTexture, _Bool, (struct SDL_Texture *texture, const struct SDL_Rect *rect, void **pixels, int *pitch), (texture, rect, pixels, pitch))
KS_REAL_VOID(SDL_UnlockTexture, (struct SDL_Texture *texture), (texture))
KS_REAL(SDL_SetTextureColorMod, _Bool, (struct SDL_Texture *texture, unsigned char r, unsigned char g, unsigned char b), (texture, r, g, b))
KS_REAL(SDL_SetTextureAlphaMod, _Bool, (struct SDL_Texture *texture, unsigned char a), (texture, a))
KS_REAL(SDL_SetTextureBlendMode, _Bool, (struct SDL_Texture *texture, unsigned int blendMode), (texture, blendMode))
KS_REAL(SDL_SetRenderDrawColor, _Bool, (struct SDL_Renderer *renderer, unsigned char r, unsigned char g, unsigned char b, unsigned char a), (renderer, r, g, b, a))
KS_REAL(SDL_RenderClear, _Bool, (struct SDL_Renderer *renderer), (renderer))
KS_REAL(SDL_RenderTexture, _Bool, (struct SDL_Renderer *renderer, struct SDL_Texture *texture, const struct SDL_FRect *srcrect, const struct SDL_FRect *dstrect), (renderer, texture, srcrect, dstrect))
KS_REAL(SDL_RenderTextureRotated, _Bool, (struct SDL_Renderer *renderer, struct SDL_Texture *texture, const struct SDL_FRect *srcrect, const struct SDL_FRect *dstrect, double angle, const struct SDL_FPoint *center, int flip), (renderer, texture, srcrect, dstrect, angle, center, flip))
KS_REAL(SDL_RenderGeometryRaw, _Bool, (struct SDL_Renderer *renderer, struct SDL_Texture *texture, const float *xy, int xy_stride, const struct SDL_FColor *color, int color_stride, const float *uv, int uv_stride, int num_vertices, const void *indices, int num_indices, int size_indices), (renderer, texture, xy, xy_stride, color, color_stride, uv, uv_stride, num_vertices, indices, num_indices, size_indices))
KS_REAL(SDL_RenderPresent, _Bool, (struct SDL_Renderer *renderer), (renderer))
KS_REAL(SDL_QueryTexture, int, (struct SDL_Texture *texture, unsigned int *format, int *access, int *w, int *h), (texture, format, access, w, h))
KS_REAL(SDL_RenderFillRect, _Bool, (struct SDL_Renderer *renderer, const struct SDL_FRect *rect), (renderer, rect))
KS_REAL(SDL_RenderPoint, _Bool, (struct SDL_Renderer *renderer, float x, float y), (renderer, x, y))
KS_REAL(SDL_RenderLine, _Bool, (struct SDL_Renderer *renderer, float x1, float y1, float x2, float y2), (renderer, x1, y1, x2, y2))
KS_REAL(SDL_SetRenderViewport, _Bool, (struct SDL_Renderer *renderer, const struct SDL_Rect *rect), (renderer, rect))
KS_REAL(SDL_SetRenderClipRect, _Bool, (struct SDL_Renderer *renderer, const struct SDL_Rect *rect), (renderer, rect))
KS_REAL(SDL_GL_CreateContext, void *, (struct SDL_Window *window), (window))
KS_REAL(SDL_GL_MakeCurrent, _Bool, (struct SDL_Window *window, void *context), (window, context))
KS_REAL(SDL_GetWindowSizeInPixels, _Bool, (struct SDL_Window *window, int *w, int *h), (window, w, h))
KS_REAL(SDL_GL_SwapWindow, _Bool, (struct SDL_Window *window), (window))
KS_REAL(SDL_Vulkan_LoadLibrary, _Bool, (const char *path), (path))
KS_REAL_VOID(SDL_PumpEvents, (void), ())
KS_REAL(SDL_PollEvent, _Bool, (union SDL_Event *event), (event))
KS_REAL(SDL_PeepEvents, int, (union SDL_Event *events, int numevents, int action, unsigned int minType, unsigned int maxType), (events, numevents, action, minType, maxType))
KS_REAL_VOID(SDL_SetEventEnabled, (unsigned int event_type, _Bool enabled), (event_type, enabled))
KS_REAL(SDL_EventEnabled, _Bool, (unsigned int event_type), (event_type))
KS_REAL(SDL_StartTextInput, _Bool, (struct SDL_Window *window), (window))
KS_REAL(SDL_StopTextInput, _Bool, (struct SDL_Window *window), (window))
KS_REAL(SDL_TextInputActive, _Bool, (struct SDL_Window *window), (window))
KS_REAL(SDL_SetTextInputArea, _Bool, (struct SDL_Window *window, const struct SDL_Rect *rect, int cursor), (window, rect, cursor))
KS_REAL(SDL_GetTextInputArea, _Bool, (struct SDL_Window *window, struct SDL_Rect *rect, int *cursor), (window, rect, cursor))
KS_REAL(SDL_HasKeyboard, _Bool, (void), ())
KS_REAL(SDL_GetKeyboardFocus, struct SDL_Window *, (void), ())
KS_REAL(SDL_GetKeyboardState, const _Bool *, (int *numkeys), (numkeys))
KS_REAL(SDL_GetModState, unsigned short, (void), ())
KS_REAL_VOID(SDL_SetModState, (unsigned short modstate), (modstate))
KS_REAL(SDL_GetMouseFocus, struct SDL_Window *, (void), ())
KS_REAL(SDL_GetMouseState, unsigned int, (float *x, float *y), (x, y))
KS_REAL(SDL_GetGlobalMouseState, unsigned int, (float *x, float *y), (x, y))
KS_REAL(SDL_GetRelativeMouseState, unsigned int, (float *x, float *y), (x, y))
KS_REAL(SDL_SetWindowRelativeMouseMode, _Bool, (struct SDL_Window *window, _Bool enabled), (window, enabled))
KS_REAL(SDL_GetWindowRelativeMouseMode, _Bool, (struct SDL_Window *window), (window))
KS_REAL(SDL_CaptureMouse, _Bool, (_Bool enabled), (enabled))
KS_REAL(SDL_GetTicks, unsigned long long, (void), ())
KS_REAL(SDL_ConvertSurface, struct SDL_Surface *, (struct SDL_Surface *surface, unsigned int pixel_format), (surface, pixel_format))
KS_REAL_VOID(SDL_DestroySurface, (struct SDL_Surface *surface), (surface))
KS_REAL(SDL_BlitSurface, _Bool, (struct SDL_Surface *src, const struct SDL_Rect *srcrect, struct SDL_Surface *dst, const struct SDL_Rect *dstrect), (src, srcrect, dst, dstrect))
KS_REAL(SDL_CreateColorCursor, struct SDL_Cursor *, (struct SDL_Surface *surface, int hot_x, int hot_y), (surface, hot_x, hot_y))
KS_REAL(SDL_SetCursor, _Bool, (struct SDL_Cursor *cursor), (cursor))
KS_REAL(SDL_ShowCursor, _Bool, (void), ())
KS_REAL(SDL_HideCursor, _Bool, (void), ())
KS_REAL_VOID(SDL_DestroyCursor, (struct SDL_Cursor *cursor), (cursor))
KS_REAL(SDL_GetError, const char *, (void), ())

void *ks_real_macos_slot_dlopen = NULL;

void *ks_real_dlopen(const char *path, int mode) {
    typedef void *(*fn_type)(const char *, int);
    fn_type real_fn = (fn_type)ks_real_macos_slot_dlopen;
    if (!real_fn) {
        // dlopen must bypass our rebinding wrapper; SDL symbols use RTLD_DEFAULT
        // because they may arrive later in a target-provided SDL3 image.
        real_fn = (fn_type)dlsym(RTLD_NEXT, "dlopen");
        ks_real_macos_slot_dlopen = (void *)real_fn;
    }
    if (!real_fn) ks_missing_real_symbol("dlopen");
    return real_fn(path, mode);
}

#endif
