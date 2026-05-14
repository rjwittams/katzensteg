#include <SDL3/SDL.h>
#include <SDL3/SDL_gamepad.h>
#include <SDL3/SDL_joystick.h>
#include <SDL3/SDL_stdinc.h>

#include <ctype.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

enum {
    WINDOW_WIDTH = 800,
    WINDOW_HEIGHT = 520,
    MAX_EVENTS = 16,
    SUMMARY_LEN = 192,
};

typedef struct ProbeState {
    bool running;
    bool focused;
    bool custom_cursor;
    bool background_gamepad_hint_requested;
    bool log_events;
    int window_w;
    int window_h;
    int mouse_x;
    int mouse_y;
    uint32_t mouse_buttons;
    int wheel_x;
    int wheel_y;
    SDL_Keycode last_keycode;
    SDL_Scancode last_scancode;
    SDL_Keymod last_mods;
    char last_text[64];
    SDL_Gamepad *controller;
    SDL_Joystick *joystick;
    SDL_JoystickID input_instance_id;
    SDL_Surface *cursor_surface;
    SDL_Cursor *cursor;
    uint32_t cursor_pixels[32 * 32];
    char input_device_name[96];
    int controller_count;
    int joystick_count;
    int last_axis;
    int last_axis_value;
    int last_button;
    bool last_button_down;
    char summaries[MAX_EVENTS][SUMMARY_LEN];
    int summary_count;
    uint64_t event_count;
} ProbeState;

static void push_summary(ProbeState *state, const char *summary);

static void fill_cursor_pixels(uint32_t pixels[32 * 32])
{
    for (int y = 0; y < 32; y++) {
        for (int x = 0; x < 32; x++) {
            uint8_t r = 0;
            uint8_t g = 0;
            uint8_t b = 0;
            uint8_t a = 0;

            if (x <= 3 && y <= 22 && y >= x - 1) {
                r = 255;
                g = 255;
                b = 255;
                a = 255;
            }
            if ((x == 0 || y == 0 || x == 4 || y == 23) && x <= 5 && y <= 24) {
                r = 20;
                g = 20;
                b = 20;
                a = 255;
            }
            if (x >= 10 && x <= 25 && y >= 10 && y <= 25 && (x == 10 || x == 25 || y == 10 || y == 25)) {
                r = 255;
                g = 32;
                b = 120;
                a = 255;
            }
            if (x >= 14 && x <= 21 && y >= 14 && y <= 21) {
                r = 64;
                g = 220;
                b = 255;
                a = 180;
            }

            pixels[y * 32 + x] =
                ((uint32_t)a << 24) |
                ((uint32_t)b << 16) |
                ((uint32_t)g << 8) |
                (uint32_t)r;
        }
    }
}

static bool install_custom_cursor(ProbeState *state)
{
    fill_cursor_pixels(state->cursor_pixels);

    state->cursor_surface = SDL_CreateSurfaceFrom(
        32,
        32,
        SDL_PIXELFORMAT_RGBA32,
        state->cursor_pixels,
        32 * 4);
    if (state->cursor_surface == NULL) {
        fprintf(stderr, "SDL_CreateSurfaceFrom cursor failed: %s\n", SDL_GetError());
        return false;
    }

    state->cursor = SDL_CreateColorCursor(state->cursor_surface, 1, 1);
    if (state->cursor == NULL) {
        fprintf(stderr, "SDL_CreateColorCursor failed: %s\n", SDL_GetError());
        SDL_DestroySurface(state->cursor_surface);
        state->cursor_surface = NULL;
        return false;
    }

    SDL_SetCursor(state->cursor);
    SDL_ShowCursor();
    push_summary(state, "custom SDL color cursor installed");
    return true;
}

static void clear_custom_cursor(ProbeState *state)
{
    if (state->cursor != NULL) {
        SDL_DestroyCursor(state->cursor);
        state->cursor = NULL;
    }
    if (state->cursor_surface != NULL) {
        SDL_DestroySurface(state->cursor_surface);
        state->cursor_surface = NULL;
    }
}

