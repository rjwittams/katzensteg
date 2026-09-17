/* Public-ABI acceptance source from Jackstay reference revision
 * 94a697e6ace998700fa7342b7bc7f217c496b367 (MIT OR Apache-2.0).
 * Synthetic pixels are inlined; --reject-media and --drop-input inject failures. */
/* Interactive synthetic CPU source. Uses the same pixels as the reference
 * viewer and the public input/media interfaces; no Porthole daemon required. */
#define _POSIX_C_SOURCE 200809L
#include "jackstay_bootstrap.h"
#include <stdint.h>
#include <stddef.h>
enum { WIDTH = 320, HEIGHT = 180, STRIDE = WIDTH * 4 };

static void fill_frame(uint8_t *pixels, uint64_t sequence) {
  for (uint32_t y = 0; y < HEIGHT; y++) {
    for (uint32_t x = 0; x < WIDTH; x++) {
      size_t offset = (size_t)y * STRIDE + (size_t)x * 4;
      pixels[offset + 0] = (uint8_t)((x + sequence * 3) % 256);
      pixels[offset + 1] = (uint8_t)((y + sequence * 5) % 256);
      pixels[offset + 2] = (uint8_t)((x + y + sequence * 7) % 256);
      pixels[offset + 3] = 255;
    }
  }
}


#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

