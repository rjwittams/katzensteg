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
struct SDL_FPoint;
struct SDL_FRect;
struct SDL_FColor;
struct SDL_RendererInfo;
union SDL_Event;

extern void ks_SDL_QuitSubSystem(unsigned int);
extern void ks_SDL_Quit(void);
extern int ks_SDL_Init(unsigned int);
extern int ks_SDL_InitSubSystem(unsigned int);
extern int ks_SDL_SetHint(const char *, const char *);
extern struct SDL_Window *ks_SDL_CreateWindow(const char *, int, int, unsigned long long);
extern unsigned long long ks_SDL_GetWindowFlags(struct SDL_Window *);
extern _Bool ks_SDL_SetWindowSize(struct SDL_Window *, int, int);
extern _Bool ks_SDL_ShowWindow(struct SDL_Window *);
extern _Bool ks_SDL_HideWindow(struct SDL_Window *);
extern _Bool ks_SDL_MinimizeWindow(struct SDL_Window *);
extern _Bool ks_SDL_RestoreWindow(struct SDL_Window *);
extern _Bool ks_SDL_RaiseWindow(struct SDL_Window *);
extern void ks_SDL_DestroyWindow(struct SDL_Window *);
extern struct SDL_Renderer *ks_SDL_CreateRenderer(struct SDL_Window *, const char *);
extern int ks_SDL_GetRendererInfo(struct SDL_Renderer *, struct SDL_RendererInfo *);
extern void ks_SDL_DestroyRenderer(struct SDL_Renderer *);
extern struct SDL_Texture *ks_SDL_CreateTexture(struct SDL_Renderer *, unsigned int, int, int, int);
extern struct SDL_Texture *ks_SDL_CreateTextureFromSurface(struct SDL_Renderer *, struct SDL_Surface *);
extern void ks_SDL_DestroyTexture(struct SDL_Texture *);
extern _Bool ks_SDL_UpdateTexture(struct SDL_Texture *, const struct SDL_Rect *, const void *, int);
extern _Bool ks_SDL_UpdateYUVTexture(struct SDL_Texture *, const struct SDL_Rect *, const unsigned char *, int, const unsigned char *, int, const unsigned char *, int);
extern _Bool ks_SDL_UpdateNVTexture(struct SDL_Texture *, const struct SDL_Rect *, const unsigned char *, int, const unsigned char *, int);
extern _Bool ks_SDL_LockTexture(struct SDL_Texture *, const struct SDL_Rect *, void **, int *);
extern void ks_SDL_UnlockTexture(struct SDL_Texture *);
extern _Bool ks_SDL_SetTextureColorMod(struct SDL_Texture *, unsigned char, unsigned char, unsigned char);
extern _Bool ks_SDL_SetTextureAlphaMod(struct SDL_Texture *, unsigned char);
extern _Bool ks_SDL_SetTextureBlendMode(struct SDL_Texture *, unsigned int);
extern _Bool ks_SDL_SetRenderDrawColor(struct SDL_Renderer *, unsigned char, unsigned char, unsigned char, unsigned char);
extern _Bool ks_SDL_RenderClear(struct SDL_Renderer *);
extern _Bool ks_SDL_RenderFillRect(struct SDL_Renderer *, const struct SDL_FRect *);
extern _Bool ks_SDL_RenderPoint(struct SDL_Renderer *, float, float);
extern _Bool ks_SDL_RenderLine(struct SDL_Renderer *, float, float, float, float);
extern _Bool ks_SDL_SetRenderViewport(struct SDL_Renderer *, const struct SDL_Rect *);
extern _Bool ks_SDL_SetRenderClipRect(struct SDL_Renderer *, const struct SDL_Rect *);
extern _Bool ks_SDL_RenderTexture(struct SDL_Renderer *, struct SDL_Texture *, const struct SDL_FRect *, const struct SDL_FRect *);
extern _Bool ks_SDL_RenderTextureRotated(struct SDL_Renderer *, struct SDL_Texture *, const struct SDL_FRect *, const struct SDL_FRect *, double, const struct SDL_FPoint *, int);
extern _Bool ks_SDL_RenderGeometryRaw(struct SDL_Renderer *, struct SDL_Texture *, const float *, int, const struct SDL_FColor *, int, const float *, int, int, const void *, int, int);
extern _Bool ks_SDL_RenderPresent(struct SDL_Renderer *);
extern void *ks_SDL_GL_CreateContext(struct SDL_Window *);
extern _Bool ks_SDL_GL_MakeCurrent(struct SDL_Window *, void *);
extern _Bool ks_SDL_GL_SwapWindow(struct SDL_Window *);
extern _Bool ks_SDL_Vulkan_LoadLibrary(const char *);
extern void ks_SDL_PumpEvents(void);
extern _Bool ks_SDL_PollEvent(union SDL_Event *);
extern int ks_SDL_PeepEvents(union SDL_Event *, int, int, unsigned int, unsigned int);
extern void ks_SDL_SetEventEnabled(unsigned int, _Bool);
extern _Bool ks_SDL_EventEnabled(unsigned int);
extern _Bool ks_SDL_StartTextInput(struct SDL_Window *);
extern _Bool ks_SDL_StopTextInput(struct SDL_Window *);
extern _Bool ks_SDL_TextInputActive(struct SDL_Window *);
extern _Bool ks_SDL_SetTextInputArea(struct SDL_Window *, const struct SDL_Rect *, int);
extern _Bool ks_SDL_GetTextInputArea(struct SDL_Window *, struct SDL_Rect *, int *);
extern _Bool ks_SDL_HasKeyboard(void);
extern struct SDL_Window *ks_SDL_GetKeyboardFocus(void);
extern const _Bool *ks_SDL_GetKeyboardState(int *);
extern unsigned short ks_SDL_GetModState(void);
extern void ks_SDL_SetModState(unsigned short);
extern unsigned int ks_SDL_GetMouseState(float *, float *);
extern unsigned int ks_SDL_GetGlobalMouseState(float *, float *);
extern unsigned int ks_SDL_GetRelativeMouseState(float *, float *);
extern _Bool ks_SDL_SetWindowRelativeMouseMode(struct SDL_Window *, _Bool);
extern _Bool ks_SDL_GetWindowRelativeMouseMode(struct SDL_Window *);
extern _Bool ks_SDL_CaptureMouse(_Bool);
extern int ks_SDL_UpperBlit(struct SDL_Surface *, const struct SDL_Rect *, struct SDL_Surface *, struct SDL_Rect *);
extern struct SDL_Cursor *ks_SDL_CreateColorCursor(struct SDL_Surface *, int, int);
extern _Bool ks_SDL_SetCursor(struct SDL_Cursor *);
extern _Bool ks_SDL_ShowCursor(void);
extern _Bool ks_SDL_HideCursor(void);
extern void ks_SDL_DestroyCursor(struct SDL_Cursor *);
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