static const char *window_event_name(uint32_t event)
{
    switch (event) {
    case SDL_EVENT_WINDOW_SHOWN: return "shown";
    case SDL_EVENT_WINDOW_HIDDEN: return "hidden";
    case SDL_EVENT_WINDOW_EXPOSED: return "exposed";
    case SDL_EVENT_WINDOW_MOVED: return "moved";
    case SDL_EVENT_WINDOW_RESIZED: return "resized";
    case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED: return "size_changed";
    case SDL_EVENT_WINDOW_MINIMIZED: return "minimized";
    case SDL_EVENT_WINDOW_MAXIMIZED: return "maximized";
    case SDL_EVENT_WINDOW_RESTORED: return "restored";
    case SDL_EVENT_WINDOW_MOUSE_ENTER: return "enter";
    case SDL_EVENT_WINDOW_MOUSE_LEAVE: return "leave";
    case SDL_EVENT_WINDOW_FOCUS_GAINED: return "focus_gained";
    case SDL_EVENT_WINDOW_FOCUS_LOST: return "focus_lost";
    case SDL_EVENT_WINDOW_CLOSE_REQUESTED: return "close";
    default: return "unknown";
    }
}

static void push_summary(ProbeState *state, const char *summary)
{
    if (state->summary_count < MAX_EVENTS) {
        state->summary_count++;
    }

    for (int i = state->summary_count - 1; i > 0; i--) {
        memcpy(state->summaries[i], state->summaries[i - 1], SUMMARY_LEN);
    }

    snprintf(state->summaries[0], SUMMARY_LEN, "%s", summary);
    state->event_count++;
    if (state->log_events) {
        fprintf(stderr, "%06llu %s\n", (unsigned long long)state->event_count, summary);
        fflush(stderr);
    }
}

static const char *safe_hint(const char *value)
{
    return value != NULL ? value : "unset";
}

static const char *safe_name(const char *value)
{
    return value != NULL ? value : "unknown";
}

static void close_input_device(ProbeState *state)
{
    if (state->controller != NULL) {
        SDL_CloseGamepad(state->controller);
        state->controller = NULL;
    }
    if (state->joystick != NULL) {
        SDL_CloseJoystick(state->joystick);
        state->joystick = NULL;
    }
    state->input_instance_id = -1;
    state->input_device_name[0] = '\0';
}

static void refresh_input_device(ProbeState *state)
{
    close_input_device(state);

    state->controller_count = 0;
    state->joystick_count = 0;

    int gamepad_count = 0;
    SDL_JoystickID *gamepads = SDL_GetGamepads(&gamepad_count);
    if (gamepads != NULL) {
        state->controller_count = gamepad_count;
        if (gamepad_count > 0) {
            state->controller = SDL_OpenGamepad(gamepads[0]);
            if (state->controller != NULL) {
                SDL_Joystick *joy = SDL_GetGamepadJoystick(state->controller);
                state->input_instance_id = joy != NULL ? SDL_GetJoystickID(joy) : 0;
                snprintf(state->input_device_name,
                         sizeof(state->input_device_name),
                         "controller:%s",
                         safe_name(SDL_GetGamepadName(state->controller)));
            }
        }
        SDL_free(gamepads);
    }

    int joystick_count = 0;
    SDL_JoystickID *joysticks = SDL_GetJoysticks(&joystick_count);
    if (joysticks != NULL) {
        state->joystick_count = joystick_count;
        if (state->controller == NULL && joystick_count > 0) {
            state->joystick = SDL_OpenJoystick(joysticks[0]);
            if (state->joystick != NULL) {
                state->input_instance_id = SDL_GetJoystickID(state->joystick);
                snprintf(state->input_device_name,
                         sizeof(state->input_device_name),
                         "joystick:%s",
                         safe_name(SDL_GetJoystickName(state->joystick)));
            }
        }
        SDL_free(joysticks);
    }
}

