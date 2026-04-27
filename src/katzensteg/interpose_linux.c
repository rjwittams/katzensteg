#if defined(__linux__)

struct SDL_Window;
struct SDL_Renderer;
struct SDL_Texture;
struct SDL_Surface;
struct SDL_Rect;
struct SDL_Point;
struct SDL_RendererInfo;
struct SDL_Color;
union SDL_Event;

extern void ks_SDL_QuitSubSystem(unsigned int);
extern void ks_SDL_Quit(void);
extern int ks_SDL_Init(unsigned int);
extern int ks_SDL_InitSubSystem(unsigned int);
extern struct SDL_Window *ks_SDL_CreateWindow(const char *, int, int, int, int, unsigned int);
extern unsigned int ks_SDL_GetWindowFlags(struct SDL_Window *);
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
extern int ks_SDL_RenderGeometryRaw(struct SDL_Renderer *, struct SDL_Texture *, const float *, int, const struct SDL_Color *, int, const float *, int, int, const void *, int, int);
extern void ks_SDL_RenderPresent(struct SDL_Renderer *);
extern void *ks_SDL_GL_CreateContext(struct SDL_Window *);
extern int ks_SDL_GL_MakeCurrent(struct SDL_Window *, void *);
extern void ks_SDL_GL_SwapWindow(struct SDL_Window *);
extern int ks_SDL_Vulkan_LoadLibrary(const char *);
extern int ks_SDL_PollEvent(union SDL_Event *);
extern int ks_SDL_PeepEvents(union SDL_Event *, int, int, unsigned int, unsigned int);
extern const unsigned char *ks_SDL_GetKeyboardState(int *);
extern unsigned int ks_SDL_GetMouseState(int *, int *);
extern unsigned int ks_SDL_GetRelativeMouseState(int *, int *);
extern int ks_SDL_UpperBlit(struct SDL_Surface *, const struct SDL_Rect *, struct SDL_Surface *, struct SDL_Rect *);
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

