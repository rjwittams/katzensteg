/* Fixed-work rectangle workload for comparing preload CPU cost. */
#include <SDL2/SDL.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>

static double cpu_seconds(void) {
    struct rusage usage;
    getrusage(RUSAGE_SELF, &usage);
    return usage.ru_utime.tv_sec + usage.ru_stime.tv_sec +
           (usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000000.0;
}

int main(int argc, char **argv) {
    const int frames = argc > 1 ? atoi(argv[1]) : 120;
    const int rectangles = argc > 2 ? atoi(argv[2]) : 3000;
    if (frames <= 0 || rectangles <= 0 || SDL_Init(SDL_INIT_VIDEO) != 0) return 2;
    SDL_Window *window = SDL_CreateWindow("capture benchmark", 0, 0, 320, 240, 0);
    SDL_Renderer *renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_SOFTWARE);
    if (!window || !renderer) return 3;
    /* Finish initialization before measuring. */
    SDL_RenderClear(renderer);
    SDL_RenderPresent(renderer);
    SDL_Delay(100);
    double cpu_start = cpu_seconds();
    Uint64 start = SDL_GetPerformanceCounter();
    for (int frame = 0; frame < frames; ++frame) {
        SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
        SDL_RenderClear(renderer);
        SDL_SetRenderDrawColor(renderer, frame & 255, 128, 255, 255);
        for (int i = 0; i < rectangles; ++i) {
            SDL_Rect rect = {(i * 7) % 312, (i * 11) % 232, 8, 8};
            SDL_RenderFillRect(renderer, &rect);
        }
        SDL_RenderPresent(renderer);
        SDL_Delay(16);
    }
    /* Include the worker finishing the last frame in process CPU time. */
    SDL_Delay(100);
    double elapsed = (double)(SDL_GetPerformanceCounter() - start) / SDL_GetPerformanceFrequency();
    printf("{\"frames\":%d,\"rectangles\":%d,\"cpu_seconds\":%.6f,\"elapsed_seconds\":%.6f}\n",
           frames, rectangles, cpu_seconds() - cpu_start, elapsed);
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();
    return 0;
}
