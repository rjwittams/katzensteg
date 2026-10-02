# How wheelhouse turns a cleat session into pixels

Research for rjwittams/katzensteg#91 (map: #89). Read on 2026-10-02 from local
checkouts: `~/dev/wheelhouse` (main), `~/dev/cleat` (main), `~/dev/jackstay`,
and this repo. Paths below are relative to those checkouts. Nothing was built or
run; every statement is from source or docs.

## Short answer

Wheelhouse links cleat's C provider library, pulls cell-level render updates
for a session, and draws them with its own terminal glyph renderer on the GPU
(Metal on macOS, OpenGL on Linux, D3D11 on Windows). It is a Jackstay consumer
only. It has no Jackstay source side, no production path that gets terminal
pixels back to the CPU, and no mode that runs without a window. The only
readback is a diagnostic hook, `r_pass_list_readback`. So wheelhouse as it
stands cannot be pointed at by `katzensteg jackstay-source`; something would
have to be written on the wheelhouse side first.

## 1. The cleat terminal provider

- Wheelhouse includes `cleat_provider.h` directly
  (`wheelhouse/src/uishell/uishell_terminal_provider.h:6`) and links
  `libcleat` built from a sibling checkout with the `ghostty-vt` feature
  (`wheelhouse/build.sh:31-49`). This is a C ABI into a Rust library, not the
  cleat CLI and not a protocol wheelhouse implements itself.
- Two backends, chosen per view from workspace config
  (`wheelhouse/src/uishell/uishell_views.c:3393-3414`):
  - in-process (`CLEAT_PROVIDER_BACKEND_IN_PROCESS`): the PTY and VT live in
    wheelhouse;
  - daemon (`CLEAT_PROVIDER_BACKEND_DAEMON`): `daemon:1` creates a session in
    a cleat daemon, `session:"<id>"` attaches to an existing one. One provider
    per named daemon is shared by all views; it owns one multiplexed packet
    connection (`uishell_views.c:3092-3148`).
- Attach is `cleat_session_attach(provider, &desc)` with the id, cols, rows and
  cell pixel size (`uishell_views.c:3444-3449`;
  `cleat/crates/cleat/include/cleat_provider.h:528-534`). The desc leaves
  `role` zero, which requests control; the daemon may grant watcher instead
  (`cleat_provider.h:205-211`). Wheelhouse shows a "watching, click to take
  control" pill and calls `cleat_session_take_control`
  (`uishell_views.c:3516-3553`).
- What it receives, per UI frame: `cleat_session_poll` for dirty state, then
  `cleat_session_render_update` (`uishell_views.c:4009-4029`). A render update
  carries cols/rows, geometry, cursor, terminal modes, scrollbar state, a list
  of ops (full visible replace, row replace, scroll copy) made of cells with
  graphemes and resolved style, plus Kitty image resources and placements
  (`cleat_provider.h:356-444`). Daemon sessions have no snapshot call; the
  first update after a channel opens is full-dirty and carries the whole grid
  (`cleat_provider.h:614-619`).
- Wheelhouse applies updates to its own cell cache and image cache
  (`uishell_views.c:4024-4025`; types in
  `wheelhouse/src/uishell/uishell_terminal_glyph.h:84-154`), then marks the
  generation observed.
- A wake callback from cleat only nudges the UI loop
  (`uishell_views.c:3084-3089`).
- Input goes the other way as structured events (`cleat_session_send_input`:
  key, text, mouse, focus, paste) and resize as `cleat_session_resize` plus
  `cleat_session_update_geometry` (`uishell_views.c:3475-3483, 3598-3626`;
  `cleat_provider.h:569-580`). Cleat encodes the terminal protocol.

## 2. What renders the grid

- The renderer is wheelhouse's own code:
  `wheelhouse/src/uishell/uishell_terminal_glyph.c` (9,598 lines), entry point
  `uishell_terminal_glyph_renderer_draw_cell_feed_with_cursors`
  (`uishell_terminal_glyph.c:9365`, declared at `uishell_terminal_glyph.h:171`).
  It is not Ghostty's renderer; Ghostty is used only as the VT inside cleat
  (`uishell_views.c:3437`).
- Input to it is a cell feed (`cols`, `rows`, `cleat_cell[]`, cursor), draw
  params (canvas rect, background, cell size in px, optional image cache), and
  a font set (`uishell_terminal_glyph.h:37-82`).
- Output is not pixels. It emits draw commands (`dr_rect`, `dr_text_run`,
  `dr_img`) into a `DR_Bucket`, which holds an `R_PassList`
  (`uishell_views.c:3987-3998`). The file calls `dr_rect` 67 times and
  `r_pass_list_readback` only from diagnostics.
