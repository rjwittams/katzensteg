# Stdio Render Batch Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a first-cut stdio/JSONL embed mode for the existing Katzensteg preload launcher path, so an agent-owned PTY can choose geometry and receive opaque renderer-generated terminal byte batches.

**Architecture:** Keep the existing launcher/profile/preload path. The launcher adds an explicit `--embed-jsonl` mode, passes launcher stdin through to a runtime control fd, and passes a dedicated runtime render-batch fd through to launcher stdout so target stdout can remain redirected. The preloaded runtime captures frames as today, but can route terminal protocol bytes into JSONL batch groups instead of writing directly to `/dev/tty`. The runtime does not emit graphics batches until the host sends an `attach` message for a `window_id` with geometry and id ranges.

**Tech Stack:** Zig 0.15.2, existing Katzensteg launcher/profile JSON, SDL2 preload runtime, termscene kitty protocol/backend, Zig file-level tests, focused Python smoke harness if needed.

---

## Scope And First-Cut Constraints

This plan implements the first useful proof, not the full future protocol.

- Use existing preload launch profiles.
- Use JSONL, not MCP, JSON-RPC, socket mode, or binary framing.
- Enter embed mode only through an explicit launcher flag, `--embed-jsonl`.
- Use two dedicated child fds internally: one control fd for client-to-runtime JSONL and one render fd for runtime-to-client JSONL. The launcher copies its stdin to the control fd and copies the render fd to its stdout in quiet embed mode.
- Keep target stdout redirected to file for the first proof.
- Start with direct inline terminal image payloads for batch mode. File/shm side channels can come later.
- Suppress graphics output until the host attaches to a window with geometry and id ranges.
- Support initial host-provided attach/viewport/id ranges through the control fd from the start.
- Support one `window_id` (`main`) while keeping it in message shapes.
- Keep viewport/window geometry concepts presentation-generic. The first implementation uses them for stdio embed mode, but direct `/dev/tty` mode should be able to reuse the same concepts later for menus, zoomed-down windows, multiple captured windows, and break-out views.

## File Structure

- Modify `src/termscene/kitty/protocol.zig`
  - Make protocol writers accept generic writers so they can write to files or memory buffers.
  - Keep emitted bytes identical for direct tty users.
- Create `src/katzensteg/render_batch_protocol.zig`
  - Own JSONL message formatting/parsing, JSON string escaping for terminal bytes, viewport/id-range structs, attach messages, and batch group names.
- Create `src/katzensteg/render_batch_sink.zig`
  - Own per-frame group buffers (`deletes`, `uploads`, `placements`, `after`) and write `frame_batch` JSONL to a `std.fs.File`.
  - Provide helpers that emit Kitty upload/place/delete bytes into the correct group.
- Modify `src/katzensteg/config.zig`
  - Add runtime config for presentation sink, batch fd, and control fd.
  - Preserve default direct tty behavior.
- Modify `src/katzensteg/launcher_profiles.zig`
  - Parse the new runtime/embed fields from profiles.
- Modify `src/katzensteg/launcher.zig`
  - Add `--embed-jsonl` parsing and quiet embed launch handling.
  - Create/pass a control fd and render-batch fd to the child.
  - Copy launcher stdin to the control fd and copy the render-batch fd to launcher stdout.
  - Keep child stdout policy separate and default it to the existing log file behavior.
- Modify `src/katzensteg/runtime.zig`
  - Initialize either direct tty presentation or batch presentation.
  - Emit non-graphics lifecycle JSONL before attach if useful.
  - Read attach/viewport/control JSONL from the configured control fd.
  - Hold graphics batches until host attach.
  - Set frame builder image/placement ranges from attach messages.
- Modify `src/katzensteg/frame_builder.zig`
  - Add id-range setters.
  - Add a batch rendering path parallel to direct presentation for the first proof.
  - Keep direct tty path behavior unchanged.
- Modify `build.zig`
  - Add a tiny embed test harness executable if a Zig harness is useful.
- Create `examples/katzensteg-embed-harness/main.zig` or `scripts/katzensteg/test_embed_protocol.py`
  - Launch an embed profile, send/verify initial config if needed, read JSONL batches, and assert batch shape.
