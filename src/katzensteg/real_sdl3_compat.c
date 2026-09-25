/* Helpers every SDL3 real-function backend provides beyond the X-macro
 * list, built beside real_sdl3_linux.c or dynapi_sdl3.c. */

#define KS_REAL(name, rettype, args, params) extern rettype ks_real_##name args;
#define KS_REAL_VOID(name, args, params) extern void ks_real_##name args;
#include "real_sdl3_functions.h"

// SDL3 removed SDL_QueryTexture. Keep the adapter's compatibility helper local
// and implement it through SDL3's size and property APIs.
int ks_real_SDL_QueryTexture(struct SDL_Texture *texture, unsigned int *format, int *access, int *w, int *h) {
    float width = 0, height = 0;
    if (!ks_real_SDL_GetTextureSize(texture, &width, &height)) return -1;
    unsigned int props = ks_real_SDL_GetTextureProperties(texture);
    if (w) *w = (int)width;
    if (h) *h = (int)height;
    if (format) *format = (unsigned int)ks_real_SDL_GetNumberProperty(props, "SDL.texture.format", 0);
    if (access) *access = (int)ks_real_SDL_GetNumberProperty(props, "SDL.texture.access", 0);
    return 0;
}
