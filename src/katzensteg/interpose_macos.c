#if defined(__APPLE__)

#define DYLD_INTERPOSE(_replacement,_replacee) \
    __attribute__((used)) static struct { \
        const void* replacement; \
        const void* replacee; \
    } _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = { \
        (const void*)(unsigned long)&_replacement, \
        (const void*)(unsigned long)&_replacee \
    };

struct SDL_Window;
struct SDL_Renderer;
struct SDL_Texture;
struct SDL_Surface;
struct SDL_Cursor;
struct SDL_Rect;
struct SDL_Point;
struct SDL_RendererInfo;
union SDL_Event;

extern void ks_SDL_QuitSubSystem(unsigned int);
extern void ks_SDL_Quit(void);
extern int ks_SDL_Init(unsigned int);
extern int ks_SDL_InitSubSystem(unsigned int);
extern int ks_SDL_SetHint(const char *, const char *);
extern struct SDL_Window *ks_SDL_CreateWindow(const char *, int, int, int, int, unsigned int);
extern unsigned int ks_SDL_GetWindowFlags(struct SDL_Window *);
extern void ks_SDL_SetWindowSize(struct SDL_Window *, int, int);
extern void ks_SDL_ShowWindow(struct SDL_Window *);
extern void ks_SDL_HideWindow(struct SDL_Window *);
extern void ks_SDL_MinimizeWindow(struct SDL_Window *);
extern void ks_SDL_RestoreWindow(struct SDL_Window *);
extern void ks_SDL_RaiseWindow(struct SDL_Window *);
extern void ks_SDL_DestroyWindow(struct SDL_Window *);
extern struct SDL_Renderer *ks_SDL_CreateRenderer(struct SDL_Window *, int, unsigned int);
extern int ks_SDL_GetRendererInfo(struct SDL_Renderer *, struct SDL_RendererInfo *);
extern void ks_SDL_DestroyRenderer(struct SDL_Renderer *);
extern struct SDL_Texture *ks_SDL_CreateTexture(struct SDL_Renderer *, unsigned int, int, int, int);
extern struct SDL_Texture *ks_SDL_CreateTextureFromSurface(struct SDL_Renderer *, struct SDL_Surface *);
extern void ks_SDL_DestroyTexture(struct SDL_Texture *);
extern int ks_SDL_UpdateTexture(struct SDL_Texture *, const struct SDL_Rect *, const void *, int);
extern int ks_SDL_UpdateYUVTexture(struct SDL_Texture *, const struct SDL_Rect *, const unsigned char *, int, const unsigned char *, int, const unsigned char *, int);
extern int ks_SDL_UpdateNVTexture(struct SDL_Texture *, const struct SDL_Rect *, const unsigned char *, int, const unsigned char *, int);
extern int ks_SDL_LockTexture(struct SDL_Texture *, const struct SDL_Rect *, void **, int *);
extern void ks_SDL_UnlockTexture(struct SDL_Texture *);
extern int ks_SDL_SetTextureColorMod(struct SDL_Texture *, unsigned char, unsigned char, unsigned char);
extern int ks_SDL_SetTextureAlphaMod(struct SDL_Texture *, unsigned char);
extern int ks_SDL_SetTextureBlendMode(struct SDL_Texture *, int);
extern int ks_SDL_SetRenderDrawColor(struct SDL_Renderer *, unsigned char, unsigned char, unsigned char, unsigned char);
extern int ks_SDL_RenderClear(struct SDL_Renderer *);
extern int ks_SDL_RenderFillRect(struct SDL_Renderer *, const struct SDL_Rect *);
extern int ks_SDL_RenderDrawPoint(struct SDL_Renderer *, int, int);
extern int ks_SDL_RenderDrawLine(struct SDL_Renderer *, int, int, int, int);
extern int ks_SDL_RenderSetViewport(struct SDL_Renderer *, const struct SDL_Rect *);
extern int ks_SDL_RenderSetClipRect(struct SDL_Renderer *, const struct SDL_Rect *);
extern int ks_SDL_RenderCopy(struct SDL_Renderer *, struct SDL_Texture *, const struct SDL_Rect *, const struct SDL_Rect *);
extern int ks_SDL_RenderCopyEx(struct SDL_Renderer *, struct SDL_Texture *, const struct SDL_Rect *, const struct SDL_Rect *, double, const struct SDL_Point *, int);
extern int ks_SDL_RenderGeometryRaw(struct SDL_Renderer *, struct SDL_Texture *, const float *, int, const void *, int, const float *, int, int, const void *, int, int);
extern void ks_SDL_RenderPresent(struct SDL_Renderer *);
extern void *ks_SDL_GL_CreateContext(struct SDL_Window *);
extern int ks_SDL_GL_MakeCurrent(struct SDL_Window *, void *);
extern void ks_SDL_GL_SwapWindow(struct SDL_Window *);
extern int ks_SDL_Vulkan_LoadLibrary(const char *);
extern void ks_SDL_PumpEvents(void);
extern int ks_SDL_PollEvent(union SDL_Event *);
extern int ks_SDL_PeepEvents(union SDL_Event *, int, int, unsigned int, unsigned int);
extern const unsigned char *ks_SDL_GetKeyboardState(int *);
extern unsigned int ks_SDL_GetMouseState(int *, int *);
extern unsigned int ks_SDL_GetRelativeMouseState(int *, int *);
extern int ks_SDL_UpperBlit(struct SDL_Surface *, const struct SDL_Rect *, struct SDL_Surface *, struct SDL_Rect *);
extern struct SDL_Cursor *ks_SDL_CreateColorCursor(struct SDL_Surface *, int, int);
extern void ks_SDL_SetCursor(struct SDL_Cursor *);
extern int ks_SDL_ShowCursor(int);
extern void ks_SDL_FreeCursor(struct SDL_Cursor *);
extern void ks_katzensteg_shutdown(void);
extern void *ks_dlopen(const char *, int);
extern void ks_scrub_preload_env_for_loaded_symbol(const void *);