- Glyphs are rasterised on the CPU by the font provider (CoreText on macOS,
  FreeType on Linux, DirectWrite on Windows: `wheelhouse/build.sh:105-110`,
  `wheelhouse/src/font_provider/`), uploaded into GPU atlas textures
  (`wheelhouse/src/font_cache/font_cache.c:757-812`), and composited on the
  GPU by the render backend (`wheelhouse/src/render/render_inc.h:18-23`:
  D3D11, OpenGL, Metal; there is also a stub backend that draws nothing).
- Reuse layers, from thin to thick:
  1. cell feed to draw bucket (`uishell_terminal_glyph.c`): needs RAD's base,
     font provider, font cache, draw and render layers. It is `internal`
     (static) code in a single-translation-unit build
     (`wheelhouse/src/uishell/uishell_main.c:36-103`), not a library.
  2. draw bucket to pixels: a render backend with a live device. On Metal the
     device is created in `r_init` without a window
     (`wheelhouse/src/render/metal/render_metal.c:436-442`); on Linux the EGL
     display comes from the X11 display
     (`wheelhouse/src/render/opengl/linux/egl/render_opengl_linux_egl.c:23`,
     `wheelhouse/src/linux/window_manager/linux_window_manager.c:32`).
  3. the whole app.
  There is no CPU compositor for the draw bucket.

## 3. Running with no window

- No such mode exists. Startup always runs `wm_init`, `r_init`, `rd_init` and
  the frame loop (`uishell_main.c:161-222`); `wm_init` on macOS sets
  `NSApplicationActivationPolicyRegular`
  (`wheelhouse/src/mac/window_manager/mac_window_manager.c:774-775`) and
  windows are shown with `makeKeyAndOrderFront`
  (`mac_window_manager.c:259, 934, 946`; the shell opens its window at
  `wheelhouse/src/shell/shell_core.c:2666`).
- The two flags described as headless are pure model checks that exit before
  any graphics init (`uishell_main.c:141-150`).
- Linux diagnostics run under Xvfb (`wheelhouse/README.md:128`,
  `wheelhouse/tools/run-linux-opengl-terminal-glyph-diagnostics.sh`).
- The closest thing to offscreen terminal rendering is
  `--terminal_glyph_fixture_ppm:<path>`: it draws a fixed 80x24 fixture into a
  bucket and reads it back with no window target
  (`uishell_terminal_glyph.c:7541-7621`). It still runs after the first
  `update()` of the normal app (`uishell_main.c:220-290`), and it draws a
  fixture, not a session.
- In the running app, non-visible workspaces already render to offscreen
  surfaces at reduced rate and scale ("Workspace Preview";
  `uishell_views.c:3380-3383, 4011-4012`,
  `wheelhouse/src/shell/shell_core.c:2211, 7715-7982`). Those are GPU textures
  for wheelhouse's own compositor; nothing reads them back.
- What stands in the way of headless: the app shell assumes a window and a
  regular-activation app; on Linux the GL context needs an X display; the
  terminal view is built inside the UI build pass (cols/rows come from the
  panel rect, `uishell_views.c:3372-3379`), so "session to pixels" is not
  separable from the UI frame without new code.

## 4. How frames could leave

- Jackstay source side: none. `wheelhouse/src/jackstay/` and
  `wheelhouse/src/uishell/uishell_jackstay.c` call only consumer and
  controller functions (`ft_acquisition_*`, `ft_input_client_*`,
  `ft_source_bootstrap_connect*`). There is no call to `ft_cpu_producer_*`,
  `ft_input_target_*` or `ft_source_bootstrap_accept*` anywhere in
  `wheelhouse/src`. `wheelhouse/docs/design/jackstay-view.md:3-7` describes the
  view as a consumer that "optionally produces cooperative input".
- Readback: `r_pass_list_readback(arena, size, passes)`
  (`wheelhouse/src/render/render_core.h:376`), returning `R_Readback {size,
  format, data}` (`render_core.h:278-284`).
  - Metal (`render_metal.c:1405-1565`): takes the device write lock, allocates
    two textures per call (RGBA16Float stage, BGRA8 sRGB final), replays only
    `R_PassKind_UI` passes, commits, `waitUntilCompleted`, then `getBytes`
    into an arena. Result is tightly packed BGRA8, `width*4` stride.
  - OpenGL (`wheelhouse/src/render/opengl/render_opengl.c:944-1110`): FBO,
    UI passes only, skips surface-targeted passes, `glReadPixels` then a
    per-pixel flip and RGBA to BGRA swap on the CPU.
  - D3D11 has one too (`wheelhouse/src/render/d3d11/render_d3d11.c:1923`);
    the stub returns nothing (`wheelhouse/src/render/stub/render_stub.c:126`).
  - It is a diagnostic: synchronous, allocates per call, no damage, no blur or
    effect passes. Wheelhouse's own comment says it "only supports flat UI"
    (`wheelhouse/src/uishell/uishell_overview_benchmark.c:179-181`). A second,
    macOS-only test adapter reads the composed window stage instead
    (`uishell_overview_benchmark.c:182-224`).
  - Cost was not measured. From the code: one GPU round trip with a blocking
    wait plus one full-frame copy per frame (two on OpenGL), and a full redraw
    of the bucket each time.
