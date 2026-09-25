/* SDL2 through SDL_DYNAMIC_API. Slot numbers come from sdl2_dynapi_slots.h. */

#include "sdl2_dynapi_slots.h"

/* SDL2 2.32.10 src/dynapi/SDL_dynapi.c:27 and :51. */
#define KS_DYNAPI_VERSION 1u
#define KS_DYNAPI_ENV "SDL_DYNAMIC_API"
#define KS_DYNAPI_SLOT(name) KS_SDL2_SLOT_##name
#define KS_DYNAPI_WRAPPERS "interpose_sdl2_dynapi_functions.h"
#define KS_DYNAPI_REAL "real_sdl2_functions.h"

#include "dynapi_glue.inc"