static void update_title(SDL_Window *window, const ProbeState *state)
{
    char title[256];
    const char *latest = state->summary_count > 0 ? state->summaries[0] : "waiting for input";
    snprintf(title,
             sizeof(title),
             "katzensteg-input-probe | mouse=%d,%d buttons=0x%x focus=%s | %s",
             state->mouse_x,
             state->mouse_y,
             state->mouse_buttons,
             state->focused ? "yes" : "no",
             latest);
    SDL_SetWindowTitle(window, title);
}

static void handle_event(SDL_Window *window, ProbeState *state, const SDL_Event *event)
{
    char summary[SUMMARY_LEN];

    switch (event->type) {
    case SDL_EVENT_QUIT:
        snprintf(summary, sizeof(summary), "quit");
        state->running = false;
        push_summary(state, summary);
        break;

    case SDL_EVENT_KEY_DOWN:
    case SDL_EVENT_KEY_UP: {
        const bool down = event->type == SDL_EVENT_KEY_DOWN;
        state->last_keycode = event->key.key;
        state->last_scancode = event->key.scancode;
        state->last_mods = event->key.mod;
        snprintf(summary,
                 sizeof(summary),
                 "key_%s key=%s code=%d scancode=%s scan=%d mods=0x%x repeat=%d",
                 down ? "down" : "up",
                 SDL_GetKeyName(state->last_keycode),
                 (int)state->last_keycode,
                 SDL_GetScancodeName(state->last_scancode),
                 (int)state->last_scancode,
                 (unsigned int)state->last_mods,
                 event->key.repeat);
        push_summary(state, summary);
        if (down && (state->last_keycode == SDLK_ESCAPE || state->last_keycode == SDLK_Q)) {
            state->running = false;
        }
        break;
    }

    case SDL_EVENT_TEXT_INPUT:
        snprintf(state->last_text, sizeof(state->last_text), "%s", event->text.text ? event->text.text : "");
        snprintf(summary, sizeof(summary), "text_input text=\"%s\"", state->last_text);
        push_summary(state, summary);
        break;

    case SDL_EVENT_MOUSE_MOTION:
        state->mouse_x = (int)event->motion.x;
        state->mouse_y = (int)event->motion.y;
        state->mouse_buttons = event->motion.state;
        snprintf(summary,
                 sizeof(summary),
                 "mouse_motion x=%d y=%d rel=%d,%d buttons=0x%x",
                 (int)event->motion.x,
                 (int)event->motion.y,
                 (int)event->motion.xrel,
                 (int)event->motion.yrel,
                 (unsigned)event->motion.state);
        push_summary(state, summary);
        break;

    case SDL_EVENT_MOUSE_BUTTON_DOWN:
    case SDL_EVENT_MOUSE_BUTTON_UP: {
        const bool down = event->type == SDL_EVENT_MOUSE_BUTTON_DOWN;
        state->mouse_x = (int)event->button.x;
        state->mouse_y = (int)event->button.y;
        state->mouse_buttons = SDL_GetMouseState(NULL, NULL);
        snprintf(summary,
                 sizeof(summary),
                 "mouse_button_%s button=%u clicks=%u x=%d y=%d buttons=0x%x",
                 down ? "down" : "up",
                 event->button.button,
                 event->button.clicks,
                 (int)event->button.x,
                 (int)event->button.y,
                 state->mouse_buttons);
        push_summary(state, summary);
        break;
    }

    case SDL_EVENT_MOUSE_WHEEL:
        state->wheel_x += event->wheel.integer_x;
        state->wheel_y += event->wheel.integer_y;
        snprintf(summary,
                 sizeof(summary),
                 "mouse_wheel x=%d y=%d precise=%g,%g direction=%u total=%d,%d",
                 event->wheel.integer_x,
                 event->wheel.integer_y,
                 event->wheel.x,
                 event->wheel.y,
                 event->wheel.direction,
                 state->wheel_x,
                 state->wheel_y);
        push_summary(state, summary);
        break;

    case SDL_EVENT_GAMEPAD_ADDED:
    case SDL_EVENT_GAMEPAD_REMOVED:
    case SDL_EVENT_JOYSTICK_ADDED:
    case SDL_EVENT_JOYSTICK_REMOVED:
        refresh_input_device(state);
        snprintf(summary,
                 sizeof(summary),
                 "input_device event=%u controllers=%d joysticks=%d active=%s id=%d",
                 event->type,
                 state->controller_count,
                 state->joystick_count,
                 state->input_device_name[0] ? state->input_device_name : "none",
                 (int)state->input_instance_id);
        push_summary(state, summary);
        break;

    case SDL_EVENT_GAMEPAD_BUTTON_DOWN:
    case SDL_EVENT_GAMEPAD_BUTTON_UP:
        state->last_button = event->gbutton.button;
        state->last_button_down = event->type == SDL_EVENT_GAMEPAD_BUTTON_DOWN;
        snprintf(summary,
                 sizeof(summary),
                 "controller_button_%s which=%d button=%u state=%u",
                 state->last_button_down ? "down" : "up",
                 (int)event->gbutton.which,
                 event->gbutton.button,
                 event->gbutton.down ? 1u : 0u);
        push_summary(state, summary);
        break;

    case SDL_EVENT_GAMEPAD_AXIS_MOTION:
        state->last_axis = event->gaxis.axis;
        state->last_axis_value = event->gaxis.value;
        snprintf(summary,
                 sizeof(summary),
                 "controller_axis which=%d axis=%u value=%d",
                 (int)event->gaxis.which,
                 event->gaxis.axis,
                 event->gaxis.value);
        push_summary(state, summary);
        break;

    case SDL_EVENT_JOYSTICK_BUTTON_DOWN:
    case SDL_EVENT_JOYSTICK_BUTTON_UP:
        state->last_button = event->jbutton.button;
        state->last_button_down = event->type == SDL_EVENT_JOYSTICK_BUTTON_DOWN;
        snprintf(summary,
                 sizeof(summary),
                 "joy_button_%s which=%d button=%u state=%u",
                 state->last_button_down ? "down" : "up",
                 (int)event->jbutton.which,
                 event->jbutton.button,
                 event->jbutton.down ? 1u : 0u);
        push_summary(state, summary);
        break;

    case SDL_EVENT_JOYSTICK_AXIS_MOTION:
        state->last_axis = event->jaxis.axis;
        state->last_axis_value = event->jaxis.value;
        snprintf(summary,
                 sizeof(summary),
                 "joy_axis which=%d axis=%u value=%d",
                 (int)event->jaxis.which,
                 event->jaxis.axis,
                 event->jaxis.value);
        push_summary(state, summary);
        break;

    case SDL_EVENT_WINDOW_FOCUS_GAINED:
    case SDL_EVENT_WINDOW_FOCUS_LOST:
    case SDL_EVENT_WINDOW_RESIZED:
    case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
    case SDL_EVENT_WINDOW_CLOSE_REQUESTED:
        if (event->type == SDL_EVENT_WINDOW_FOCUS_GAINED) {
            state->focused = true;
        }
        else if (event->type == SDL_EVENT_WINDOW_FOCUS_LOST) {
            state->focused = false;
        }
        else if (event->type == SDL_EVENT_WINDOW_RESIZED ||
                 event->type == SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED) {
            state->window_w = event->window.data1;
            state->window_h = event->window.data2;
        }
        else if (event->type == SDL_EVENT_WINDOW_CLOSE_REQUESTED) {
            state->running = false;
        }
        snprintf(summary,
                 sizeof(summary),
                 "window event=%s data=%d,%d",
                 window_event_name(event->type),
                 event->window.data1,
                 event->window.data2);
        push_summary(state, summary);
        break;

    default:
        snprintf(summary, sizeof(summary), "event type=%u", event->type);
        push_summary(state, summary);
        break;
    }

    update_title(window, state);
}

