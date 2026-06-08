#include <SDL3/SDL.h>

#include <dlfcn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
    DEFAULT_WINDOW_WIDTH = 960,
    DEFAULT_WINDOW_HEIGHT = 540,
    DEFAULT_RUN_SECONDS = 12,
};

typedef struct Options {
    int seconds;
    bool log_frames;
} Options;

typedef bool (*PFN_SDL_Init)(SDL_InitFlags flags);
typedef void (*PFN_SDL_Quit)(void);
typedef const char *(*PFN_SDL_GetError)(void);
typedef SDL_Window *(*PFN_SDL_CreateWindow)(const char *title, int w, int h, SDL_WindowFlags flags);
typedef void (*PFN_SDL_DestroyWindow)(SDL_Window *window);
typedef SDL_Renderer *(*PFN_SDL_CreateRenderer)(SDL_Window *window, const char *name);
typedef void (*PFN_SDL_DestroyRenderer)(SDL_Renderer *renderer);
typedef bool (*PFN_SDL_SetRenderDrawColor)(SDL_Renderer *renderer, Uint8 r, Uint8 g, Uint8 b, Uint8 a);
typedef bool (*PFN_SDL_RenderClear)(SDL_Renderer *renderer);
typedef bool (*PFN_SDL_RenderPresent)(SDL_Renderer *renderer);
typedef bool (*PFN_SDL_PollEvent)(SDL_Event *event);
typedef Uint64 (*PFN_SDL_GetTicks)(void);
typedef void (*PFN_SDL_Delay)(Uint32 ms);

typedef struct SDL3Api {
    PFN_SDL_Init SDL_Init;
    PFN_SDL_Quit SDL_Quit;
    PFN_SDL_GetError SDL_GetError;
    PFN_SDL_CreateWindow SDL_CreateWindow;
    PFN_SDL_DestroyWindow SDL_DestroyWindow;
    PFN_SDL_CreateRenderer SDL_CreateRenderer;
    PFN_SDL_DestroyRenderer SDL_DestroyRenderer;
    PFN_SDL_SetRenderDrawColor SDL_SetRenderDrawColor;
    PFN_SDL_RenderClear SDL_RenderClear;
    PFN_SDL_RenderPresent SDL_RenderPresent;
    PFN_SDL_PollEvent SDL_PollEvent;
    PFN_SDL_GetTicks SDL_GetTicks;
    PFN_SDL_Delay SDL_Delay;
} SDL3Api;

static void usage(const char *argv0)
{
    fprintf(stderr, "usage: %s [--seconds N] [--log-frames]\n", argv0);
}

static bool parse_options(int argc, char **argv, Options *options)
{
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--seconds") == 0) {
            if (i + 1 >= argc) return false;
            options->seconds = atoi(argv[++i]);
            if (options->seconds <= 0) return false;
        } else if (strcmp(argv[i], "--log-frames") == 0) {
            options->log_frames = true;
        } else {
            return false;
        }
    }
    return true;
}

static void *load_symbol(void *handle, const char *name)
{
    dlerror();
    void *symbol = dlsym(handle, name);
    const char *error = dlerror();
    if (error != NULL) {
        fprintf(stderr, "katzensteg-dlopen-probe-sdl3: dlsym(%s) failed: %s\n", name, error);
        return NULL;
    }
    return symbol;
}

static bool resolve_api(void *handle, SDL3Api *api)
{
    api->SDL_Init = (PFN_SDL_Init)load_symbol(handle, "SDL_Init");
    api->SDL_Quit = (PFN_SDL_Quit)load_symbol(handle, "SDL_Quit");
    api->SDL_GetError = (PFN_SDL_GetError)load_symbol(handle, "SDL_GetError");
    api->SDL_CreateWindow = (PFN_SDL_CreateWindow)load_symbol(handle, "SDL_CreateWindow");
    api->SDL_DestroyWindow = (PFN_SDL_DestroyWindow)load_symbol(handle, "SDL_DestroyWindow");
    api->SDL_CreateRenderer = (PFN_SDL_CreateRenderer)load_symbol(handle, "SDL_CreateRenderer");
    api->SDL_DestroyRenderer = (PFN_SDL_DestroyRenderer)load_symbol(handle, "SDL_DestroyRenderer");
    api->SDL_SetRenderDrawColor = (PFN_SDL_SetRenderDrawColor)load_symbol(handle, "SDL_SetRenderDrawColor");
    api->SDL_RenderClear = (PFN_SDL_RenderClear)load_symbol(handle, "SDL_RenderClear");
    api->SDL_RenderPresent = (PFN_SDL_RenderPresent)load_symbol(handle, "SDL_RenderPresent");
    api->SDL_PollEvent = (PFN_SDL_PollEvent)load_symbol(handle, "SDL_PollEvent");
    api->SDL_GetTicks = (PFN_SDL_GetTicks)load_symbol(handle, "SDL_GetTicks");
    api->SDL_Delay = (PFN_SDL_Delay)load_symbol(handle, "SDL_Delay");

    return api->SDL_Init != NULL &&
           api->SDL_Quit != NULL &&
           api->SDL_GetError != NULL &&
           api->SDL_CreateWindow != NULL &&
           api->SDL_DestroyWindow != NULL &&
           api->SDL_CreateRenderer != NULL &&
           api->SDL_DestroyRenderer != NULL &&
           api->SDL_SetRenderDrawColor != NULL &&
           api->SDL_RenderClear != NULL &&
           api->SDL_RenderPresent != NULL &&
           api->SDL_PollEvent != NULL &&
           api->SDL_GetTicks != NULL &&
           api->SDL_Delay != NULL;
}