int SDL_Init(unsigned int flags) { return ks_SDL_Init(flags); }
int SDL_InitSubSystem(unsigned int flags) { return ks_SDL_InitSubSystem(flags); }
void SDL_QuitSubSystem(unsigned int flags) { ks_SDL_QuitSubSystem(flags); }
void SDL_Quit(void) { ks_SDL_Quit(); }
struct SDL_Window *SDL_CreateWindow(const char *title, int x, int y, int w, int h, unsigned int flags) { return ks_SDL_CreateWindow(title, x, y, w, h, flags); }
unsigned int SDL_GetWindowFlags(struct SDL_Window *window) { return ks_SDL_GetWindowFlags(window); }
void SDL_ShowWindow(struct SDL_Window *window) { ks_SDL_ShowWindow(window); }
void SDL_HideWindow(struct SDL_Window *window) { ks_SDL_HideWindow(window); }
void SDL_MinimizeWindow(struct SDL_Window *window) { ks_SDL_MinimizeWindow(window); }
void SDL_RestoreWindow(struct SDL_Window *window) { ks_SDL_RestoreWindow(window); }
void SDL_RaiseWindow(struct SDL_Window *window) { ks_SDL_RaiseWindow(window); }
void SDL_DestroyWindow(struct SDL_Window *window) { ks_SDL_DestroyWindow(window); }
struct SDL_Renderer *SDL_CreateRenderer(struct SDL_Window *window, int index, unsigned int flags) { return ks_SDL_CreateRenderer(window, index, flags); }
int SDL_GetRendererInfo(struct SDL_Renderer *renderer, struct SDL_RendererInfo *info) { return ks_SDL_GetRendererInfo(renderer, info); }
void SDL_DestroyRenderer(struct SDL_Renderer *renderer) { ks_SDL_DestroyRenderer(renderer); }
struct SDL_Texture *SDL_CreateTexture(struct SDL_Renderer *renderer, unsigned int format, int access, int w, int h) { return ks_SDL_CreateTexture(renderer, format, access, w, h); }
struct SDL_Texture *SDL_CreateTextureFromSurface(struct SDL_Renderer *renderer, struct SDL_Surface *surface) { return ks_SDL_CreateTextureFromSurface(renderer, surface); }
void SDL_DestroyTexture(struct SDL_Texture *texture) { ks_SDL_DestroyTexture(texture); }
int SDL_UpdateTexture(struct SDL_Texture *texture, const struct SDL_Rect *rect, const void *pixels, int pitch) { return ks_SDL_UpdateTexture(texture, rect, pixels, pitch); }
int SDL_UpdateYUVTexture(struct SDL_Texture *texture, const struct SDL_Rect *rect, const unsigned char *yplane, int ypitch, const unsigned char *uplane, int upitch, const unsigned char *vplane, int vpitch) { return ks_SDL_UpdateYUVTexture(texture, rect, yplane, ypitch, uplane, upitch, vplane, vpitch); }
int SDL_UpdateNVTexture(struct SDL_Texture *texture, const struct SDL_Rect *rect, const unsigned char *yplane, int ypitch, const unsigned char *uvplane, int uvpitch) { return ks_SDL_UpdateNVTexture(texture, rect, yplane, ypitch, uvplane, uvpitch); }
int SDL_LockTexture(struct SDL_Texture *texture, const struct SDL_Rect *rect, void **pixels, int *pitch) { return ks_SDL_LockTexture(texture, rect, pixels, pitch); }
void SDL_UnlockTexture(struct SDL_Texture *texture) { ks_SDL_UnlockTexture(texture); }
int SDL_SetTextureColorMod(struct SDL_Texture *texture, unsigned char r, unsigned char g, unsigned char b) { return ks_SDL_SetTextureColorMod(texture, r, g, b); }
int SDL_SetTextureAlphaMod(struct SDL_Texture *texture, unsigned char a) { return ks_SDL_SetTextureAlphaMod(texture, a); }
int SDL_SetTextureBlendMode(struct SDL_Texture *texture, int blendMode) { return ks_SDL_SetTextureBlendMode(texture, blendMode); }
int SDL_SetRenderDrawColor(struct SDL_Renderer *renderer, unsigned char r, unsigned char g, unsigned char b, unsigned char a) { return ks_SDL_SetRenderDrawColor(renderer, r, g, b, a); }
int SDL_RenderClear(struct SDL_Renderer *renderer) { return ks_SDL_RenderClear(renderer); }
int SDL_RenderCopy(struct SDL_Renderer *renderer, struct SDL_Texture *texture, const struct SDL_Rect *srcrect, const struct SDL_Rect *dstrect) { return ks_SDL_RenderCopy(renderer, texture, srcrect, dstrect); }
int SDL_RenderCopyEx(struct SDL_Renderer *renderer, struct SDL_Texture *texture, const struct SDL_Rect *srcrect, const struct SDL_Rect *dstrect, double angle, const struct SDL_Point *center, int flip) { return ks_SDL_RenderCopyEx(renderer, texture, srcrect, dstrect, angle, center, flip); }
int SDL_RenderGeometryRaw(struct SDL_Renderer *renderer, struct SDL_Texture *texture, const float *xy, int xy_stride, const struct SDL_Color *color, int color_stride, const float *uv, int uv_stride, int num_vertices, const void *indices, int num_indices, int size_indices) { return ks_SDL_RenderGeometryRaw(renderer, texture, xy, xy_stride, color, color_stride, uv, uv_stride, num_vertices, indices, num_indices, size_indices); }
void SDL_RenderPresent(struct SDL_Renderer *renderer) { ks_SDL_RenderPresent(renderer); }
int SDL_RenderFillRect(struct SDL_Renderer *renderer, const struct SDL_Rect *rect) { return ks_SDL_RenderFillRect(renderer, rect); }
int SDL_RenderDrawPoint(struct SDL_Renderer *renderer, int x, int y) { return ks_SDL_RenderDrawPoint(renderer, x, y); }
int SDL_RenderDrawLine(struct SDL_Renderer *renderer, int x1, int y1, int x2, int y2) { return ks_SDL_RenderDrawLine(renderer, x1, y1, x2, y2); }
int SDL_RenderSetViewport(struct SDL_Renderer *renderer, const struct SDL_Rect *rect) { return ks_SDL_RenderSetViewport(renderer, rect); }
int SDL_RenderSetClipRect(struct SDL_Renderer *renderer, const struct SDL_Rect *rect) { return ks_SDL_RenderSetClipRect(renderer, rect); }
void *SDL_GL_CreateContext(struct SDL_Window *window) { return ks_SDL_GL_CreateContext(window); }
int SDL_GL_MakeCurrent(struct SDL_Window *window, void *context) { return ks_SDL_GL_MakeCurrent(window, context); }
void SDL_GL_SwapWindow(struct SDL_Window *window) { ks_SDL_GL_SwapWindow(window); }
int SDL_Vulkan_LoadLibrary(const char *path) { return ks_SDL_Vulkan_LoadLibrary(path); }
int SDL_PollEvent(union SDL_Event *event) { return ks_SDL_PollEvent(event); }
int SDL_PeepEvents(union SDL_Event *events, int numevents, int action, unsigned int minType, unsigned int maxType) { return ks_SDL_PeepEvents(events, numevents, action, minType, maxType); }
const unsigned char *SDL_GetKeyboardState(int *numkeys) { return ks_SDL_GetKeyboardState(numkeys); }
unsigned int SDL_GetMouseState(int *x, int *y) { return ks_SDL_GetMouseState(x, y); }
unsigned int SDL_GetRelativeMouseState(int *x, int *y) { return ks_SDL_GetRelativeMouseState(x, y); }
int SDL_UpperBlit(struct SDL_Surface *src, const struct SDL_Rect *srcrect, struct SDL_Surface *dst, struct SDL_Rect *dstrect) { return ks_SDL_UpperBlit(src, srcrect, dst, dstrect); }
void *dlopen(const char *path, int mode) { return ks_dlopen(path, mode); }

#endif