static void draw_bar(SDL_Renderer *renderer, int x, int y, int w, int h, uint8_t r, uint8_t g, uint8_t b)
{
    SDL_FRect rect = { (float)x, (float)y, (float)w, (float)h };
    SDL_SetRenderDrawColor(renderer, r, g, b, 255);
    SDL_RenderFillRect(renderer, &rect);
}

static uint8_t glyph_row(char c, int row)
{
    static const uint8_t digits[10][7] = {
        { 0x0e, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0e },
        { 0x04, 0x0c, 0x04, 0x04, 0x04, 0x04, 0x0e },
        { 0x0e, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1f },
        { 0x1e, 0x01, 0x01, 0x0e, 0x01, 0x01, 0x1e },
        { 0x02, 0x06, 0x0a, 0x12, 0x1f, 0x02, 0x02 },
        { 0x1f, 0x10, 0x10, 0x1e, 0x01, 0x01, 0x1e },
        { 0x06, 0x08, 0x10, 0x1e, 0x11, 0x11, 0x0e },
        { 0x1f, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08 },
        { 0x0e, 0x11, 0x11, 0x0e, 0x11, 0x11, 0x0e },
        { 0x0e, 0x11, 0x11, 0x0f, 0x01, 0x02, 0x0c },
    };
    static const uint8_t letters[26][7] = {
        { 0x0e, 0x11, 0x11, 0x1f, 0x11, 0x11, 0x11 },
        { 0x1e, 0x11, 0x11, 0x1e, 0x11, 0x11, 0x1e },
        { 0x0e, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0e },
        { 0x1e, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1e },
        { 0x1f, 0x10, 0x10, 0x1e, 0x10, 0x10, 0x1f },
        { 0x1f, 0x10, 0x10, 0x1e, 0x10, 0x10, 0x10 },
        { 0x0e, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0f },
        { 0x11, 0x11, 0x11, 0x1f, 0x11, 0x11, 0x11 },
        { 0x0e, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0e },
        { 0x01, 0x01, 0x01, 0x01, 0x11, 0x11, 0x0e },
        { 0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11 },
        { 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1f },
        { 0x11, 0x1b, 0x15, 0x15, 0x11, 0x11, 0x11 },
        { 0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11 },
        { 0x0e, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0e },
        { 0x1e, 0x11, 0x11, 0x1e, 0x10, 0x10, 0x10 },
        { 0x0e, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0d },
        { 0x1e, 0x11, 0x11, 0x1e, 0x14, 0x12, 0x11 },
        { 0x0f, 0x10, 0x10, 0x0e, 0x01, 0x01, 0x1e },
        { 0x1f, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04 },
        { 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0e },
        { 0x11, 0x11, 0x11, 0x11, 0x11, 0x0a, 0x04 },
        { 0x11, 0x11, 0x11, 0x15, 0x15, 0x15, 0x0a },
        { 0x11, 0x11, 0x0a, 0x04, 0x0a, 0x11, 0x11 },
        { 0x11, 0x11, 0x0a, 0x04, 0x04, 0x04, 0x04 },
        { 0x1f, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1f },
    };

    c = (char)toupper((unsigned char)c);
    if (c >= '0' && c <= '9') {
        return digits[c - '0'][row];
    }
    if (c >= 'A' && c <= 'Z') {
        return letters[c - 'A'][row];
    }

    switch (c) {
    case ' ': return 0x00;
    case '.': return row == 6 ? 0x04 : 0x00;
    case ',': return row == 5 ? 0x04 : row == 6 ? 0x08 : 0x00;
    case ':': return (row == 2 || row == 5) ? 0x04 : 0x00;
    case ';': return row == 2 ? 0x04 : row == 5 ? 0x04 : row == 6 ? 0x08 : 0x00;
    case '-': return row == 3 ? 0x1f : 0x00;
    case '_': return row == 6 ? 0x1f : 0x00;
    case '+': return row == 3 ? 0x0e : (row == 2 || row == 4) ? 0x04 : 0x00;
    case '=': return (row == 2 || row == 4) ? 0x1f : 0x00;
    case '/': return row < 2 ? 0x01 : row < 4 ? 0x02 : row < 6 ? 0x04 : 0x08;
    case '\\': return row < 2 ? 0x10 : row < 4 ? 0x08 : row < 6 ? 0x04 : 0x02;
    case '|': return 0x04;
    case '"': return row < 2 ? 0x0a : 0x00;
    case '\'': return row < 3 ? 0x04 : 0x00;
    case '(': return row == 0 ? 0x02 : row == 6 ? 0x02 : 0x04;
    case ')': return row == 0 ? 0x08 : row == 6 ? 0x08 : 0x04;
    case '[': return row == 0 || row == 6 ? 0x0e : 0x08;
    case ']': return row == 0 || row == 6 ? 0x0e : 0x02;
    case '<': return row < 3 ? (uint8_t)(0x04 >> row) : (uint8_t)(0x01 << (row - 3));
    case '>': return row < 3 ? (uint8_t)(0x04 << row) : (uint8_t)(0x10 >> (row - 3));
    case '!': return row < 5 ? 0x04 : row == 6 ? 0x04 : 0x00;
    case '?': return row == 0 ? 0x0e : row == 1 ? 0x11 : row == 2 ? 0x01 : row == 3 ? 0x02 : row == 4 ? 0x04 : row == 6 ? 0x04 : 0x00;
    case '*': return row == 1 ? 0x15 : row == 2 ? 0x0e : row == 3 ? 0x1f : row == 4 ? 0x0e : row == 5 ? 0x15 : 0x00;
    case '#': return (row == 1 || row == 5) ? 0x0a : (row == 2 || row == 4) ? 0x1f : 0x0a;
    case '%': return row == 0 ? 0x19 : row == 1 ? 0x1a : row == 2 ? 0x02 : row == 3 ? 0x04 : row == 4 ? 0x08 : row == 5 ? 0x0b : 0x13;
    case '&': return row == 0 ? 0x0c : row == 1 ? 0x12 : row == 2 ? 0x14 : row == 3 ? 0x08 : row == 4 ? 0x15 : row == 5 ? 0x12 : 0x0d;
    case '@': return row == 0 ? 0x0e : row == 1 ? 0x11 : row == 2 ? 0x17 : row == 3 ? 0x15 : row == 4 ? 0x17 : row == 5 ? 0x10 : 0x0e;
    default: return row == 0 || row == 6 ? 0x1f : (row == 1 || row == 5 ? 0x11 : 0x04);
    }
}

