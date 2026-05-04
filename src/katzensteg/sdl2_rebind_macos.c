#if defined(__APPLE__)

#include "darwin_rebinder.h"

#include <stddef.h>

#define KS_DECLARE_REPLACEMENT(name) extern void ks_##name(void); extern void *ks_real_macos_slot_##name
#define KS_DECLARE_CAPTURE(name) extern void *ks_real_macos_slot_##name
#define KS_REPLACE(name) { #name, (void *)ks_##name, &ks_real_macos_slot_##name }
#define KS_CAPTURE(name) { #name, NULL, &ks_real_macos_slot_##name }

// REPLACE symbols route target-app calls through Katzensteg wrappers. CAPTURE
// symbols leave target-app calls alone and only seed ks_real_* slots used by
// Katzensteg internals.
KS_DECLARE_REPLACEMENT(SDL_Init);
KS_DECLARE_REPLACEMENT(SDL_InitSubSystem);
KS_DECLARE_REPLACEMENT(SDL_SetHint);
KS_DECLARE_REPLACEMENT(SDL_QuitSubSystem);
KS_DECLARE_REPLACEMENT(SDL_Quit);
KS_DECLARE_REPLACEMENT(SDL_CreateWindow);
KS_DECLARE_REPLACEMENT(SDL_GetWindowFlags);
KS_DECLARE_REPLACEMENT(SDL_SetWindowSize);
KS_DECLARE_REPLACEMENT(SDL_ShowWindow);
KS_DECLARE_REPLACEMENT(SDL_HideWindow);
KS_DECLARE_REPLACEMENT(SDL_MinimizeWindow);
KS_DECLARE_REPLACEMENT(SDL_RestoreWindow);
KS_DECLARE_REPLACEMENT(SDL_RaiseWindow);
KS_DECLARE_REPLACEMENT(SDL_DestroyWindow);
KS_DECLARE_REPLACEMENT(SDL_CreateRenderer);
KS_DECLARE_REPLACEMENT(SDL_GetRendererInfo);
KS_DECLARE_REPLACEMENT(SDL_DestroyRenderer);
KS_DECLARE_REPLACEMENT(SDL_CreateTexture);
KS_DECLARE_REPLACEMENT(SDL_CreateTextureFromSurface);
KS_DECLARE_REPLACEMENT(SDL_DestroyTexture);
KS_DECLARE_REPLACEMENT(SDL_UpdateTexture);
KS_DECLARE_REPLACEMENT(SDL_UpdateYUVTexture);
KS_DECLARE_REPLACEMENT(SDL_UpdateNVTexture);
KS_DECLARE_REPLACEMENT(SDL_LockTexture);
KS_DECLARE_REPLACEMENT(SDL_UnlockTexture);
KS_DECLARE_REPLACEMENT(SDL_SetTextureColorMod);
KS_DECLARE_REPLACEMENT(SDL_SetTextureAlphaMod);
KS_DECLARE_REPLACEMENT(SDL_SetTextureBlendMode);
KS_DECLARE_REPLACEMENT(SDL_SetRenderDrawColor);
KS_DECLARE_REPLACEMENT(SDL_RenderClear);
KS_DECLARE_REPLACEMENT(SDL_RenderFillRect);
KS_DECLARE_REPLACEMENT(SDL_RenderDrawPoint);
KS_DECLARE_REPLACEMENT(SDL_RenderDrawLine);
KS_DECLARE_REPLACEMENT(SDL_RenderSetViewport);
KS_DECLARE_REPLACEMENT(SDL_RenderSetClipRect);
KS_DECLARE_REPLACEMENT(SDL_RenderCopy);
KS_DECLARE_REPLACEMENT(SDL_RenderCopyEx);
KS_DECLARE_REPLACEMENT(SDL_RenderGeometryRaw);
KS_DECLARE_REPLACEMENT(SDL_RenderPresent);
KS_DECLARE_REPLACEMENT(SDL_GL_CreateContext);
KS_DECLARE_REPLACEMENT(SDL_GL_MakeCurrent);
KS_DECLARE_REPLACEMENT(SDL_GL_SwapWindow);
KS_DECLARE_REPLACEMENT(SDL_Vulkan_LoadLibrary);
KS_DECLARE_REPLACEMENT(SDL_PumpEvents);
KS_DECLARE_REPLACEMENT(SDL_PollEvent);
KS_DECLARE_REPLACEMENT(SDL_PeepEvents);
KS_DECLARE_REPLACEMENT(SDL_GetKeyboardState);
KS_DECLARE_REPLACEMENT(SDL_GetMouseState);
KS_DECLARE_REPLACEMENT(SDL_GetRelativeMouseState);
KS_DECLARE_REPLACEMENT(SDL_UpperBlit);
KS_DECLARE_REPLACEMENT(SDL_CreateColorCursor);
KS_DECLARE_REPLACEMENT(SDL_SetCursor);
KS_DECLARE_REPLACEMENT(SDL_ShowCursor);
KS_DECLARE_REPLACEMENT(SDL_FreeCursor);

