/* A real SDL app used across the public launcher and independent input ABI. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#ifdef USE_SDL3
#include <SDL3/SDL.h>
#define INIT_OK SDL_Init(SDL_INIT_VIDEO)
#define SDL_KEYDOWN SDL_EVENT_KEY_DOWN
#define SDL_KEYUP SDL_EVENT_KEY_UP
#define SDL_TEXTINPUT SDL_EVENT_TEXT_INPUT
#define SDL_MOUSEBUTTONDOWN SDL_EVENT_MOUSE_BUTTON_DOWN
#define SDL_MOUSEBUTTONUP SDL_EVENT_MOUSE_BUTTON_UP
#define SDL_MOUSEMOTION SDL_EVENT_MOUSE_MOTION
#define SDL_MOUSEWHEEL SDL_EVENT_MOUSE_WHEEL
#define KEY_SCAN(e) ((e).key.scancode)
#define KEY_CODE(e) ((e).key.key)
#define KEY_MODS(e) ((e).key.mod)
#else
#include <SDL2/SDL.h>
#define INIT_OK (SDL_Init(SDL_INIT_VIDEO) == 0)
#define KEY_SCAN(e) ((e).key.keysym.scancode)
#define KEY_CODE(e) ((e).key.keysym.sym)
#define KEY_MODS(e) ((e).key.keysym.mod)
#endif
static void text_hex(const char *text) {
  fputs("{\"event\":\"text\",\"hex\":\"", stdout);
  for (const unsigned char *p = (const unsigned char *)text; *p; ++p) printf("%02x", *p);
  puts("\"}");
}
int main(void) {
  setvbuf(stdout, NULL, _IOLBF, 0);
  if (!INIT_OK) { fprintf(stderr, "SDL_Init: %s\n", SDL_GetError()); return 1; }
#ifdef USE_SDL3
  SDL_Window *window = SDL_CreateWindow("Jackstay input acceptance", 640, 480, 0);
  SDL_Renderer *renderer = SDL_CreateRenderer(window, "software");
  SDL_StartTextInput(window);
#else
  SDL_Window *window = SDL_CreateWindow("Jackstay input acceptance", 0, 0, 640, 480, 0);
  SDL_Renderer *renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_SOFTWARE);
  SDL_StartTextInput();
#endif
  if (!window || !renderer) { fprintf(stderr, "SDL setup: %s\n", SDL_GetError()); return 2; }
  fcntl(STDIN_FILENO, F_SETFL, O_NONBLOCK);
  puts("{\"event\":\"ready\"}");
  int running = 1, paused = 0, video = 1, state_only = 0;
  while (running) {
    char command;
    while (read(STDIN_FILENO, &command, 1) == 1) {
      if (command == 'q') running = 0;
      if (command == 'p') { paused = !paused; printf("{\"event\":\"paused\",\"value\":%d}\n", paused); }
      if (command == 'v') { video = !video; printf("{\"event\":\"video\",\"value\":%d}\n", video); }
      if (command == 'r') SDL_SetWindowSize(window, 800, 600);
      if (command == 's') state_only = !state_only;
      if (command == 'm') state_only = 2;
    }
    if (!paused) {
      if (state_only) {
        SDL_PumpEvents();
        const void *keys = state_only == 2 ? NULL : SDL_GetKeyboardState(NULL);
        unsigned buttons = SDL_GetMouseState(NULL, NULL);
        unsigned mods = SDL_GetModState();
        printf("{\"event\":\"state\",\"a\":%d,\"shift\":%d,\"buttons\":%u,\"mods\":%u}\n", keys ? ((const unsigned char *)keys)[SDL_SCANCODE_A] != 0 : 0, keys ? ((const unsigned char *)keys)[SDL_SCANCODE_LSHIFT] != 0 : (mods & 3) != 0, buttons, mods);
      } else {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
          switch (e.type) {
            case SDL_KEYDOWN: case SDL_KEYUP:
              printf("{\"event\":\"key\",\"down\":%d,\"scan\":%d,\"key\":%d,\"mods\":%u,\"repeat\":%d}\n", e.type == SDL_KEYDOWN, KEY_SCAN(e), KEY_CODE(e), KEY_MODS(e), e.key.repeat != 0); break;
            case SDL_TEXTINPUT: text_hex(e.text.text); break;
            case SDL_MOUSEBUTTONDOWN: case SDL_MOUSEBUTTONUP:
              printf("{\"event\":\"button\",\"down\":%d,\"button\":%d}\n", e.type == SDL_MOUSEBUTTONDOWN, e.button.button); break;
            case SDL_MOUSEMOTION:
              printf("{\"event\":\"motion\",\"x\":%.3f,\"y\":%.3f}\n", (double)e.motion.x, (double)e.motion.y); break;
            case SDL_MOUSEWHEEL:
#ifdef USE_SDL3
              printf("{\"event\":\"scroll\",\"x\":%.3f,\"y\":%.3f}\n", (double)e.wheel.x, (double)e.wheel.y); break;
#else
              printf("{\"event\":\"scroll\",\"x\":%.3f,\"y\":%.3f}\n", (double)e.wheel.preciseX, (double)e.wheel.preciseY); break;
#endif
          }
        }
      }
    }
    if (video) { SDL_SetRenderDrawColor(renderer, 30, 70, 110, 255); SDL_RenderClear(renderer); SDL_RenderPresent(renderer); }
    SDL_Delay(5);
  }
  SDL_DestroyRenderer(renderer); SDL_DestroyWindow(window); SDL_Quit();
  return 0;
}