- Modify `profiles/probes.json`
  - Add hidden/visible probe profiles for embed mode using `basic-sdl-demo`.
- Modify docs:
  - `docs/katzensteg/2026-04-28-stdio-render-batch-protocol.md`
  - `docs/katzensteg/launcher-usage.md`

---

## Chunk 1: Config And Protocol Types

### Task 1: Add Runtime Config Fields For Embed Mode

**Files:**
- Modify: `src/katzensteg/config.zig`

- [ ] **Step 1: Write failing config parse test**

Add a test near the existing runtime config JSON tests:

```zig
test "runtime config JSON parses stdio batch presentation fields" {
    const json =
        \\{
        \\  "presentation_sink": "jsonl_fd",
        \\  "presentation_fd": 3,
        \\  "presentation_control_fd": 4
        \\}
    ;

    const config = try parseRuntimeConfigJsonSlice(std.testing.allocator, json, null);

    try std.testing.expectEqual(PresentationSink.jsonl_fd, config.presentation_sink);
    try std.testing.expectEqual(@as(i32, 3), config.presentation_fd.?);
    try std.testing.expectEqual(@as(i32, 4), config.presentation_control_fd.?);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test src/katzensteg/config.zig`

Expected: FAIL because `PresentationSink`, `PresentationAspect`, `PresentationRectCells`, `IdRange`, and fields do not exist.

- [ ] **Step 3: Add minimal config model**

Add:

```zig
pub const PresentationSink = enum {
    tty,
    jsonl_fd,
};

pub const IdRange = struct {
    start: u32,
    end: u32,
};
```

Add defaults to `RuntimeConfig`:

```zig
presentation_sink: PresentationSink = .tty,
presentation_fd: ?i32 = null,
presentation_control_fd: ?i32 = null,
```

Parse these fields from JSON. Keep geometry, aspect policy, and id ranges out of runtime config for the first cut; those arrive through the client `attach` message.

- [ ] **Step 4: Run config test**