KS_DECLARE_CAPTURE(SDL_GetWindowID);
KS_DECLARE_CAPTURE(SDL_QueryTexture);
KS_DECLARE_CAPTURE(SDL_GL_GetDrawableSize);
KS_DECLARE_CAPTURE(SDL_GetMouseFocus);
KS_DECLARE_CAPTURE(SDL_GetTicks);
KS_DECLARE_CAPTURE(SDL_ConvertSurfaceFormat);
KS_DECLARE_CAPTURE(SDL_FreeSurface);
KS_DECLARE_CAPTURE(SDL_GetError);

extern void *ks_dlopen(const char *, int);
extern void *ks_real_macos_slot_dlopen;

static const struct ks_darwin_rebinding sdl2_rebindings[] = {
    KS_REPLACE(SDL_Init),
    KS_REPLACE(SDL_InitSubSystem),
    KS_REPLACE(SDL_SetHint),
    KS_REPLACE(SDL_QuitSubSystem),
    KS_REPLACE(SDL_Quit),
    KS_REPLACE(SDL_CreateWindow),
    KS_CAPTURE(SDL_GetWindowID),
    KS_REPLACE(SDL_GetWindowFlags),
    KS_REPLACE(SDL_SetWindowSize),
    KS_REPLACE(SDL_ShowWindow),
    KS_REPLACE(SDL_HideWindow),
    KS_REPLACE(SDL_MinimizeWindow),
    KS_REPLACE(SDL_RestoreWindow),
    KS_REPLACE(SDL_RaiseWindow),
    KS_REPLACE(SDL_DestroyWindow),
    KS_REPLACE(SDL_CreateRenderer),
    KS_REPLACE(SDL_GetRendererInfo),
    KS_REPLACE(SDL_DestroyRenderer),
    KS_REPLACE(SDL_CreateTexture),
    KS_REPLACE(SDL_CreateTextureFromSurface),
    KS_REPLACE(SDL_DestroyTexture),
    KS_REPLACE(SDL_UpdateTexture),
    KS_REPLACE(SDL_UpdateYUVTexture),
    KS_REPLACE(SDL_UpdateNVTexture),
    KS_REPLACE(SDL_LockTexture),
    KS_REPLACE(SDL_UnlockTexture),
    KS_REPLACE(SDL_SetTextureColorMod),
    KS_REPLACE(SDL_SetTextureAlphaMod),
    KS_REPLACE(SDL_SetTextureBlendMode),
    KS_REPLACE(SDL_SetRenderDrawColor),
    KS_REPLACE(SDL_RenderClear),
    KS_REPLACE(SDL_RenderFillRect),
    KS_REPLACE(SDL_RenderDrawPoint),
    KS_REPLACE(SDL_RenderDrawLine),
    KS_REPLACE(SDL_RenderSetViewport),
    KS_REPLACE(SDL_RenderSetClipRect),
    KS_REPLACE(SDL_RenderCopy),
    KS_REPLACE(SDL_RenderCopyEx),
    KS_REPLACE(SDL_RenderGeometryRaw),
    KS_REPLACE(SDL_RenderPresent),
    KS_REPLACE(SDL_GL_CreateContext),
    KS_REPLACE(SDL_GL_MakeCurrent),
    KS_CAPTURE(SDL_GL_GetDrawableSize),
    KS_REPLACE(SDL_GL_SwapWindow),
    KS_REPLACE(SDL_Vulkan_LoadLibrary),
    KS_REPLACE(SDL_PumpEvents),
    KS_REPLACE(SDL_PollEvent),
    KS_REPLACE(SDL_PeepEvents),
    KS_REPLACE(SDL_GetKeyboardState),
    KS_CAPTURE(SDL_GetMouseFocus),
    KS_REPLACE(SDL_GetMouseState),
    KS_REPLACE(SDL_GetRelativeMouseState),
    KS_CAPTURE(SDL_GetTicks),
    KS_CAPTURE(SDL_ConvertSurfaceFormat),
    KS_CAPTURE(SDL_FreeSurface),
    KS_REPLACE(SDL_UpperBlit),
    KS_REPLACE(SDL_CreateColorCursor),
    KS_REPLACE(SDL_SetCursor),
    KS_REPLACE(SDL_ShowCursor),
    KS_REPLACE(SDL_FreeCursor),
    KS_CAPTURE(SDL_GetError),
    KS_CAPTURE(SDL_QueryTexture),
    { "dlopen", (void *)ks_dlopen, &ks_real_macos_slot_dlopen },
};

void ks_macos_register_sdl2_rebindings(void) {
    ks_darwin_register_rebindings(sdl2_rebindings, (unsigned int)(sizeof(sdl2_rebindings) / sizeof(sdl2_rebindings[0])));
}

#endif