- Format fit: Jackstay CPU frames are BGRA8 or RGBA8
  (`jackstay/crates/jackstay/include/capture_transfer.h:57-59`), so the
  readback result could be published without conversion.
- Metal texture sharing is not implemented in wheelhouse
  (`render_metal.c:1567-1568`: "frames take the CPU path").

## 5. Where Jackstay is defined, and what a source must implement

- Repo: `~/dev/jackstay` (github `flotilla-org/jackstay`), Rust crate
  `crates/jackstay` with C headers in `crates/jackstay/include/`:
  `capture_transfer.h` (media), `jackstay_input.h`, `jackstay_bootstrap.h`,
  `jackstay_ring.h`. Design docs in `docs/design/`.
- A source that `katzensteg jackstay-source` can open must:
  1. own a listener on a Unix socket and authorise peers itself; Jackstay
     creates no listener (`jackstay/docs/design/source-bootstrap.md:3-7`);
  2. for each accepted connection call `ft_source_bootstrap_accept(&fd,
     input_target_or_null, &input_server)`, then
     `ft_cpu_producer_serve(producer, &fd, &server)`
     (`source-bootstrap.md:43-46`);
  3. create an `ft_cpu_producer` with explicit limits and call
     `ft_cpu_producer_publish` per frame, plus reconfigure/advance on resize
     and cleanup polling (`capture_transfer.h:381-400`,
     `jackstay/docs/design/acquisition-cpu-c-setup.md:11-18, 73-88`);
  4. for input, create an `ft_input_target`, run an executor loop
     (`ft_input_target_next`, `ft_input_work_describe`,
     `ft_input_work_complete`), report geometry with
     `ft_input_target_geometry`, and keep pumping through cleanup
     (`jackstay_input.h:104-128`, `jackstay/docs/design/input.md:72-80`).
- Input vocabulary is keys (physical DOM code or logical), UTF-8 text commits,
  pointer motion, buttons and scroll (`input.md:15-41`). Geometry flows from
  target to controller only. The event kinds are key, text, motion, button, scroll
  and cleanup (`jackstay_input.h:27-32`); there is no resize request from
  controller to source.
- This repo already has a Zig wrapper for the source side:
  `src/jackstay/publisher.zig` (listener, bootstrap accept, producer serve,
  maintenance) and `src/jackstay/media.zig:160-243` (`Producer`), used by the
  preload runtime to publish app frames (`src/katzensteg/runtime.zig:334-348,
  1060-1070`).

## 6. What `katzensteg jackstay-source` does today

- `jackstay-source` is a launcher profile whose target is the
  `katzensteg-jackstay` binary (`profiles/jackstay.json:3-12`), built from
  `src/katzensteg/jackstay_consumer.zig` only with `-Djackstay=true`
  (`build.zig:12, 184-186`). Without that option the launcher reports
  `JackstayUnavailable` (`src/katzensteg/launcher.zig:356, 438`).
- Arguments: `<socket> [--observe | --require-input]`; default requests
  optional input (`jackstay_consumer.zig:81-82`).
- A worker connects to the socket, runs bootstrap, attaches CPU media, then
  loops: acquire a frame, copy it row by row into its own buffer (64 MiB cap),
  release the lease, and swap it into a latest-frame mailbox
  (`jackstay_consumer.zig:33-75`).
- The main loop is an ordinary Katzensteg producer: `Runtime.initMediaSource`,
  `pollBatchControl`, `pollTerminalInput`, and
  `presentExternalFramebuffer(width, height, rgba8|bgra8, pixels)` when the
  host wants a frame (`jackstay_consumer.zig:102-153`). It therefore appears
  in the WM as a normal producer window through `KATZENSTEG_TARGET=jsonl:...`
  (`docs/jackstay.md:54-68`). The WM sees pixels and nothing else.