static void *open_sdl3_library(const char **loaded_name)
{
    const char *override_path = getenv("KATZENSTEG_SDL3_DLOPEN_PATH");
#if defined(__APPLE__)
    const char *candidates[] = {
        override_path,
        "libSDL3.0.dylib",
        "libSDL3.dylib",
        "/opt/homebrew/lib/libSDL3.0.dylib",
        "/opt/homebrew/lib/libSDL3.dylib",
    };
#else
    const char *candidates[] = {
        override_path,
        "libSDL3.so.0",
        "libSDL3.so",
    };
#endif

    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        const char *candidate = candidates[i];
        if (candidate == NULL || candidate[0] == '\0') continue;
        dlerror();
        void *handle = dlopen(candidate, RTLD_NOW | RTLD_LOCAL);
        if (handle != NULL) {
            *loaded_name = candidate;
            return handle;
        }
    }

    const char *error = dlerror();
    fprintf(stderr,
            "katzensteg-dlopen-probe-sdl3: failed to dlopen SDL3 (%s)\n",
            error != NULL ? error : "unknown error");
    return NULL;
}

int main(int argc, char **argv)
{
    Options options = {
        .seconds = DEFAULT_RUN_SECONDS,
        .log_frames = false,
    };
    if (!parse_options(argc, argv, &options)) {
        usage(argv[0]);
        return 2;
    }

    const char *library_name = NULL;
    void *handle = open_sdl3_library(&library_name);
    if (handle == NULL) return 1;

    SDL3Api sdl = {0};
    if (!resolve_api(handle, &sdl)) {
        dlclose(handle);
        return 1;
    }
    fprintf(stderr, "katzensteg-dlopen-probe-sdl3: loaded SDL3 from %s\n", library_name);

    if (!sdl.SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS)) {
        fprintf(stderr, "katzensteg-dlopen-probe-sdl3: SDL_Init failed: %s\n", sdl.SDL_GetError());
        dlclose(handle);
        return 1;
    }

    SDL_Window *window = sdl.SDL_CreateWindow(
        "katzensteg-dlopen-probe-sdl3",
        DEFAULT_WINDOW_WIDTH,
        DEFAULT_WINDOW_HEIGHT,
        SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY);
    if (window == NULL) {
        fprintf(stderr, "katzensteg-dlopen-probe-sdl3: SDL_CreateWindow failed: %s\n", sdl.SDL_GetError());
        sdl.SDL_Quit();
        dlclose(handle);
        return 1;
    }

    SDL_Renderer *renderer = sdl.SDL_CreateRenderer(window, NULL);
    if (renderer == NULL) {
        fprintf(stderr, "katzensteg-dlopen-probe-sdl3: SDL_CreateRenderer failed: %s\n", sdl.SDL_GetError());
        sdl.SDL_DestroyWindow(window);
        sdl.SDL_Quit();
        dlclose(handle);
        return 1;
    }

    const Uint64 run_ms = (Uint64)options.seconds * 1000u;
    const Uint64 start = sdl.SDL_GetTicks();
    uint64_t frame = 0;
    bool running = true;

    while (running && (sdl.SDL_GetTicks() - start) < run_ms) {
        SDL_Event event;
        while (sdl.SDL_PollEvent(&event)) {
            if (event.type == SDL_EVENT_QUIT) running = false;
            if (event.type == SDL_EVENT_KEY_DOWN && event.key.key == SDLK_ESCAPE) running = false;
        }

        const Uint8 r = (Uint8)((frame * 3u) % 255u);
        const Uint8 g = (Uint8)((frame * 5u) % 255u);
        const Uint8 b = (Uint8)((frame * 7u) % 255u);
        if (!sdl.SDL_SetRenderDrawColor(renderer, r, g, b, 255) ||
            !sdl.SDL_RenderClear(renderer) ||
            !sdl.SDL_RenderPresent(renderer)) {
            fprintf(stderr, "katzensteg-dlopen-probe-sdl3: render call failed: %s\n", sdl.SDL_GetError());
            break;
        }

        if (options.log_frames && (frame % 60u) == 0u) {
            fprintf(stderr, "katzensteg-dlopen-probe-sdl3: frame=%llu rgb=%u,%u,%u\n",
                    (unsigned long long)frame, (unsigned)r, (unsigned)g, (unsigned)b);
        }
        frame++;
        sdl.SDL_Delay(16);
    }

    sdl.SDL_DestroyRenderer(renderer);
    sdl.SDL_DestroyWindow(window);
    sdl.SDL_Quit();
    dlclose(handle);
    return 0;
}
