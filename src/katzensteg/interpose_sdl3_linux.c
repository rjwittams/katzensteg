#if defined(__linux__)

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

__attribute__((destructor))
static void katzensteg_module_destructor(void) {
    ks_katzensteg_shutdown();
}

_Bool SDL_Init(unsigned int flags) { return ks_SDL_Init(flags); }
_Bool SDL_InitSubSystem(unsigned int flags) { return ks_SDL_InitSubSystem(flags); }
_Bool SDL_SetHint(const char *name, const char *value) { return ks_SDL_SetHint(name, value); }
void SDL_QuitSubSystem(unsigned int flags) { ks_SDL_QuitSubSystem(flags); }
void SDL_Quit(void) { ks_SDL_Quit(); }
struct SDL_Window *SDL_CreateWindow(const char *title, int w, int h, unsigned long long flags) { return ks_SDL_CreateWindow(title, w, h, flags); }
unsigned long long SDL_GetWindowFlags(struct SDL_Window *window) { return ks_SDL_GetWindowFlags(window); }
_Bool SDL_SetWindowSize(struct SDL_Window *window, int w, int h) { return ks_SDL_SetWindowSize(window, w, h); }
_Bool SDL_ShowWindow(struct SDL_Window *window) { return ks_SDL_ShowWindow(window); }
_Bool SDL_HideWindow(struct SDL_Window *window) { return ks_SDL_HideWindow(window); }
_Bool SDL_MinimizeWindow(struct SDL_Window *window) { return ks_SDL_MinimizeWindow(window); }
_Bool SDL_RestoreWindow(struct SDL_Window *window) { return ks_SDL_RestoreWindow(window); }
_Bool SDL_RaiseWindow(struct SDL_Window *window) { return ks_SDL_RaiseWindow(window); }
void SDL_DestroyWindow(struct SDL_Window *window) { ks_SDL_DestroyWindow(window); }
struct SDL_Renderer *SDL_CreateRenderer(struct SDL_Window *window, const char *name) { return ks_SDL_CreateRenderer(window, name); }
int SDL_GetRendererInfo(struct SDL_Renderer *renderer, struct SDL_RendererInfo *info) { return ks_SDL_GetRendererInfo(renderer, info); }
void SDL_DestroyRenderer(struct SDL_Renderer *renderer) { ks_SDL_DestroyRenderer(renderer); }
struct SDL_Texture *SDL_CreateTexture(struct SDL_Renderer *renderer, unsigned int format, int access, int w, int h) { return ks_SDL_CreateTexture(renderer, format, access, w, h); }
struct SDL_Texture *SDL_CreateTextureFromSurface(struct SDL_Renderer *renderer, struct SDL_Surface *surface) { return ks_SDL_CreateTextureFromSurface(renderer, surface); }
void SDL_DestroyTexture(struct SDL_Texture *texture) { ks_SDL_DestroyTexture(texture); }
_Bool SDL_UpdateTexture(struct SDL_Texture *texture, const struct SDL_Rect *rect, const void *pixels, int pitch) { return ks_SDL_UpdateTexture(texture, rect, pixels, pitch); }
_Bool SDL_UpdateYUVTexture(struct SDL_Texture *texture, const struct SDL_Rect *rect, const unsigned char *yplane, int ypitch, const unsigned char *uplane, int upitch, const unsigned char *vplane, int vpitch) { return ks_SDL_UpdateYUVTexture(texture, rect, yplane, ypitch, uplane, upitch, vplane, vpitch); }
_Bool SDL_UpdateNVTexture(struct SDL_Texture *texture, const struct SDL_Rect *rect, const unsigned char *yplane, int ypitch, const unsigned char *uvplane, int uvpitch) { return ks_SDL_UpdateNVTexture(texture, rect, yplane, ypitch, uvplane, uvpitch); }
_Bool SDL_LockTexture(struct SDL_Texture *texture, const struct SDL_Rect *rect, void **pixels, int *pitch) { return ks_SDL_LockTexture(texture, rect, pixels, pitch); }
void SDL_UnlockTexture(struct SDL_Texture *texture) { ks_SDL_UnlockTexture(texture); }
_Bool SDL_SetTextureColorMod(struct SDL_Texture *texture, unsigned char r, unsigned char g, unsigned char b) { return ks_SDL_SetTextureColorMod(texture, r, g, b); }
_Bool SDL_SetTextureAlphaMod(struct SDL_Texture *texture, unsigned char a) { return ks_SDL_SetTextureAlphaMod(texture, a); }
_Bool SDL_SetTextureBlendMode(struct SDL_Texture *texture, unsigned int blendMode) { return ks_SDL_SetTextureBlendMode(texture, blendMode); }
_Bool SDL_SetRenderDrawColor(struct SDL_Renderer *renderer, unsigned char r, unsigned char g, unsigned char b, unsigned char a) { return ks_SDL_SetRenderDrawColor(renderer, r, g, b, a); }
_Bool SDL_RenderClear(struct SDL_Renderer *renderer) { return ks_SDL_RenderClear(renderer); }
_Bool SDL_RenderTexture(struct SDL_Renderer *renderer, struct SDL_Texture *texture, const struct SDL_FRect *srcrect, const struct SDL_FRect *dstrect) { return ks_SDL_RenderTexture(renderer, texture, srcrect, dstrect); }
_Bool SDL_RenderTextureRotated(struct SDL_Renderer *renderer, struct SDL_Texture *texture, const struct SDL_FRect *srcrect, const struct SDL_FRect *dstrect, double angle, const struct SDL_FPoint *center, int flip) { return ks_SDL_RenderTextureRotated(renderer, texture, srcrect, dstrect, angle, center, flip); }
_Bool SDL_RenderGeometryRaw(struct SDL_Renderer *renderer, struct SDL_Texture *texture, const float *xy, int xy_stride, const struct SDL_FColor *color, int color_stride, const float *uv, int uv_stride, int num_vertices, const void *indices, int num_indices, int size_indices) { return ks_SDL_RenderGeometryRaw(renderer, texture, xy, xy_stride, color, color_stride, uv, uv_stride, num_vertices, indices, num_indices, size_indices); }
_Bool SDL_RenderPresent(struct SDL_Renderer *renderer) { return ks_SDL_RenderPresent(renderer); }
_Bool SDL_RenderFillRect(struct SDL_Renderer *renderer, const struct SDL_FRect *rect) { return ks_SDL_RenderFillRect(renderer, rect); }
_Bool SDL_RenderPoint(struct SDL_Renderer *renderer, float x, float y) { return ks_SDL_RenderPoint(renderer, x, y); }
_Bool SDL_RenderLine(struct SDL_Renderer *renderer, float x1, float y1, float x2, float y2) { return ks_SDL_RenderLine(renderer, x1, y1, x2, y2); }
_Bool SDL_SetRenderViewport(struct SDL_Renderer *renderer, const struct SDL_Rect *rect) { return ks_SDL_SetRenderViewport(renderer, rect); }
_Bool SDL_SetRenderClipRect(struct SDL_Renderer *renderer, const struct SDL_Rect *rect) { return ks_SDL_SetRenderClipRect(renderer, rect); }
void *SDL_GL_CreateContext(struct SDL_Window *window) { return ks_SDL_GL_CreateContext(window); }
_Bool SDL_GL_MakeCurrent(struct SDL_Window *window, void *context) { return ks_SDL_GL_MakeCurrent(window, context); }
_Bool SDL_GL_SwapWindow(struct SDL_Window *window) { return ks_SDL_GL_SwapWindow(window); }
_Bool SDL_Vulkan_LoadLibrary(const char *path) { return ks_SDL_Vulkan_LoadLibrary(path); }
void SDL_PumpEvents(void) { ks_SDL_PumpEvents(); }
_Bool SDL_PollEvent(union SDL_Event *event) { return ks_SDL_PollEvent(event); }
int SDL_PeepEvents(union SDL_Event *events, int numevents, int action, unsigned int minType, unsigned int maxType) { return ks_SDL_PeepEvents(events, numevents, action, minType, maxType); }
void SDL_SetEventEnabled(unsigned int event_type, _Bool enabled) { ks_SDL_SetEventEnabled(event_type, enabled); }
_Bool SDL_EventEnabled(unsigned int event_type) { return ks_SDL_EventEnabled(event_type); }
_Bool SDL_StartTextInput(struct SDL_Window *window) { return ks_SDL_StartTextInput(window); }
_Bool SDL_StopTextInput(struct SDL_Window *window) { return ks_SDL_StopTextInput(window); }
_Bool SDL_TextInputActive(struct SDL_Window *window) { return ks_SDL_TextInputActive(window); }
_Bool SDL_SetTextInputArea(struct SDL_Window *window, const struct SDL_Rect *rect, int cursor) { return ks_SDL_SetTextInputArea(window, rect, cursor); }
_Bool SDL_GetTextInputArea(struct SDL_Window *window, struct SDL_Rect *rect, int *cursor) { return ks_SDL_GetTextInputArea(window, rect, cursor); }
_Bool SDL_HasKeyboard(void) { return ks_SDL_HasKeyboard(); }
struct SDL_Window *SDL_GetKeyboardFocus(void) { return ks_SDL_GetKeyboardFocus(); }
const _Bool *SDL_GetKeyboardState(int *numkeys) { return ks_SDL_GetKeyboardState(numkeys); }
unsigned short SDL_GetModState(void) { return ks_SDL_GetModState(); }
void SDL_SetModState(unsigned short modstate) { ks_SDL_SetModState(modstate); }
unsigned int SDL_GetMouseState(float *x, float *y) { return ks_SDL_GetMouseState(x, y); }
unsigned int SDL_GetGlobalMouseState(float *x, float *y) { return ks_SDL_GetGlobalMouseState(x, y); }
unsigned int SDL_GetRelativeMouseState(float *x, float *y) { return ks_SDL_GetRelativeMouseState(x, y); }
_Bool SDL_SetWindowRelativeMouseMode(struct SDL_Window *window, _Bool enabled) { return ks_SDL_SetWindowRelativeMouseMode(window, enabled); }
_Bool SDL_GetWindowRelativeMouseMode(struct SDL_Window *window) { return ks_SDL_GetWindowRelativeMouseMode(window); }
_Bool SDL_CaptureMouse(_Bool enabled) { return ks_SDL_CaptureMouse(enabled); }
int SDL_UpperBlit(struct SDL_Surface *src, const struct SDL_Rect *srcrect, struct SDL_Surface *dst, struct SDL_Rect *dstrect) { return ks_SDL_UpperBlit(src, srcrect, dst, dstrect); }
struct SDL_Cursor *SDL_CreateColorCursor(struct SDL_Surface *surface, int hot_x, int hot_y) { return ks_SDL_CreateColorCursor(surface, hot_x, hot_y); }
_Bool SDL_SetCursor(struct SDL_Cursor *cursor) { return ks_SDL_SetCursor(cursor); }
_Bool SDL_ShowCursor(void) { return ks_SDL_ShowCursor(); }
_Bool SDL_HideCursor(void) { return ks_SDL_HideCursor(); }
void SDL_DestroyCursor(struct SDL_Cursor *cursor) { ks_SDL_DestroyCursor(cursor); }
void *dlopen(const char *path, int mode) { return ks_dlopen(path, mode); }

#endif
