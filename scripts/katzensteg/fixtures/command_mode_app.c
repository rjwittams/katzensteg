/* Command-mode acceptance: a real SDL app with an optional uncooperative exit. */
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <unistd.h>
#ifdef USE_SDL3
#include <SDL3/SDL.h>
#define KEYDOWN SDL_EVENT_KEY_DOWN
#define KEYUP SDL_EVENT_KEY_UP
#define QUIT SDL_EVENT_QUIT
#define SCAN(e) ((e).key.scancode)
#define TEXT SDL_EVENT_TEXT_INPUT
#else
#include <SDL2/SDL.h>
#define KEYDOWN SDL_KEYDOWN
#define KEYUP SDL_KEYUP
#define QUIT SDL_QUIT
#define SCAN(e) ((e).key.keysym.scancode)
#define TEXT SDL_TEXTINPUT
#endif
int main(void) {
    FILE *report = fopen(getenv("KS_COMMAND_REPORT"), "w");
    if (!report) return 2;
    setvbuf(report, NULL, _IOLBF, 0);
    int ignore = getenv("KS_IGNORE_QUIT") != NULL;
    if (ignore) signal(SIGTERM, SIG_IGN);
#ifdef USE_SDL3
    if (!SDL_Init(SDL_INIT_VIDEO)) return 3;
    SDL_Window *window = SDL_CreateWindow("command test", 320, 240, 0);
    SDL_Renderer *renderer = SDL_CreateRenderer(window, "software");
#else
    if (SDL_Init(SDL_INIT_VIDEO) != 0) return 3;
    SDL_Window *window = SDL_CreateWindow("command test", 0, 0, 320, 240, 0);
    SDL_Renderer *renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_SOFTWARE);
#endif
    if (!window || !renderer) return 4;
    SDL_RenderClear(renderer);
    SDL_RenderPresent(renderer);
    fprintf(report, "ready %d\n", getpid());
    for (;;) {
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            if (event.type == QUIT) {
                fputs("quit\n", report);
                if (!ignore) { SDL_Quit(); fclose(report); return 0; }
            }
            if (event.type == KEYDOWN || event.type == KEYUP)
                fprintf(report, "key %d %d\n", SCAN(event), event.type == KEYDOWN);
            if (event.type == TEXT) fprintf(report, "text %s\n", event.text.text);
#ifdef USE_SDL3
            int focus = event.type == SDL_EVENT_WINDOW_FOCUS_GAINED ? 1 : event.type == SDL_EVENT_WINDOW_FOCUS_LOST ? 0 : -1;
#else
            int focus = event.type != SDL_WINDOWEVENT ? -1 : event.window.event == SDL_WINDOWEVENT_FOCUS_GAINED ? 1 : event.window.event == SDL_WINDOWEVENT_FOCUS_LOST ? 0 : -1;
#endif
            if (focus >= 0) {
                const void *keys = SDL_GetKeyboardState(NULL);
                fprintf(report, "focus %d keys %d buttons %u flags %d\n", focus,
                    ((const unsigned char *)keys)[SDL_SCANCODE_W] != 0,
                    (unsigned)SDL_GetMouseState(NULL, NULL),
                    (SDL_GetWindowFlags(window) & SDL_WINDOW_INPUT_FOCUS) != 0);
            }
        }
        SDL_Delay(5);
    }
}