static void draw_text(SDL_Renderer *renderer, int x, int y, int scale, const char *text, uint8_t r, uint8_t g, uint8_t b)
{
    SDL_SetRenderDrawColor(renderer, r, g, b, 255);
    for (int i = 0; text[i] != '\0'; i++) {
        const char c = text[i];
        for (int row = 0; row < 7; row++) {
            const uint8_t bits = glyph_row(c, row);
            for (int col = 0; col < 5; col++) {
                if ((bits & (1u << (4 - col))) != 0) {
                    SDL_FRect rect = {
                        (float)(x + i * 6 * scale + col * scale),
                        (float)(y + row * scale),
                        (float)scale,
                        (float)scale
                    };
                    SDL_RenderFillRect(renderer, &rect);
                }
            }
        }
    }
}

static void draw_textf(SDL_Renderer *renderer, int x, int y, int scale, uint8_t r, uint8_t g, uint8_t b, const char *fmt, ...)
{
    char buf[256];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    draw_text(renderer, x, y, scale, buf, r, g, b);
}

static void render_probe(SDL_Renderer *renderer, const ProbeState *state, uint32_t tick)
{
    SDL_SetRenderDrawColor(renderer, 15, 17, 22, 255);
    SDL_RenderClear(renderer);

    SDL_SetRenderDrawColor(renderer, 38, 42, 52, 255);
    for (int x = 0; x < state->window_w; x += 40) {
        SDL_RenderLine(renderer, (float)x, 0.0f, (float)x, (float)state->window_h);
    }
    for (int y = 0; y < state->window_h; y += 40) {
        SDL_RenderLine(renderer, 0.0f, (float)y, (float)state->window_w, (float)y);
    }

    const int cx = state->mouse_x;
    const int cy = state->mouse_y;

    const int label_x = cx + 14 < state->window_w - 170 ? cx + 14 : cx - 170;
    const int label_y = cy + 14 < state->window_h - 26 ? cy + 14 : cy - 30;
    draw_bar(renderer, label_x - 4, label_y - 4, 160, 22, 20, 24, 32);
    draw_textf(renderer, label_x, label_y, 2, 255, 230, 120, "MOUSE %d,%d B%X", cx, cy, state->mouse_buttons);

    draw_bar(renderer, 12, 12, state->window_w - 24, 104, 21, 25, 34);
    draw_bar(renderer, 20, 20, 16, 16, state->focused ? 60 : 100, state->focused ? 220 : 70, 120);
    draw_bar(renderer, 20, 44, 16, 16, state->last_keycode ? 80 : 40, state->last_keycode ? 170 : 70, 245);
    draw_bar(renderer, 20, 68, 16, 16, state->mouse_buttons ? 245 : 60, state->mouse_buttons ? 110 : 70, 80);
    draw_bar(renderer, 20, 92, 16, 16, state->last_text[0] ? 180 : 60, state->last_text[0] ? 120 : 70, 245);

    draw_textf(renderer, 44, 18, 2, 210, 230, 245, "FOCUS %s  WINDOW %dX%d", state->focused ? "YES" : "NO", state->window_w, state->window_h);
    draw_textf(renderer, 44, 42, 2, 210, 230, 245, "KEY %s  SCAN %s  MODS %X",
               state->last_keycode ? SDL_GetKeyName(state->last_keycode) : "NONE",
               state->last_scancode ? SDL_GetScancodeName(state->last_scancode) : "NONE",
               (unsigned int)state->last_mods);
    draw_textf(renderer, 44, 66, 2, 210, 230, 245, "MOUSE %d,%d  BUTTONS %X  WHEEL %d,%d",
               state->mouse_x, state->mouse_y, state->mouse_buttons, state->wheel_x, state->wheel_y);
    draw_textf(renderer, 44, 90, 2, 210, 230, 245, "TEXT \"%s\"  EVENTS %llu",
               state->last_text[0] ? state->last_text : "", (unsigned long long)state->event_count);
    if (state->custom_cursor) {
        draw_text(renderer, state->window_w - 238, 90, 2, "SDL COLOR CURSOR", 255, 110, 180);
    }

    draw_bar(renderer, 12, 124, state->window_w - 24, 76, 21, 25, 34);
    draw_bar(renderer, 20, 132, 16, 16, state->input_device_name[0] ? 80 : 70, state->input_device_name[0] ? 210 : 70, 150);
    draw_bar(renderer, 20, 156, 16, 16, state->last_button_down ? 245 : 60, state->last_button_down ? 110 : 70, 80);
    draw_bar(renderer, 20, 180, 16, 16, state->last_axis_value != 0 ? 90 : 60, state->last_axis_value != 0 ? 180 : 70, 245);
    draw_textf(renderer, 44, 130, 2, 210, 230, 245, "GAMEPAD HINT %s  DEV %s",
               safe_hint(SDL_GetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS)),
               state->input_device_name[0] ? state->input_device_name : "NONE");
    draw_textf(renderer, 44, 154, 2, 210, 230, 245, "CONTROLLERS %d  JOYSTICKS %d  INSTANCE %d",
               state->controller_count, state->joystick_count, (int)state->input_instance_id);
    draw_textf(renderer, 44, 178, 2, 210, 230, 245, "BUTTON %d %s  AXIS %d VALUE %d",
               state->last_button,
               state->last_button_down ? "DOWN" : "UP",
               state->last_axis,
               state->last_axis_value);

    const int event_rows = state->summary_count < 10 ? state->summary_count : 10;
    const int log_top = state->window_h - 26 - event_rows * 20;
    draw_bar(renderer, 12, log_top - 10, state->window_w - 24, event_rows * 20 + 20, 18, 22, 30);
    for (int i = 0; i < event_rows; i++) {
        uint8_t shade = (uint8_t)(230 - i * 12);
        draw_textf(renderer, 20, log_top + i * 20, 2, shade, shade, 245, "%02d %s", i, state->summaries[i]);
    }

    const int pulse = (int)((tick / 16) % 120);
    draw_bar(renderer, state->window_w - 150, 20, 100 + pulse / 6, 16, 80, 180, 180);

    SDL_SetRenderDrawColor(renderer, 255, 220, 80, 255);
    SDL_RenderLine(renderer, (float)(cx - 24), (float)cy, (float)(cx + 24), (float)cy);
    SDL_RenderLine(renderer, (float)cx, (float)(cy - 24), (float)cx, (float)(cy + 24));
    SDL_FRect cursor = { (float)(cx - 5), (float)(cy - 5), 10.0f, 10.0f };
    SDL_RenderRect(renderer, &cursor);

    SDL_RenderPresent(renderer);
}