Run: `zig test src/katzensteg/config.zig`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/katzensteg/config.zig
git commit -m "feat: add render batch runtime config"
```

### Task 2: Add JSONL Render Batch Protocol Helpers

**Files:**
- Create: `src/katzensteg/render_batch_protocol.zig`
- Modify: `build.zig` only if a named test step is added

- [ ] **Step 1: Write protocol formatting tests**

Create tests covering:

```zig
test "frame batch JSON escapes terminal control bytes" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    try writeFrameBatchJsonl(std.testing.allocator, out.writer(std.testing.allocator), .{
        .window_id = "main",
        .seq = 7,
        .deletes = &.{},
        .uploads = &.{"\x1b_Gq=2,a=t;\x1b\\"},
        .placements = &.{"\x1b[4;1H\x1b_Gq=2,a=p;\x1b\\"},
        .after = &.{},
    });

    try std.testing.expect(std.mem.endsWith(u8, out.items, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"type\":\"frame_batch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\\u001b_G") != null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test src/katzensteg/render_batch_protocol.zig`

Expected: FAIL because the file/functions do not exist.

- [ ] **Step 3: Implement minimal JSONL writer**

Implement:

- `BatchView`
- `writeHelloJsonl`
- `writeFrameBatchJsonl`
- `parseAttachMessage` or a similarly small parser for first-cut `attach` and `viewport` messages
- `PresentationAspect`, `PresentationRectCells`, and attach-side `IdRange` types if they do not live elsewhere
- a small `writeJsonString` helper that escapes `"` `\` control bytes, especially ESC as `\u001b`

Use hand-written JSON for writing this small stable message set. For parsing host control messages, use `std.json` into small structs or `std.json.Value`; do not add a generic protocol framework.

- [ ] **Step 4: Run protocol test**

Run: `zig test src/katzensteg/render_batch_protocol.zig`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/katzensteg/render_batch_protocol.zig
git commit -m "feat: add render batch JSONL protocol helpers"
```

---

## Chunk 2: Batchable Terminal Bytes

### Task 3: Make Kitty Protocol Writers Generic

**Files:**
- Modify: `src/termscene/kitty/protocol.zig`
- Test: existing examples compile through `zig build -Dvulkan=false`

- [ ] **Step 1: Write memory-writer protocol test**

Add a test in `protocol.zig`:

```zig
test "protocol writers support memory writers" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    try writePlace(out.writer(std.testing.allocator), 4, 1, .{
        .image_id = 10,
        .placement_id = 20,
        .cols = 5,
        .rows = 3,
        .src_x = 0,
        .src_y = 0,
        .src_w = 16,
        .src_h = 16,
        .z = 100,
    });
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[4;1H") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "a=p") != null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test src/termscene/kitty/protocol.zig`

Expected: FAIL because functions require `std.fs.File.DeprecatedWriter`.

- [ ] **Step 3: Change protocol writer parameters to `anytype`**

Change protocol functions and private helpers from:

```zig
out: std.fs.File.DeprecatedWriter
```

to:

```zig
out: anytype
```

Keep all emitted bytes identical.

- [ ] **Step 4: Run protocol and build checks**

Run:

```bash
zig test src/termscene/kitty/protocol.zig
zig build -Dvulkan=false
```

Expected: both PASS.

- [ ] **Step 5: Commit**

```bash
git add src/termscene/kitty/protocol.zig
git commit -m "refactor: allow kitty protocol writes to memory"
```

### Task 4: Add Render Batch Sink

**Files:**
- Create: `src/katzensteg/render_batch_sink.zig`
- Modify: `src/katzensteg/frame_builder.zig` only if using shared id helpers in tests

- [ ] **Step 1: Write batch sink tests**

Cover:

- upload bytes go into `uploads`
- placement bytes go into `placements`
- delete bytes go into `deletes`
- `flushFrame` emits one JSONL `frame_batch` and clears groups

Example:

```zig
test "batch sink groups upload place and delete bytes" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    var sink = RenderBatchSink.init(std.testing.allocator, "main", out.writer(std.testing.allocator));
    defer sink.deinit();

    try sink.uploadRgba(100000, &[_]u8{ 255, 0, 0, 255 }, 1, 1);
    try sink.place(4, 1, .{
        .image_id = 100000,
        .placement_id = 200000,
        .cols = 1,
        .rows = 1,
        .src_x = 0,
        .src_y = 0,
        .src_w = 1,
        .src_h = 1,
        .z = 100,
    });
    try sink.deletePlacement(.{ .image_id = 100000, .placement_id = 200000 });
    try sink.flushFrame();

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"uploads\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"placements\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"deletes\":[") != null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test --dep termscene -Mroot=src/katzensteg/render_batch_sink.zig -Mtermscene=src/termscene/mod.zig`

Expected: FAIL because the sink does not exist.

- [ ] **Step 3: Implement direct-APC-only sink**

Implement first-cut helpers:

- `uploadRgba`
- `place`
- `deletePlacement`
- `deleteImageData`
- `flushFrame`
- `clearRetainingCapacity`

Use direct APC upload only in this first cut. Leave file transport out of this module.

- [ ] **Step 4: Run sink and protocol tests**

Run:

```bash
zig test --dep termscene -Mroot=src/katzensteg/render_batch_sink.zig -Mtermscene=src/termscene/mod.zig
zig test src/katzensteg/render_batch_protocol.zig
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/katzensteg/render_batch_sink.zig
git commit -m "feat: add render batch sink"
```

---

## Chunk 3: Runtime Presentation Routing

### Task 5: Add Id Range Support To FrameBuilder

**Files:**
- Modify: `src/katzensteg/frame_builder.zig`

- [ ] **Step 1: Write id-range tests**

Add tests:

```zig
test "frame builder allocates image ids from configured range" {
    var builder = FrameBuilder.init(std.testing.allocator, false, .fullscreen, false, false);
    defer builder.deinit();
    builder.setImageIdRange(.{ .start = 100000, .end = 100002 });
    try std.testing.expectEqual(@as(u32, 100000), builder.allocImageId());
    try std.testing.expectEqual(@as(u32, 100001), builder.allocImageId());
}
```

Add a similar test for composite placement ids if the setter lives in `FrameBuilder`.

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test src/katzensteg/frame_builder.zig -lc`

Expected: FAIL because setters do not exist.

- [ ] **Step 3: Add setters and bounded allocation**

Add:

- `setImageIdRange(range: config_mod.IdRange) void`
- `setCompositePlacementIdRange(range: config_mod.IdRange) void`

For first cut, when a range is exhausted, wrap to `start` and log/return an error only if that becomes necessary during integration. Prefer bounded wrap over process crash.

- [ ] **Step 4: Run frame builder tests**

Run: `zig test src/katzensteg/frame_builder.zig -lc`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/katzensteg/frame_builder.zig
git commit -m "feat: allow configured render id ranges"
```

### Task 6: Route Present Jobs To Batch Sink

**Files:**
- Modify: `src/katzensteg/runtime.zig`
- Modify: `src/katzensteg/frame_builder.zig`
- Create or modify: `src/katzensteg/render_batch_sink.zig`

- [ ] **Step 1: Write focused frame-builder batch test**

Add a test that constructs a `RendererState` with a tiny composite framebuffer and renders through a `RenderBatchSink`, then asserts one `frame_batch` JSONL line contains uploads and placements.

Keep this test independent of SDL real windows.

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test src/katzensteg/frame_builder.zig -lc`

Expected: FAIL because no batch render path exists.

- [ ] **Step 3: Implement minimal batch render path**

Add a first-cut method parallel to direct rendering, for example:

```zig
pub fn renderPresentJobBatch(
    self: *FrameBuilder,
    logger: *Logger,
    sink: *RenderBatchSink,
    renderer: ?*sdl.SDL_Renderer,
    job: *PresentJob,
) void
```

For first cut:

- Return without emitting graphics if the sink/window is not attached.
- Support fullscreen composite path first.
- Support scene path by using `RenderBatchSink` equivalents for `registerRawImage`, `place`, and `delete`.
- Route old placement deletes into the `deletes` group.
- Call `sink.flushFrame()` after a successful present.
- Do not implement file transports in batch mode.

- [ ] **Step 4: Run frame builder and sink tests**

Run:

```bash
zig test src/katzensteg/frame_builder.zig -lc
zig test --dep termscene -Mroot=src/katzensteg/render_batch_sink.zig -Mtermscene=src/termscene/mod.zig
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/katzensteg/frame_builder.zig src/katzensteg/render_batch_sink.zig
git commit -m "feat: render presents as JSONL batches"
```

### Task 7: Initialize Runtime In Batch Mode

**Files:**
- Modify: `src/katzensteg/runtime.zig`
- Modify: `src/katzensteg/config.zig`

- [ ] **Step 1: Write runtime config/init test where practical**

If direct `Runtime.init` is too environment-heavy, add a smaller helper test for selecting presentation mode:

```zig
test "batch presentation forces direct upload profile" {
    const options = presentationOptionsFromConfig(.{
        .presentation_sink = .jsonl_fd,
        .presentation_fd = 3,
    });
    try std.testing.expect(options.batch_enabled);
    try std.testing.expect(!options.open_direct_tty);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test src/katzensteg/runtime.zig -lc`

Expected: FAIL because helper/mode does not exist.

- [ ] **Step 3: Implement runtime mode selection**

In `Runtime.init`:

- if `config.presentation_sink == .tty`, keep current behavior
- if `.jsonl_fd`:
  - do not open `/dev/tty` for presentation
  - open the configured fd as a `std.fs.File`
  - open the configured control fd as a `std.fs.File`
  - initialize `RenderBatchSink`
  - emit optional non-graphics `hello`/`launched`/`window_created` JSONL
  - start a small control reader that waits for `attach`/`viewport`
  - keep graphics output suppressed until an `attach` message is received
  - configure `FrameBuilder` id ranges from `attach`
  - force first-cut upload behavior to direct APC
  - keep logging file-based only

Be careful not to disable existing input capture unless batch mode cannot support it yet. If unsupported, log that input capture is disabled in batch mode and set `input_enabled = false`.

- [ ] **Step 4: Run runtime tests**

Run: `zig test src/katzensteg/runtime.zig -lc`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/katzensteg/runtime.zig src/katzensteg/config.zig
git commit -m "feat: initialize runtime render batch mode"
```

---

## Chunk 4: Launcher Embed Mode

### Task 8: Parse Profile Runtime Embed Fields

**Files:**
- Modify: `src/katzensteg/launcher_profiles.zig`
- Modify: `src/katzensteg/launcher.zig`

- [ ] **Step 1: Write profile parser test**

Add JSON profile test:

```zig
test "launcher profiles parse render batch runtime settings" {
    const json =
        \\{
        \\  "profiles": {
        \\    "embed": {
        \\      "target": "/bin/echo",
        \\      "runtime": {
        \\        "presentation_sink": "jsonl_fd",
        \\        "presentation_sink": "jsonl_fd"
        \\      }
        \\    }
        \\  }
        \\}
    ;
    var catalog = try ProfileCatalog.parse(std.testing.allocator, json);
    defer catalog.deinit();
    const profile = catalog.find("embed").?;
    try std.testing.expectEqual(config.PresentationSink.jsonl_fd, profile.runtime.presentation_sink);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test src/katzensteg/launcher_profiles.zig`

Expected: FAIL because runtime field parsing is missing.

- [ ] **Step 3: Parse and resolve new runtime fields**

Extend `RuntimeFieldSet`, runtime parser, and inheritance resolution for the new fields.

- [ ] **Step 4: Run profile tests**

Run: `zig test src/katzensteg/launcher_profiles.zig`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/katzensteg/launcher_profiles.zig
git commit -m "feat: parse render batch profile settings"
```

### Task 9: Add Explicit `--embed-jsonl` Launcher Pass-Through

**Files:**
- Modify: `src/katzensteg/launcher.zig`

- [ ] **Step 1: Write launcher tests**

Add tests for:

- command parser recognizes `--embed-jsonl` before target
- dry-run includes `presentation_sink=jsonl_fd`
- `--embed-jsonl` injects/overrides `presentation_sink=jsonl_fd`
- resolved runtime JSON includes `presentation_fd` and `presentation_control_fd`
- embed mode chooses quiet launcher output
- child stdout remains file/pipe when presentation uses a render fd

Prefer small pure helper tests over spawning real children.

- [ ] **Step 2: Run tests to verify failure**

Run: `zig test src/katzensteg/launcher.zig`

Expected: FAIL because launcher embed helpers do not exist.

- [ ] **Step 3: Implement pass-through fd wiring**

Implementation shape:

- Detect embed mode from the explicit `--embed-jsonl` CLI flag.
- Create a control pipe and a render pipe before spawning the child.
- Pass the render write end to the child as a stable fd, e.g. `3`, and set `presentation_fd = 3` in the runtime JSON.
- Pass the control read end to the child as a stable fd, e.g. `4`, and set `presentation_control_fd = 4` in the runtime JSON.
- Override `presentation_sink = jsonl_fd`.
- Copy launcher stdin to the control pipe. The first proof harness must send `hello` then `attach` before expecting graphics batches.
- Keep child stdout using existing `stdout` policy, usually file.
- In quiet/embed mode, suppress human `std.debug.print` launch messages.
- Drain the pipe read end to launcher stdout without parsing JSONL.
- Keep terminal reset best-effort after child exit.

If Zig child fd remapping is awkward, use the smallest platform-specific helper needed and keep it isolated in `launcher.zig`.

Do not allow a profile alone to silently make launcher stdout a JSONL stream. Profiles can provide defaults, but `--embed-jsonl` is the explicit mode switch.

- [ ] **Step 4: Run launcher tests**

Run: `zig test src/katzensteg/launcher.zig`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/katzensteg/launcher.zig
git commit -m "feat: pass render batch fd through launcher"
```

---

## Chunk 5: Probe Profile And End-To-End Harness

### Task 10: Add Embed Probe Profile

**Files:**
- Modify: `profiles/probes.json`
- Test: `src/katzensteg/launcher_profiles.zig`

- [ ] **Step 1: Add profile parser regression test if needed**

If profile-directory tests already load `profiles/`, extend an assertion to ensure `probe.embed.basic_sdl` resolves.

- [ ] **Step 2: Add profile**

Add a profile roughly shaped as:

```json
"runtime.embed_jsonl": {
  "hidden": true,
  "runtime": {
    "presentation_sink": "jsonl_fd",
    "output_profile": "direct_apc"
  }
},
"probe.embed.basic_sdl": {
  "extends": [
    "adapter.sdl2_preload",
    "runtime.embed_jsonl"
  ],
  "target": "{repo}/zig-out/bin/basic-sdl-demo"
}
```

Keep it hidden if the profile list feels too noisy.

- [ ] **Step 3: Run profile tests**

Run: `zig test src/katzensteg/launcher_profiles.zig`

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add profiles/probes.json src/katzensteg/launcher_profiles.zig
git commit -m "test: add embed render batch probe profile"
```

### Task 11: Add End-To-End JSONL Smoke Harness

**Files:**
- Create: `scripts/katzensteg/test_embed_render_batches.py`
- Modify: `docs/katzensteg/launcher-usage.md`

- [ ] **Step 1: Write failing smoke test**

Create a Python `unittest` that:

- builds or assumes `zig-out/bin/katzensteg` and `basic-sdl-demo`
- runs `./zig-out/bin/katzensteg --embed-jsonl probe.embed.basic_sdl`
- writes a `hello` and `attach` JSONL message to launcher stdin
- captures launcher stdout
- reads a bounded number of JSONL lines
- asserts at least one `frame_batch`
- asserts groups include `uploads` and `placements`
- asserts no launcher human text appears before JSONL

- [ ] **Step 2: Run smoke test to verify it fails before integration is complete**

Run:

```bash
python3 scripts/katzensteg/test_embed_render_batches.py
```

Expected before implementation: FAIL because profile/mode is not wired or no JSONL batches appear.

- [ ] **Step 3: Fix integration until smoke passes**

Use logs in `/tmp/katzensteg-*.log` and profile stdout logs to distinguish:

- launcher quiet-mode leak
- fd pass-through issue
- runtime did not enter batch mode
- frame builder did not emit batch
- target app did not present a frame

- [ ] **Step 4: Run final smoke and focused tests**

Run:

```bash
zig test src/katzensteg/config.zig
zig test src/katzensteg/render_batch_protocol.zig
zig test --dep termscene -Mroot=src/katzensteg/render_batch_sink.zig -Mtermscene=src/termscene/mod.zig
zig test src/katzensteg/launcher_profiles.zig
zig test src/katzensteg/launcher.zig
zig test src/katzensteg/frame_builder.zig -lc
zig test src/katzensteg/runtime.zig -lc
zig build -Dvulkan=false
python3 scripts/katzensteg/test_embed_render_batches.py
```

Expected: all PASS.

- [ ] **Step 5: Document usage**

Update `docs/katzensteg/launcher-usage.md` with:

- embed profile name
- that stdout is JSONL in embed mode
- target stdout remains logged
- first-cut limitations

- [ ] **Step 6: Commit**

```bash
git add scripts/katzensteg/test_embed_render_batches.py docs/katzensteg/launcher-usage.md
git commit -m "test: prove stdio render batch embed mode"
```

---

## Final Verification

- [ ] Run the full focused verification:

```bash
zig test src/katzensteg/config.zig
zig test src/katzensteg/render_batch_protocol.zig
zig test --dep termscene -Mroot=src/katzensteg/render_batch_sink.zig -Mtermscene=src/termscene/mod.zig
zig test src/termscene/kitty/protocol.zig
zig test src/katzensteg/launcher_profiles.zig
zig test src/katzensteg/launcher.zig
zig test src/katzensteg/frame_builder.zig -lc
zig test src/katzensteg/runtime.zig -lc
zig build -Dvulkan=false
python3 scripts/katzensteg/test_embed_render_batches.py
```

- [ ] Record any platform-specific failures in the plan or a follow-up note.
- [ ] Confirm `git status --short` only shows intended files.
- [ ] Do not claim the proof works until the smoke harness has observed at least one valid `frame_batch`.

## Follow-Up Work After First Proof

- Dynamic host-to-runtime viewport updates.
- Keyboard/mouse/focus events.
- Target stdout event stream for interactive text prompts.
- File/shm side-channel payloads.
- Socket transport.
- Optional metadata-rich batch mode.
- Pi extension integration.
- Open-source Codex integration.
