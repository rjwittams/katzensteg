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
struct SDL_Rect;

extern struct SDL_Window *ks_SDL_CreateWindow(const char *, int, int, int, int, unsigned int);
extern void ks_SDL_DestroyWindow(struct SDL_Window *);
extern struct SDL_Renderer *ks_SDL_CreateRenderer(struct SDL_Window *, int, unsigned int);
extern void ks_SDL_DestroyRenderer(struct SDL_Renderer *);
extern struct SDL_Texture *ks_SDL_CreateTexture(struct SDL_Renderer *, unsigned int, int, int, int);
extern void ks_SDL_DestroyTexture(struct SDL_Texture *);
extern int ks_SDL_UpdateTexture(struct SDL_Texture *, const struct SDL_Rect *, const void *, int);
extern int ks_SDL_SetRenderDrawColor(struct SDL_Renderer *, unsigned char, unsigned char, unsigned char, unsigned char);
extern int ks_SDL_RenderClear(struct SDL_Renderer *);
extern int ks_SDL_RenderCopy(struct SDL_Renderer *, struct SDL_Texture *, const struct SDL_Rect *, const struct SDL_Rect *);
extern void ks_SDL_RenderPresent(struct SDL_Renderer *);

extern struct SDL_Window *SDL_CreateWindow(const char *, int, int, int, int, unsigned int);
extern void SDL_DestroyWindow(struct SDL_Window *);
extern struct SDL_Renderer *SDL_CreateRenderer(struct SDL_Window *, int, unsigned int);
extern void SDL_DestroyRenderer(struct SDL_Renderer *);
extern struct SDL_Texture *SDL_CreateTexture(struct SDL_Renderer *, unsigned int, int, int, int);
extern void SDL_DestroyTexture(struct SDL_Texture *);
extern int SDL_UpdateTexture(struct SDL_Texture *, const struct SDL_Rect *, const void *, int);
extern int SDL_SetRenderDrawColor(struct SDL_Renderer *, unsigned char, unsigned char, unsigned char, unsigned char);
extern int SDL_RenderClear(struct SDL_Renderer *);
extern int SDL_RenderCopy(struct SDL_Renderer *, struct SDL_Texture *, const struct SDL_Rect *, const struct SDL_Rect *);
extern void SDL_RenderPresent(struct SDL_Renderer *);

DYLD_INTERPOSE(ks_SDL_CreateWindow, SDL_CreateWindow)
DYLD_INTERPOSE(ks_SDL_DestroyWindow, SDL_DestroyWindow)
DYLD_INTERPOSE(ks_SDL_CreateRenderer, SDL_CreateRenderer)
DYLD_INTERPOSE(ks_SDL_DestroyRenderer, SDL_DestroyRenderer)
DYLD_INTERPOSE(ks_SDL_CreateTexture, SDL_CreateTexture)
DYLD_INTERPOSE(ks_SDL_DestroyTexture, SDL_DestroyTexture)
DYLD_INTERPOSE(ks_SDL_UpdateTexture, SDL_UpdateTexture)
DYLD_INTERPOSE(ks_SDL_SetRenderDrawColor, SDL_SetRenderDrawColor)
DYLD_INTERPOSE(ks_SDL_RenderClear, SDL_RenderClear)
DYLD_INTERPOSE(ks_SDL_RenderCopy, SDL_RenderCopy)
DYLD_INTERPOSE(ks_SDL_RenderPresent, SDL_RenderPresent)

#endif