static void pause_ms(unsigned ms) { struct timespec t = {(time_t)(ms / 1000), (long)(ms % 1000) * 1000000}; nanosleep(&t, NULL); }
static int listener(const char *path) {
  struct sockaddr_un address = {0}; address.sun_family = AF_UNIX;
  if (strlen(path) >= sizeof(address.sun_path)) return -1;
  memcpy(address.sun_path, path, strlen(path) + 1);
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  /* Refuse existing paths; never unlink a socket owned by another process. */
  if (bind(fd, (struct sockaddr *)&address, sizeof(address)) || listen(fd, 1)) { close(fd); return -1; }
  return fd;
}
static void checked(ft_status status) { if (status != FT_STATUS_OK) { fprintf(stderr, "reference source status=%d\n", status); exit(1); } }
int main(int argc, char **argv) {
  if (argc < 2 || ft_abi_version() != FT_ABI_VERSION) { fprintf(stderr, "usage: capture-input-source SOURCE_SOCKET [--report-state] [--observe-only]\n"); return 1; }
  int report_state = 0, observe_only = 0, reject_media = 0, drop_input = 0, delay_bootstrap = 0;
  for (int i = 2; i < argc; i++) {
    if (!strcmp(argv[i], "--report-state")) report_state = 1;
    else if (!strcmp(argv[i], "--observe-only")) observe_only = 1;
    else if (!strcmp(argv[i], "--reject-media")) reject_media = 1;
    else if (!strcmp(argv[i], "--drop-input")) drop_input = 1;
    else if (!strcmp(argv[i], "--delay-bootstrap")) delay_bootstrap = 1;
    else { fprintf(stderr, "unknown option: %s\n", argv[i]); return 1; }
  }
  umask(0077);
  int media_listener = listener(argv[1]); if (media_listener < 0) { perror("source listener"); return 1; }
  ft_cpu_producer *producer = NULL; ft_cpu_setup_server *media_server = NULL;
  ft_cpu_producer_config media_config = {6, 2, 1, 2, STRIDE * HEIGHT, 8 * 1024 * 1024, 5000000000ULL};
  checked(ft_cpu_producer_create(&media_config, &producer));
  ft_input_target *target = NULL; ft_input_server *input_server = NULL;
  ft_input_config config; ft_input_config_default(&config); config.independent_contributions = 1; config.interaction_cancel = 1; checked(ft_input_target_create(&config, &target));
  printf("ready\n"); fflush(stdout);
  int32_t media_fd = accept(media_listener, NULL, NULL); if (media_fd < 0) return 1;
  /* This example authorizes its private same-user endpoint for the selected
   * synthetic source. Passing NULL intentionally withholds input authority. */
  if (delay_bootstrap) { printf("bootstrap_wait\n"); fflush(stdout); pause_ms(300); }
  checked(ft_source_bootstrap_accept(&media_fd, observe_only ? NULL : target, &input_server));
  if (reject_media) close(media_fd);
  else checked(ft_cpu_producer_serve(producer, &media_fd, &media_server));
  close(media_listener); unlink(argv[1]);
  uint8_t *pixels = malloc(STRIDE * HEIGHT); if (!pixels) return 1;
  uint64_t held[256] = {0}; unsigned held_count = 0, buttons = 0, downs = 0, repeats = 0, releases = 0, cleanup = 0;
  size_t text_bytes = 0; double pointer_x = 0, pointer_y = 0; int finished = 0;
  for (uint64_t sequence = 1; !finished; sequence++) {
    if (drop_input && sequence == 120) ft_input_server_destroy(&input_server);
    ft_input_work *work = NULL;
    while (ft_input_target_next(target, &work) == FT_STATUS_OK) {
      ft_input_operation op; checked(ft_input_work_describe(work, &op)); ft_input_event *e = &op.event;
      uint32_t outcome = FT_INPUT_EXECUTED;
      switch (e->kind) {
        case FT_INPUT_KEY: {
          /* This reference supports physical controls and a small logical subset.
           * No keyboard-layout reconstruction is claimed. */
          if (e->key_kind == FT_INPUT_LOGICAL_KEY && strcmp(e->key, "Enter") && strcmp(e->key, "ArrowLeft") && strcmp(e->key, "ArrowRight")) {
            outcome = FT_INPUT_UNSUPPORTED; break;
          }
          if (e->action == FT_INPUT_DOWN) { if (held_count == 256) outcome = FT_INPUT_REJECTED; else { held[held_count++] = e->press; downs++; } }
          else if (e->action == FT_INPUT_REPEAT) repeats++;
          else { for (unsigned i = 0; i < held_count; i++) if (held[i] == e->press) { held[i] = held[--held_count]; releases++; break; } }
          break;
        }
        case FT_INPUT_TEXT: text_bytes += e->text_len; break;
        case FT_INPUT_BUTTON:
          if (e->action == FT_INPUT_DOWN) buttons |= 1u << (e->button - 1); else buttons &= ~(1u << (e->button - 1));
          pointer_x = e->x; pointer_y = e->y; break;
        case FT_INPUT_MOTION: pointer_x = e->x; pointer_y = e->y; break;
        case FT_INPUT_SCROLL: pointer_x += e->x; pointer_y += e->y; break;
        case FT_INPUT_CLEANUP:
          if (op.scope == FT_INPUT_SCOPE_ALL) held_count = 0;
          buttons = 0; cleanup++;
          if (!drop_input && op.reason != FT_INPUT_REASON_FOCUS && op.reason != FT_INPUT_REASON_GEOMETRY) finished = 1;
          break;
        default: outcome = FT_INPUT_UNSUPPORTED;
      }
      checked(ft_input_work_complete(&work, outcome));
      if (report_state) {
        printf("state downs=%u repeats=%u releases=%u text_bytes=%zu held=%u buttons=%u\n", downs, repeats, releases, text_bytes, held_count, buttons);
        fflush(stdout);
      }
    }
    if (!input_server && (!media_server || ft_cpu_setup_server_poll(media_server) != FT_STATUS_DRAINING)) finished = 1;
    fill_frame(pixels, sequence);
    /* Held keys tint the top strip; committed text fills a bottom progress bar;
     * the pointer is a white square, red while a button is held. */
    for (uint32_t y = 0; y < HEIGHT; y++) for (uint32_t x = 0; x < WIDTH; x++) {
      uint8_t *p = pixels + y * STRIDE + x * 4;
      if (y < 15 && held_count) { p[0] = 0; p[1] = 255; p[2] = 0; }
      if (y > HEIGHT - 15 && x < text_bytes % WIDTH) { p[0] = 255; p[1] = 255; p[2] = 255; }
      if ((double)x >= pointer_x && (double)x < pointer_x + 8 && (double)y >= pointer_y && (double)y < pointer_y + 8) {
        p[0] = buttons ? 0 : 255; p[1] = buttons ? 0 : 255; p[2] = 255;
      }
    }
    ft_acquired_frame_descriptor desc = {.sequence = sequence, .timestamp_ns = sequence * 16000000,
      .width = WIDTH, .height = HEIGHT, .stride = STRIDE, .pixel_format = FT_PIXEL_FORMAT_BGRA8_UNORM};
    uint64_t cursor; ft_status s = ft_cpu_producer_publish(producer, &desc, pixels, STRIDE * HEIGHT, &cursor);
    if (s != FT_STATUS_OK && s != FT_STATUS_DROPPED) checked(s);
    pause_ms(16);
  }
  /* Wait for the worker to flush the actual completion response and finish. */
  unsigned waits = 0;
  while (input_server && ft_input_server_poll(input_server) == FT_STATUS_EMPTY && waits++ < 3000) pause_ms(1);
  if (input_server && ft_input_server_poll(input_server) != FT_STATUS_OK) { fprintf(stderr, "input reply drain timeout\n"); return 1; }
  ft_input_server_destroy(&input_server); checked(ft_input_target_destroy(&target));
  ft_status setup = media_server ? ft_cpu_setup_server_destroy(&media_server) : FT_STATUS_OK;
  if (setup != FT_STATUS_OK && setup != FT_STATUS_CANCELLED) checked(setup);
  ft_status s = FT_STATUS_DRAINING;
  for (int n = 0; n < 500 && s == FT_STATUS_DRAINING; n++) { s = ft_cpu_producer_destroy(&producer); if (s == FT_STATUS_DRAINING) pause_ms(10); }
  checked(s); free(pixels);
  printf("input_source downs=%u repeats=%u releases=%u text_bytes=%zu cleanup=%u held=%u buttons=%u\n",
    downs, repeats, releases, text_bytes, cleanup, held_count, buttons);
  return 0;
}