int main(int argc, char **argv)
{
    ProbeState state;
    memset(&state, 0, sizeof(state));
    state.input_instance_id = -1;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--background-gamepad") == 0) {
            state.background_gamepad_hint_requested = true;
        }
        else if (strcmp(argv[i], "--log-events") == 0) {
            state.log_events = true;
        }
        else if (strcmp(argv[i], "--custom-cursor") == 0) {
            state.custom_cursor = true;
        }
        else {
            fprintf(stderr, "usage: %s [--background-gamepad] [--log-events] [--custom-cursor]\n", argv[0]);
            return 2;
        }
    }

    if (state.background_gamepad_hint_requested) {
        SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
    }

    if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS | SDL_INIT_GAMEPAD | SDL_INIT_JOYSTICK)) {
        fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        return 1;
    }

    SDL_Window *window = SDL_CreateWindow("katzensteg-input-probe",
                                          WINDOW_WIDTH,
                                          WINDOW_HEIGHT,
                                          SDL_WINDOW_RESIZABLE);
    if (!window) {
        fprintf(stderr, "SDL_CreateWindow failed: %s\n", SDL_GetError());
        SDL_Quit();
        return 1;
    }

    SDL_Renderer *renderer = SDL_CreateRenderer(window, NULL);
    if (!renderer) {
        fprintf(stderr, "SDL_CreateRenderer failed: %s\n", SDL_GetError());
        SDL_DestroyWindow(window);
        SDL_Quit();
        return 1;
    }

    if (state.log_events) {
        const char *renderer_name = SDL_GetRendererName(renderer);
        fprintf(stderr, "renderer=%s\n", renderer_name ? renderer_name : "unknown");
    }

    SDL_StartTextInput(window);
    state.running = true;
    state.focused = (SDL_GetWindowFlags(window) & SDL_WINDOW_INPUT_FOCUS) != 0;
    SDL_GetWindowSize(window, &state.window_w, &state.window_h);
    {
        float mx = 0;
        float my = 0;
        state.mouse_buttons = SDL_GetMouseState(&mx, &my);
        state.mouse_x = (int)mx;
        state.mouse_y = (int)my;
    }
    refresh_input_device(&state);

    push_summary(&state, "started; press Escape or q to quit");
    if (state.custom_cursor && !install_custom_cursor(&state)) {
        state.custom_cursor = false;
        push_summary(&state, "custom SDL color cursor unavailable");
    }
    if (state.log_events) {
        fprintf(stderr,
                "background_gamepad_hint=%s active_device=%s controllers=%d joysticks=%d\n",
                safe_hint(SDL_GetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS)),
                state.input_device_name[0] ? state.input_device_name : "none",
                state.controller_count,
                state.joystick_count);
    }
    update_title(window, &state);

    while (state.running) {
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            handle_event(window, &state, &event);
        }

        SDL_GetWindowSize(window, &state.window_w, &state.window_h);
        render_probe(renderer, &state, (uint32_t)SDL_GetTicks());
        SDL_Delay(8);
    }

    SDL_StopTextInput(window);
    clear_custom_cursor(&state);
    close_input_device(&state);
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();
    return 0;
}
