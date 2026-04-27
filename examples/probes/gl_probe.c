#include <SDL.h>
#include <SDL_opengl.h>

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

static float wave(unsigned frame, float phase)
{
    return 0.5f + 0.5f * sinf((float)frame * 0.032f + phase);
}

static void cube_face(float r, float g, float b,
                      float x0, float y0, float z0,
                      float x1, float y1, float z1,
                      float x2, float y2, float z2,
                      float x3, float y3, float z3)
{
    glColor3f(r, g, b);
    glVertex3f(x0, y0, z0);
    glVertex3f(x1, y1, z1);
    glVertex3f(x2, y2, z2);
    glVertex3f(x3, y3, z3);
}

static void draw_cube(void)
{
    glBegin(GL_QUADS);
    cube_face(1.00f, 0.18f, 0.12f, -1.0f, -1.0f, 1.0f, 1.0f, -1.0f, 1.0f, 1.0f, 1.0f, 1.0f, -1.0f, 1.0f, 1.0f);
    cube_face(0.14f, 0.72f, 1.00f, 1.0f, -1.0f, -1.0f, -1.0f, -1.0f, -1.0f, -1.0f, 1.0f, -1.0f, 1.0f, 1.0f, -1.0f);
    cube_face(0.20f, 0.92f, 0.38f, -1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, -1.0f, -1.0f, 1.0f, -1.0f);
    cube_face(1.00f, 0.82f, 0.16f, -1.0f, -1.0f, -1.0f, 1.0f, -1.0f, -1.0f, 1.0f, -1.0f, 1.0f, -1.0f, -1.0f, 1.0f);
    cube_face(0.72f, 0.35f, 1.00f, 1.0f, -1.0f, 1.0f, 1.0f, -1.0f, -1.0f, 1.0f, 1.0f, -1.0f, 1.0f, 1.0f, 1.0f);
    cube_face(0.96f, 0.96f, 0.96f, -1.0f, -1.0f, -1.0f, -1.0f, -1.0f, 1.0f, -1.0f, 1.0f, 1.0f, -1.0f, 1.0f, -1.0f);
    glEnd();
}

static void draw_frame(unsigned frame, int drawable_w, int drawable_h)
{
    const float r = wave(frame, 0.0f);
    const float g = wave(frame, 2.1f);
    const float b = wave(frame, 4.2f);
    const float aspect = drawable_h > 0 ? (float)drawable_w / (float)drawable_h : 1.0f;
    const float angle = (float)frame * 1.25f;

    glViewport(0, 0, drawable_w, drawable_h);
    glDisable(GL_SCISSOR_TEST);
    glEnable(GL_DEPTH_TEST);
    glDepthFunc(GL_LEQUAL);
    glClearDepth(1.0);
    glClearColor(0.06f + r * 0.22f, 0.05f + g * 0.18f, 0.08f + b * 0.24f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    glFrustum(-aspect, aspect, -1.0, 1.0, 1.5, 20.0);

    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();
    glTranslatef(0.0f, 0.0f, -5.0f);
    glRotatef(angle, 0.35f, 1.0f, 0.15f);
    glRotatef(angle * 0.55f, 1.0f, 0.1f, 0.0f);

    draw_cube();
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

    SDL_GL_SetAttribute(SDL_GL_RED_SIZE, 8);
    SDL_GL_SetAttribute(SDL_GL_GREEN_SIZE, 8);
    SDL_GL_SetAttribute(SDL_GL_BLUE_SIZE, 8);
    SDL_GL_SetAttribute(SDL_GL_ALPHA_SIZE, 8);
    SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);

    Uint32 flags = SDL_WINDOW_OPENGL | SDL_WINDOW_SHOWN | SDL_WINDOW_ALLOW_HIGHDPI | SDL_WINDOW_RESIZABLE;
    if (options.fullscreen_desktop) flags |= SDL_WINDOW_FULLSCREEN_DESKTOP;

    SDL_Window *window = SDL_CreateWindow("katzensteg-gl-probe",
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

    SDL_GLContext context = SDL_GL_CreateContext(window);
    if (context == NULL) {
        fprintf(stderr, "SDL_GL_CreateContext failed: %s\n", SDL_GetError());
        SDL_DestroyWindow(window);
        SDL_Quit();
        return 1;
    }
    if (SDL_GL_MakeCurrent(window, context) != 0) {
        fprintf(stderr, "SDL_GL_MakeCurrent failed: %s\n", SDL_GetError());
        SDL_GL_DeleteContext(context);
        SDL_DestroyWindow(window);
        SDL_Quit();
        return 1;
    }
    SDL_GL_SetSwapInterval(1);

    int window_w = 0;
    int window_h = 0;
    int drawable_w = 0;
    int drawable_h = 0;
    SDL_GetWindowSize(window, &window_w, &window_h);
    SDL_GL_GetDrawableSize(window, &drawable_w, &drawable_h);
    fprintf(stderr, "katzensteg-gl-probe: window=%dx%d drawable=%dx%d fullscreen_desktop=%s\n",
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

        SDL_GL_GetDrawableSize(window, &drawable_w, &drawable_h);
        draw_frame(frame, drawable_w, drawable_h);
        SDL_GL_SwapWindow(window);

        if (options.log_frames && (frame % 60u) == 0u) {
            fprintf(stderr, "katzensteg-gl-probe: frame=%u drawable=%dx%d\n", frame, drawable_w, drawable_h);
        }
        frame++;
    }

    SDL_GL_DeleteContext(context);
    SDL_DestroyWindow(window);
    SDL_Quit();
    return 0;
}
