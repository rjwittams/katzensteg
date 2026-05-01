#if defined(__linux__)

#define _GNU_SOURCE
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
struct SDL_RendererInfo;
struct SDL_Color;
union SDL_Event;

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

KS_REAL(SDL_Init, int, (unsigned int flags), (flags))
KS_REAL(SDL_InitSubSystem, int, (unsigned int flags), (flags))
KS_REAL(SDL_SetHint, int, (const char *name, const char *value), (name, value))
KS_REAL_VOID(SDL_QuitSubSystem, (unsigned int flags), (flags))
KS_REAL_VOID(SDL_Quit, (void), ())
KS_REAL(SDL_CreateWindow, struct SDL_Window *, (const char *title, int x, int y, int w, int h, unsigned int flags), (title, x, y, w, h, flags))
KS_REAL(SDL_GetWindowFlags, unsigned int, (struct SDL_Window *window), (window))
KS_REAL_VOID(SDL_ShowWindow, (struct SDL_Window *window), (window))
KS_REAL_VOID(SDL_HideWindow, (struct SDL_Window *window), (window))
KS_REAL_VOID(SDL_MinimizeWindow, (struct SDL_Window *window), (window))
KS_REAL_VOID(SDL_RestoreWindow, (struct SDL_Window *window), (window))
KS_REAL_VOID(SDL_RaiseWindow, (struct SDL_Window *window), (window))
KS_REAL_VOID(SDL_DestroyWindow, (struct SDL_Window *window), (window))
KS_REAL(SDL_CreateRenderer, struct SDL_Renderer *, (struct SDL_Window *window, int index, unsigned int flags), (window, index, flags))
KS_REAL(SDL_GetRendererInfo, int, (struct SDL_Renderer *renderer, struct SDL_RendererInfo *info), (renderer, info))
KS_REAL_VOID(SDL_DestroyRenderer, (struct SDL_Renderer *renderer), (renderer))
KS_REAL(SDL_CreateTexture, struct SDL_Texture *, (struct SDL_Renderer *renderer, unsigned int format, int access, int w, int h), (renderer, format, access, w, h))
KS_REAL(SDL_CreateTextureFromSurface, struct SDL_Texture *, (struct SDL_Renderer *renderer, struct SDL_Surface *surface), (renderer, surface))
KS_REAL_VOID(SDL_DestroyTexture, (struct SDL_Texture *texture), (texture))
KS_REAL(SDL_UpdateTexture, int, (struct SDL_Texture *texture, const struct SDL_Rect *rect, const void *pixels, int pitch), (texture, rect, pixels, pitch))
KS_REAL(SDL_UpdateYUVTexture, int, (struct SDL_Texture *texture, const struct SDL_Rect *rect, const unsigned char *yplane, int ypitch, const unsigned char *uplane, int upitch, const unsigned char *vplane, int vpitch), (texture, rect, yplane, ypitch, uplane, upitch, vplane, vpitch))
KS_REAL(SDL_UpdateNVTexture, int, (struct SDL_Texture *texture, const struct SDL_Rect *rect, const unsigned char *yplane, int ypitch, const unsigned char *uvplane, int uvpitch), (texture, rect, yplane, ypitch, uvplane, uvpitch))
KS_REAL(SDL_LockTexture, int, (struct SDL_Texture *texture, const struct SDL_Rect *rect, void **pixels, int *pitch), (texture, rect, pixels, pitch))
KS_REAL_VOID(SDL_UnlockTexture, (struct SDL_Texture *texture), (texture))
KS_REAL(SDL_SetTextureColorMod, int, (struct SDL_Texture *texture, unsigned char r, unsigned char g, unsigned char b), (texture, r, g, b))
KS_REAL(SDL_SetTextureAlphaMod, int, (struct SDL_Texture *texture, unsigned char a), (texture, a))
KS_REAL(SDL_SetTextureBlendMode, int, (struct SDL_Texture *texture, int blendMode), (texture, blendMode))
KS_REAL(SDL_SetRenderDrawColor, int, (struct SDL_Renderer *renderer, unsigned char r, unsigned char g, unsigned char b, unsigned char a), (renderer, r, g, b, a))
KS_REAL(SDL_RenderClear, int, (struct SDL_Renderer *renderer), (renderer))
KS_REAL(SDL_RenderCopy, int, (struct SDL_Renderer *renderer, struct SDL_Texture *texture, const struct SDL_Rect *srcrect, const struct SDL_Rect *dstrect), (renderer, texture, srcrect, dstrect))
KS_REAL(SDL_RenderCopyEx, int, (struct SDL_Renderer *renderer, struct SDL_Texture *texture, const struct SDL_Rect *srcrect, const struct SDL_Rect *dstrect, double angle, const struct SDL_Point *center, int flip), (renderer, texture, srcrect, dstrect, angle, center, flip))
KS_REAL(SDL_RenderGeometryRaw, int, (struct SDL_Renderer *renderer, struct SDL_Texture *texture, const float *xy, int xy_stride, const struct SDL_Color *color, int color_stride, const float *uv, int uv_stride, int num_vertices, const void *indices, int num_indices, int size_indices), (renderer, texture, xy, xy_stride, color, color_stride, uv, uv_stride, num_vertices, indices, num_indices, size_indices))
KS_REAL_VOID(SDL_RenderPresent, (struct SDL_Renderer *renderer), (renderer))
KS_REAL(SDL_QueryTexture, int, (struct SDL_Texture *texture, unsigned int *format, int *access, int *w, int *h), (texture, format, access, w, h))
KS_REAL(SDL_RenderFillRect, int, (struct SDL_Renderer *renderer, const struct SDL_Rect *rect), (renderer, rect))
KS_REAL(SDL_RenderDrawPoint, int, (struct SDL_Renderer *renderer, int x, int y), (renderer, x, y))
KS_REAL(SDL_RenderDrawLine, int, (struct SDL_Renderer *renderer, int x1, int y1, int x2, int y2), (renderer, x1, y1, x2, y2))
KS_REAL(SDL_RenderSetViewport, int, (struct SDL_Renderer *renderer, const struct SDL_Rect *rect), (renderer, rect))
KS_REAL(SDL_RenderSetClipRect, int, (struct SDL_Renderer *renderer, const struct SDL_Rect *rect), (renderer, rect))
KS_REAL(SDL_GL_CreateContext, void *, (struct SDL_Window *window), (window))
KS_REAL(SDL_GL_MakeCurrent, int, (struct SDL_Window *window, void *context), (window, context))
KS_REAL_VOID(SDL_GL_GetDrawableSize, (struct SDL_Window *window, int *w, int *h), (window, w, h))
KS_REAL_VOID(SDL_GL_SwapWindow, (struct SDL_Window *window), (window))
KS_REAL(SDL_Vulkan_LoadLibrary, int, (const char *path), (path))
KS_REAL_VOID(SDL_PumpEvents, (void), ())
KS_REAL(SDL_PollEvent, int, (union SDL_Event *event), (event))
KS_REAL(SDL_PeepEvents, int, (union SDL_Event *events, int numevents, int action, unsigned int minType, unsigned int maxType), (events, numevents, action, minType, maxType))
KS_REAL(SDL_GetKeyboardState, const unsigned char *, (int *numkeys), (numkeys))
KS_REAL(SDL_GetMouseFocus, struct SDL_Window *, (void), ())
KS_REAL(SDL_GetMouseState, unsigned int, (int *x, int *y), (x, y))
KS_REAL(SDL_GetRelativeMouseState, unsigned int, (int *x, int *y), (x, y))
KS_REAL(SDL_GetTicks, unsigned int, (void), ())
KS_REAL(SDL_ConvertSurfaceFormat, struct SDL_Surface *, (struct SDL_Surface *surface, unsigned int pixel_format, unsigned int flags), (surface, pixel_format, flags))
KS_REAL_VOID(SDL_FreeSurface, (struct SDL_Surface *surface), (surface))
KS_REAL(SDL_UpperBlit, int, (struct SDL_Surface *src, const struct SDL_Rect *srcrect, struct SDL_Surface *dst, struct SDL_Rect *dstrect), (src, srcrect, dst, dstrect))
KS_REAL(SDL_CreateColorCursor, struct SDL_Cursor *, (struct SDL_Surface *surface, int hot_x, int hot_y), (surface, hot_x, hot_y))
KS_REAL_VOID(SDL_SetCursor, (struct SDL_Cursor *cursor), (cursor))
KS_REAL(SDL_ShowCursor, int, (int toggle), (toggle))
KS_REAL_VOID(SDL_FreeCursor, (struct SDL_Cursor *cursor), (cursor))
KS_REAL(SDL_GetError, const char *, (void), ())
KS_REAL(dlopen, void *, (const char *path, int mode), (path, mode))

#endif
