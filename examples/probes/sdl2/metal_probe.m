#include <SDL.h>
#include <SDL_metal.h>

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
    DEFAULT_WINDOW_WIDTH = 960,
    DEFAULT_WINDOW_HEIGHT = 540,
    DEFAULT_RUN_SECONDS = 20,
};

typedef struct Options {
    bool fullscreen_desktop;
    bool log_frames;
    int seconds;
} Options;

static void usage(const char *argv0)
{
    fprintf(stderr, "usage: %s [--fullscreen-desktop] [--log-frames] [--seconds N]\n", argv0);
}

static bool parse_options(int argc, char **argv, Options *options)
{
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--fullscreen-desktop") == 0) {
            options->fullscreen_desktop = true;
        } else if (strcmp(argv[i], "--log-frames") == 0) {
            options->log_frames = true;
        } else if (strcmp(argv[i], "--seconds") == 0) {
            if (i + 1 >= argc) return false;
            options->seconds = atoi(argv[++i]);
            if (options->seconds <= 0) return false;
        } else {
            return false;
        }
    }
    return true;
}

static double wave(unsigned frame, double phase)
{
    return 0.5 + 0.5 * sin((double)frame * 0.032 + phase);
}

static bool draw_frame(id<MTLCommandQueue> queue, CAMetalLayer *layer, unsigned frame)
{
    @autoreleasepool {
        id<CAMetalDrawable> drawable = [layer nextDrawable];
        if (drawable == nil) return false;

        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(
            0.06 + wave(frame, 0.0) * 0.60,
            0.05 + wave(frame, 2.1) * 0.55,
            0.08 + wave(frame, 4.2) * 0.65,
            1.0);

        id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> encoder = [command_buffer renderCommandEncoderWithDescriptor:pass];
        [encoder endEncoding];
        [command_buffer presentDrawable:drawable];
        [command_buffer commit];
    }
    return true;
}

int main(int argc, char **argv)
{
    Options options = {
        .fullscreen_desktop = false,
        .log_frames = false,
        .seconds = DEFAULT_RUN_SECONDS,
    };
    if (!parse_options(argc, argv, &options)) {
        usage(argv[0]);
        return 2;
    }

    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS) != 0) {
        fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        return 1;
    }

    Uint32 flags = SDL_WINDOW_METAL | SDL_WINDOW_SHOWN | SDL_WINDOW_ALLOW_HIGHDPI | SDL_WINDOW_RESIZABLE;
    if (options.fullscreen_desktop) flags |= SDL_WINDOW_FULLSCREEN_DESKTOP;

    SDL_Window *window = SDL_CreateWindow("katzensteg-metal-probe",
                                          SDL_WINDOWPOS_CENTERED,
                                          SDL_WINDOWPOS_CENTERED,
                                          DEFAULT_WINDOW_WIDTH,
                                          DEFAULT_WINDOW_HEIGHT,
                                          flags);
    if (window == NULL) {
        fprintf(stderr, "SDL_CreateWindow failed: %s\n", SDL_GetError());
        SDL_Quit();
        return 1;
    }

    SDL_MetalView view = SDL_Metal_CreateView(window);
    CAMetalLayer *layer = view != NULL ? (__bridge CAMetalLayer *)SDL_Metal_GetLayer(view) : nil;
    id<MTLDevice> device = layer.device ?: MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue = device != nil ? [device newCommandQueue] : nil;
    if (layer == nil || device == nil || queue == nil) {
        fprintf(stderr, "katzensteg-metal-probe: Metal setup failed: %s\n", SDL_GetError());
        if (view != NULL) SDL_Metal_DestroyView(view);
        SDL_DestroyWindow(window);
        SDL_Quit();
        return 1;
    }

    layer.device = device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = NO;

    int window_w = 0;
    int window_h = 0;
    int drawable_w = 0;
    int drawable_h = 0;
    SDL_GetWindowSize(window, &window_w, &window_h);
    SDL_Metal_GetDrawableSize(window, &drawable_w, &drawable_h);
    layer.drawableSize = CGSizeMake(drawable_w, drawable_h);
    fprintf(stderr, "katzensteg-metal-probe: window=%dx%d drawable=%dx%d fullscreen_desktop=%s\n",
            window_w,
            window_h,
            drawable_w,
            drawable_h,
            options.fullscreen_desktop ? "yes" : "no");

    const Uint32 start_ms = SDL_GetTicks();
    const Uint32 run_ms = (Uint32)options.seconds * 1000u;
    unsigned frame = 0;
    bool running = true;
    while (running && SDL_GetTicks() - start_ms < run_ms) {
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_QUIT) running = false;
            if (event.type == SDL_KEYDOWN && event.key.keysym.sym == SDLK_ESCAPE) running = false;
        }

        SDL_Metal_GetDrawableSize(window, &drawable_w, &drawable_h);
        layer.drawableSize = CGSizeMake(drawable_w, drawable_h);
        if (!draw_frame(queue, layer, frame)) {
            fprintf(stderr, "katzensteg-metal-probe: no drawable available\n");
            break;
        }

        if (options.log_frames && (frame % 60u) == 0u) {
            fprintf(stderr, "katzensteg-metal-probe: frame=%u drawable=%dx%d\n", frame, drawable_w, drawable_h);
        }
        frame++;
    }

    SDL_Metal_DestroyView(view);
    SDL_DestroyWindow(window);
    SDL_Quit();
    return 0;
}