__attribute__((constructor))
static void katzensteg_module_constructor(void) {
    ks_scrub_preload_env_for_loaded_symbol((const void *)&katzensteg_module_constructor);
}

static void katzensteg_module_destructor(void) {
    ks_katzensteg_shutdown();
}

__attribute__((used, section("__DATA,__mod_term_func")))
static void (*katzensteg_module_destructor_ptr)(void) = katzensteg_module_destructor;

extern struct SDL_Window *SDL_CreateWindow(const char *, int, int, int, int, unsigned int);
extern void SDL_SetWindowSize(struct SDL_Window *, int, int);
extern void SDL_DestroyWindow(struct SDL_Window *);
extern void SDL_ShowWindow(struct SDL_Window *);
extern void SDL_HideWindow(struct SDL_Window *);
extern void SDL_MinimizeWindow(struct SDL_Window *);
extern void SDL_RestoreWindow(struct SDL_Window *);
extern void SDL_RaiseWindow(struct SDL_Window *);
extern struct SDL_Renderer *SDL_CreateRenderer(struct SDL_Window *, int, unsigned int);
extern int SDL_GetRendererInfo(struct SDL_Renderer *, struct SDL_RendererInfo *);
extern void SDL_DestroyRenderer(struct SDL_Renderer *);
extern struct SDL_Texture *SDL_CreateTexture(struct SDL_Renderer *, unsigned int, int, int, int);
extern struct SDL_Texture *SDL_CreateTextureFromSurface(struct SDL_Renderer *, struct SDL_Surface *);
extern void SDL_DestroyTexture(struct SDL_Texture *);
extern int SDL_UpdateTexture(struct SDL_Texture *, const struct SDL_Rect *, const void *, int);
extern int SDL_UpdateYUVTexture(struct SDL_Texture *, const struct SDL_Rect *, const unsigned char *, int, const unsigned char *, int, const unsigned char *, int);
extern int SDL_UpdateNVTexture(struct SDL_Texture *, const struct SDL_Rect *, const unsigned char *, int, const unsigned char *, int);
extern int SDL_LockTexture(struct SDL_Texture *, const struct SDL_Rect *, void **, int *);
extern void SDL_UnlockTexture(struct SDL_Texture *);
extern int SDL_SetTextureColorMod(struct SDL_Texture *, unsigned char, unsigned char, unsigned char);
extern int SDL_SetTextureAlphaMod(struct SDL_Texture *, unsigned char);
extern int SDL_SetTextureBlendMode(struct SDL_Texture *, int);
extern int SDL_SetRenderDrawColor(struct SDL_Renderer *, unsigned char, unsigned char, unsigned char, unsigned char);
extern int SDL_RenderClear(struct SDL_Renderer *);
extern int SDL_RenderFillRect(struct SDL_Renderer *, const struct SDL_Rect *);
extern int SDL_RenderDrawPoint(struct SDL_Renderer *, int, int);
extern int SDL_RenderDrawLine(struct SDL_Renderer *, int, int, int, int);
extern int SDL_RenderSetViewport(struct SDL_Renderer *, const struct SDL_Rect *);
extern int SDL_RenderSetClipRect(struct SDL_Renderer *, const struct SDL_Rect *);
extern int SDL_RenderCopy(struct SDL_Renderer *, struct SDL_Texture *, const struct SDL_Rect *, const struct SDL_Rect *);
extern int SDL_RenderCopyEx(struct SDL_Renderer *, struct SDL_Texture *, const struct SDL_Rect *, const struct SDL_Rect *, double, const struct SDL_Point *, int);
extern int SDL_RenderGeometryRaw(struct SDL_Renderer *, struct SDL_Texture *, const float *, int, const void *, int, const float *, int, int, const void *, int, int);
extern void SDL_RenderPresent(struct SDL_Renderer *);
extern void *SDL_GL_CreateContext(struct SDL_Window *);
extern int SDL_GL_MakeCurrent(struct SDL_Window *, void *);
extern void SDL_GL_SwapWindow(struct SDL_Window *);
extern int SDL_Vulkan_LoadLibrary(const char *);
extern int SDL_PollEvent(union SDL_Event *);
extern int SDL_PeepEvents(union SDL_Event *, int, int, unsigned int, unsigned int);
extern void SDL_PumpEvents(void);
extern const unsigned char *SDL_GetKeyboardState(int *);
extern unsigned int SDL_GetMouseState(int *, int *);
extern unsigned int SDL_GetRelativeMouseState(int *, int *);
extern int SDL_UpperBlit(struct SDL_Surface *, const struct SDL_Rect *, struct SDL_Surface *, struct SDL_Rect *);
extern struct SDL_Cursor *SDL_CreateColorCursor(struct SDL_Surface *, int, int);
extern void SDL_SetCursor(struct SDL_Cursor *);
extern int SDL_ShowCursor(int);
extern void SDL_FreeCursor(struct SDL_Cursor *);
extern int SDL_Init(unsigned int);
extern int SDL_InitSubSystem(unsigned int);
extern int SDL_SetHint(const char *, const char *);
extern void SDL_QuitSubSystem(unsigned int);
extern void SDL_Quit(void);
extern unsigned int SDL_GetWindowFlags(struct SDL_Window *);
extern void *dlopen(const char *, int);

