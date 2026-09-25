/* SDL3 through SDL3_DYNAMIC_API. Slot numbers come from sdl3_dynapi_slots.h. */

#include "sdl3_dynapi_slots.h"

/* SDL3 3.4.16 src/dynapi/SDL_dynapi.c:28 and :66. */
#define KS_DYNAPI_VERSION 2u
#define KS_DYNAPI_ENV "SDL3_DYNAMIC_API"
#define KS_DYNAPI_SLOT(name) KS_SDL3_SLOT_##name
#define KS_DYNAPI_WRAPPERS "interpose_sdl3_dynapi_functions.h"
#define KS_DYNAPI_REAL "real_sdl3_functions.h"

#include "dynapi_glue.inc"
#include "real_sdl3_compat.h"