- Input back: if the source admitted a controller, the presenter enables
  input capture and focus reports (`src/katzensteg/runtime.zig:219-231`) and
  `Controller.pump` forwards the canonical input model's events: native keys
  with press identity and modifiers, text, pointer motion and buttons scaled
  into the target's logical extent, and line scroll
  (`src/katzensteg/jackstay_input_controller.zig:131-271`). At most 32
  operations are outstanding; focus loss triggers a Jackstay reset
  (`docs/jackstay.md:236-252`).
- It does not forward a resize. Moving or resizing the panel changes only the
  presentation mapping (`docs/jackstay.md:66-68, 242-244`). Wheelhouse's own
  Jackstay view behaves the same way
  (`wheelhouse/docs/design/jackstay-view.md:121-122`).
- Limits: CPU RGBA/BGRA only, no audio, no GPU transport, no registry
  (`docs/jackstay.md:111-113`).

## 7. Platform limits

- Wheelhouse builds on macOS (Metal, CoreText), Linux (OpenGL over X11/EGL,
  FreeType) and Windows (D3D11, DirectWrite). Its CI builds Linux with cleat's
  no-VT variant; "Ghostty on Linux is not covered by these jobs"
  (`wheelhouse/README.md:62`). Linux needs an X display; I found no Wayland
  path.
- Readback exists on Metal, OpenGL and D3D11.
- Katzensteg's Jackstay connectors support macOS and Linux
  (`docs/jackstay.md:5`).
- Version skew on this machine: Katzensteg pins Jackstay ABI 8
  (`profiles/jackstay-dependency.json`), the local `~/dev/jackstay` header is
  0.9 (`capture_transfer.h:23-24`), and wheelhouse CI pins a 0.11 branch
  commit (`wheelhouse/.github/workflows/build.yml:24-27`). Both sides require
  an exact ABI match at runtime (`docs/jackstay.md:30`,
  `wheelhouse/docs/design/jackstay-view.md:202`). A wheelhouse-built source and
  a KS presenter would not load the same library version today.
- Similar skew for cleat: wheelhouse calls `cleat_session_hosting`,
  `cleat_session_transfer` and `cleat_session_adopt`
  (`uishell_views.c:3299, 3473`), which are not in the local `~/dev/cleat`
  header (ABI 9); wheelhouse CI pins a cleat revision described as ABI 10
  (`build.yml:17-23`).

## Not determined

- The real cost of `r_pass_list_readback` per frame. Nothing was run.
- Whether wheelhouse can be made to start without showing a window by small
  changes (accessory activation policy, a hidden window). No flag exists; I
  did not test what the frame loop does with zero windows.
- Whether Kitty image bytes reach a daemon-backed session. The local header
  says `cleat_session_with_image_resource_data` "currently succeeds only for
  in-process sessions" (`cleat_provider.h:628-634`), but that checkout is
  behind wheelhouse's pin.
- Whether EGL in wheelhouse's Linux backend can run surfaceless. The code
  takes its display from X11; I did not look for a fallback beyond that.
- Whether the glyph renderer can be compiled outside the unity build. It is
  all `internal` functions; I did not attempt it.

## What this means for the WM

Facts that bear on the choice:

- A Jackstay source gives the WM pixels and an input channel. It gives no way
  to tell the source the window's size changed, and no cells, so the WM cannot
  drive cols/rows of a terminal through it.
- Wheelhouse has the renderer but neither a source side nor a headless mode.
- Cleat's provider ABI already hands any C or Zig client the same render
  updates wheelhouse gets, and takes input and resize directly.
- Katzensteg already has the Zig code for the Jackstay source side.

Options, not ranked:

1. **Wheelhouse app as the source.** Add a Jackstay producer to wheelhouse
   that publishes a terminal view (or a view surface) via readback, and an
   input target that feeds the view. Needs a window on screen or new headless
   work, a production readback path, and a side channel for resize. Works
   wherever wheelhouse runs with a display.
2. **A small headless renderer built from wheelhouse's layers.** A new
   executable that links cleat, the glyph renderer and a render backend,
   attaches to one session, renders offscreen, and either publishes Jackstay
   or speaks the Katzensteg producer protocol directly. Avoids the app shell,
   still needs a GPU device (and X on Linux), and means carving the renderer
   out of the unity build.
3. **Cells only for now.** The WM links cleat's provider ABI and paints cells
   itself; the pixel presentation waits. No wheelhouse dependency.
4. **A different pixel renderer fed by the same cleat render updates** (CPU
   rasteriser in this repo or elsewhere). Shares option 3's attach code;
   does not reuse wheelhouse's glyph work.
5. **Jackstay as transport only, with resize carried elsewhere.** Whatever
   renders, publish through Jackstay so `jackstay-source` presents it
   unchanged, and send resize over cleat (the WM as a second attachment) or
   a new message. Needs the ABI pins aligned first.