DYLD_INTERPOSE(ks_SDL_Init, SDL_Init)
DYLD_INTERPOSE(ks_SDL_InitSubSystem, SDL_InitSubSystem)
DYLD_INTERPOSE(ks_SDL_SetHint, SDL_SetHint)
DYLD_INTERPOSE(ks_SDL_QuitSubSystem, SDL_QuitSubSystem)
DYLD_INTERPOSE(ks_SDL_Quit, SDL_Quit)
DYLD_INTERPOSE(ks_SDL_CreateWindow, SDL_CreateWindow)
DYLD_INTERPOSE(ks_SDL_GetWindowFlags, SDL_GetWindowFlags)
DYLD_INTERPOSE(ks_SDL_SetWindowSize, SDL_SetWindowSize)
DYLD_INTERPOSE(ks_SDL_ShowWindow, SDL_ShowWindow)
DYLD_INTERPOSE(ks_SDL_HideWindow, SDL_HideWindow)
DYLD_INTERPOSE(ks_SDL_MinimizeWindow, SDL_MinimizeWindow)
DYLD_INTERPOSE(ks_SDL_RestoreWindow, SDL_RestoreWindow)
DYLD_INTERPOSE(ks_SDL_RaiseWindow, SDL_RaiseWindow)
DYLD_INTERPOSE(ks_SDL_DestroyWindow, SDL_DestroyWindow)
DYLD_INTERPOSE(ks_SDL_CreateRenderer, SDL_CreateRenderer)
DYLD_INTERPOSE(ks_SDL_GetRendererInfo, SDL_GetRendererInfo)
DYLD_INTERPOSE(ks_SDL_DestroyRenderer, SDL_DestroyRenderer)
DYLD_INTERPOSE(ks_SDL_CreateTexture, SDL_CreateTexture)
DYLD_INTERPOSE(ks_SDL_CreateTextureFromSurface, SDL_CreateTextureFromSurface)
DYLD_INTERPOSE(ks_SDL_DestroyTexture, SDL_DestroyTexture)
DYLD_INTERPOSE(ks_SDL_UpdateTexture, SDL_UpdateTexture)
DYLD_INTERPOSE(ks_SDL_UpdateYUVTexture, SDL_UpdateYUVTexture)
DYLD_INTERPOSE(ks_SDL_UpdateNVTexture, SDL_UpdateNVTexture)
DYLD_INTERPOSE(ks_SDL_LockTexture, SDL_LockTexture)
DYLD_INTERPOSE(ks_SDL_UnlockTexture, SDL_UnlockTexture)
DYLD_INTERPOSE(ks_SDL_SetTextureColorMod, SDL_SetTextureColorMod)
DYLD_INTERPOSE(ks_SDL_SetTextureAlphaMod, SDL_SetTextureAlphaMod)
DYLD_INTERPOSE(ks_SDL_SetTextureBlendMode, SDL_SetTextureBlendMode)
DYLD_INTERPOSE(ks_SDL_SetRenderDrawColor, SDL_SetRenderDrawColor)
DYLD_INTERPOSE(ks_SDL_RenderClear, SDL_RenderClear)
DYLD_INTERPOSE(ks_SDL_RenderFillRect, SDL_RenderFillRect)
DYLD_INTERPOSE(ks_SDL_RenderDrawPoint, SDL_RenderDrawPoint)
DYLD_INTERPOSE(ks_SDL_RenderDrawLine, SDL_RenderDrawLine)
DYLD_INTERPOSE(ks_SDL_RenderSetViewport, SDL_RenderSetViewport)
DYLD_INTERPOSE(ks_SDL_RenderSetClipRect, SDL_RenderSetClipRect)
DYLD_INTERPOSE(ks_SDL_RenderCopy, SDL_RenderCopy)
DYLD_INTERPOSE(ks_SDL_RenderCopyEx, SDL_RenderCopyEx)
DYLD_INTERPOSE(ks_SDL_RenderGeometryRaw, SDL_RenderGeometryRaw)
DYLD_INTERPOSE(ks_SDL_RenderPresent, SDL_RenderPresent)
DYLD_INTERPOSE(ks_SDL_GL_CreateContext, SDL_GL_CreateContext)
DYLD_INTERPOSE(ks_SDL_GL_MakeCurrent, SDL_GL_MakeCurrent)
DYLD_INTERPOSE(ks_SDL_GL_SwapWindow, SDL_GL_SwapWindow)
DYLD_INTERPOSE(ks_SDL_Vulkan_LoadLibrary, SDL_Vulkan_LoadLibrary)
DYLD_INTERPOSE(ks_SDL_PumpEvents, SDL_PumpEvents)
DYLD_INTERPOSE(ks_SDL_PollEvent, SDL_PollEvent)
DYLD_INTERPOSE(ks_SDL_PeepEvents, SDL_PeepEvents)
DYLD_INTERPOSE(ks_SDL_GetKeyboardState, SDL_GetKeyboardState)
DYLD_INTERPOSE(ks_SDL_GetMouseState, SDL_GetMouseState)
DYLD_INTERPOSE(ks_SDL_GetRelativeMouseState, SDL_GetRelativeMouseState)
DYLD_INTERPOSE(ks_SDL_UpperBlit, SDL_UpperBlit)
DYLD_INTERPOSE(ks_SDL_CreateColorCursor, SDL_CreateColorCursor)
DYLD_INTERPOSE(ks_SDL_SetCursor, SDL_SetCursor)
DYLD_INTERPOSE(ks_SDL_ShowCursor, SDL_ShowCursor)
DYLD_INTERPOSE(ks_SDL_FreeCursor, SDL_FreeCursor)
DYLD_INTERPOSE(ks_dlopen, dlopen)

#endif