extern struct SDL_Window *SDL_CreateWindow(const char *, int, int, unsigned long long);
extern _Bool SDL_SetWindowSize(struct SDL_Window *, int, int);
extern void SDL_DestroyWindow(struct SDL_Window *);
extern _Bool SDL_ShowWindow(struct SDL_Window *);
extern _Bool SDL_HideWindow(struct SDL_Window *);
extern _Bool SDL_MinimizeWindow(struct SDL_Window *);
extern _Bool SDL_RestoreWindow(struct SDL_Window *);
extern _Bool SDL_RaiseWindow(struct SDL_Window *);
extern struct SDL_Renderer *SDL_CreateRenderer(struct SDL_Window *, const char *);
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
extern _Bool SDL_SetTextureBlendMode(struct SDL_Texture *, unsigned int);
extern int SDL_SetRenderDrawColor(struct SDL_Renderer *, unsigned char, unsigned char, unsigned char, unsigned char);
extern int SDL_RenderClear(struct SDL_Renderer *);
extern _Bool SDL_RenderFillRect(struct SDL_Renderer *, const struct SDL_FRect *);
extern _Bool SDL_RenderPoint(struct SDL_Renderer *, float, float);
extern _Bool SDL_RenderLine(struct SDL_Renderer *, float, float, float, float);
extern _Bool SDL_SetRenderViewport(struct SDL_Renderer *, const struct SDL_Rect *);
extern _Bool SDL_SetRenderClipRect(struct SDL_Renderer *, const struct SDL_Rect *);
extern _Bool SDL_RenderTexture(struct SDL_Renderer *, struct SDL_Texture *, const struct SDL_FRect *, const struct SDL_FRect *);
extern _Bool SDL_RenderTextureRotated(struct SDL_Renderer *, struct SDL_Texture *, const struct SDL_FRect *, const struct SDL_FRect *, double, const struct SDL_FPoint *, int);
extern int SDL_RenderGeometryRaw(struct SDL_Renderer *, struct SDL_Texture *, const float *, int, const void *, int, const float *, int, int, const void *, int, int);
extern _Bool SDL_RenderPresent(struct SDL_Renderer *);
extern void *SDL_GL_CreateContext(struct SDL_Window *);
extern int SDL_GL_MakeCurrent(struct SDL_Window *, void *);
extern void SDL_GL_SwapWindow(struct SDL_Window *);
extern _Bool SDL_Vulkan_LoadLibrary(const char *);
extern _Bool SDL_PollEvent(union SDL_Event *);
extern int SDL_PeepEvents(union SDL_Event *, int, int, unsigned int, unsigned int);
extern void SDL_PumpEvents(void);
extern void SDL_SetEventEnabled(unsigned int, _Bool);
extern _Bool SDL_EventEnabled(unsigned int);
extern _Bool SDL_StartTextInput(struct SDL_Window *);
extern _Bool SDL_StopTextInput(struct SDL_Window *);
extern _Bool SDL_TextInputActive(struct SDL_Window *);
extern _Bool SDL_SetTextInputArea(struct SDL_Window *, const struct SDL_Rect *, int);
extern _Bool SDL_GetTextInputArea(struct SDL_Window *, struct SDL_Rect *, int *);
extern _Bool SDL_HasKeyboard(void);
extern struct SDL_Window *SDL_GetKeyboardFocus(void);
extern const _Bool *SDL_GetKeyboardState(int *);
extern unsigned short SDL_GetModState(void);
extern void SDL_SetModState(unsigned short);
extern unsigned int SDL_GetMouseState(float *, float *);
extern unsigned int SDL_GetGlobalMouseState(float *, float *);
extern unsigned int SDL_GetRelativeMouseState(float *, float *);
extern _Bool SDL_SetWindowRelativeMouseMode(struct SDL_Window *, _Bool);
extern _Bool SDL_GetWindowRelativeMouseMode(struct SDL_Window *);
extern _Bool SDL_CaptureMouse(_Bool);
extern int SDL_UpperBlit(struct SDL_Surface *, const struct SDL_Rect *, struct SDL_Surface *, struct SDL_Rect *);
extern struct SDL_Cursor *SDL_CreateColorCursor(struct SDL_Surface *, int, int);
extern _Bool SDL_SetCursor(struct SDL_Cursor *);
extern _Bool SDL_ShowCursor(void);
extern _Bool SDL_HideCursor(void);
extern void SDL_DestroyCursor(struct SDL_Cursor *);
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
DYLD_INTERPOSE(ks_SDL_RenderPoint, SDL_RenderPoint)
DYLD_INTERPOSE(ks_SDL_RenderLine, SDL_RenderLine)
DYLD_INTERPOSE(ks_SDL_SetRenderViewport, SDL_SetRenderViewport)
DYLD_INTERPOSE(ks_SDL_SetRenderClipRect, SDL_SetRenderClipRect)
DYLD_INTERPOSE(ks_SDL_RenderTexture, SDL_RenderTexture)
DYLD_INTERPOSE(ks_SDL_RenderTextureRotated, SDL_RenderTextureRotated)
DYLD_INTERPOSE(ks_SDL_RenderGeometryRaw, SDL_RenderGeometryRaw)
DYLD_INTERPOSE(ks_SDL_RenderPresent, SDL_RenderPresent)
DYLD_INTERPOSE(ks_SDL_GL_CreateContext, SDL_GL_CreateContext)
DYLD_INTERPOSE(ks_SDL_GL_MakeCurrent, SDL_GL_MakeCurrent)
DYLD_INTERPOSE(ks_SDL_GL_SwapWindow, SDL_GL_SwapWindow)
DYLD_INTERPOSE(ks_SDL_Vulkan_LoadLibrary, SDL_Vulkan_LoadLibrary)
DYLD_INTERPOSE(ks_SDL_PumpEvents, SDL_PumpEvents)
DYLD_INTERPOSE(ks_SDL_PollEvent, SDL_PollEvent)
DYLD_INTERPOSE(ks_SDL_PeepEvents, SDL_PeepEvents)
DYLD_INTERPOSE(ks_SDL_SetEventEnabled, SDL_SetEventEnabled)
DYLD_INTERPOSE(ks_SDL_EventEnabled, SDL_EventEnabled)
DYLD_INTERPOSE(ks_SDL_StartTextInput, SDL_StartTextInput)
DYLD_INTERPOSE(ks_SDL_StopTextInput, SDL_StopTextInput)
DYLD_INTERPOSE(ks_SDL_TextInputActive, SDL_TextInputActive)
DYLD_INTERPOSE(ks_SDL_SetTextInputArea, SDL_SetTextInputArea)
DYLD_INTERPOSE(ks_SDL_GetTextInputArea, SDL_GetTextInputArea)
DYLD_INTERPOSE(ks_SDL_HasKeyboard, SDL_HasKeyboard)
DYLD_INTERPOSE(ks_SDL_GetKeyboardFocus, SDL_GetKeyboardFocus)
DYLD_INTERPOSE(ks_SDL_GetKeyboardState, SDL_GetKeyboardState)
DYLD_INTERPOSE(ks_SDL_GetModState, SDL_GetModState)
DYLD_INTERPOSE(ks_SDL_SetModState, SDL_SetModState)
DYLD_INTERPOSE(ks_SDL_GetMouseState, SDL_GetMouseState)
DYLD_INTERPOSE(ks_SDL_GetGlobalMouseState, SDL_GetGlobalMouseState)
DYLD_INTERPOSE(ks_SDL_GetRelativeMouseState, SDL_GetRelativeMouseState)
DYLD_INTERPOSE(ks_SDL_SetWindowRelativeMouseMode, SDL_SetWindowRelativeMouseMode)
DYLD_INTERPOSE(ks_SDL_GetWindowRelativeMouseMode, SDL_GetWindowRelativeMouseMode)
DYLD_INTERPOSE(ks_SDL_CaptureMouse, SDL_CaptureMouse)
DYLD_INTERPOSE(ks_SDL_CreateColorCursor, SDL_CreateColorCursor)
DYLD_INTERPOSE(ks_SDL_SetCursor, SDL_SetCursor)
DYLD_INTERPOSE(ks_SDL_ShowCursor, SDL_ShowCursor)
DYLD_INTERPOSE(ks_SDL_HideCursor, SDL_HideCursor)
DYLD_INTERPOSE(ks_SDL_DestroyCursor, SDL_DestroyCursor)
DYLD_INTERPOSE(ks_dlopen, dlopen)

#endif
