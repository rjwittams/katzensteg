# Katzensteg WM Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first interactive `katzensteg wm` host: a Mac-inspired text-window compositor that launches an embedded producer, owns all decorations, and maps the producer's JSONL output into a host-owned content rectangle.

**Architecture:** Add a WM host layer above the existing attach/embed protocol. The WM owns terminal UI, keyboard handling, producer sessions, chrome, window geometry, and lifecycle policy; the embedded Katzensteg producer only renders into the content rect requested through `attach`/`viewport`. Reuse `attach_protocol.zig`, `terminal_batch_applier.zig`, `render_batch_protocol.zig`, and selected attach-host control-message helpers.

**Tech Stack:** Zig 0.15.2, Katzensteg launcher/profile system, stdio JSONL embed transport, Kitty terminal graphics batches, focused Zig unit tests plus smoke tests where practical.

---

## File Structure

- Modify: `src/katzensteg/launcher.zig`
  - Add `wm` command parsing, usage text, and dispatch.
  - Keep normal profile launch and `attach` behavior unchanged.

- Create: `src/katzensteg/wm_host.zig`
  - Own the WM state machine, producer sessions, windows, event log, geometry calculation, and interactive run loop.
  - First implementation may be single-producer internally, but public names should be plural-friendly.

- Modify: `src/katzensteg/attach_host.zig`
  - Factor reusable control-message writers if needed.
  - Do not add WM chrome or lifecycle policy here.

- Modify: `src/katzensteg/attach_protocol.zig`
  - Add parsing for non-frame lifecycle messages only if the WM needs to distinguish `detached` from ignored lines.
  - Keep frame-batch parsing as the core reusable path.

- Modify: `build.zig`
  - Add `katzensteg-wm-host-test`.
  - Add the new module dependency to the launcher test if needed.

- Create or modify: `scripts/katzensteg/test_wm_fake_peer.py`
  - Optional first smoke: run `katzensteg wm --exec -- <fake peer>` or a test-only equivalent if the interactive command has a scripted mode.

- Modify: `docs/katzensteg/launcher-usage.md`
  - Document `katzensteg wm <profile>` after the first interactive slice works.

---

## Chunk 1: Command Shape And Pure WM State

### Task 1: Parse `katzensteg wm`

**Files:**
- Modify: `src/katzensteg/launcher.zig`

- [ ] **Step 1: Write launcher parser tests**

Add tests near the existing command parser tests:

```zig
test "launcher command parser recognizes wm profile target" {
    try std.testing.expectEqual(Command.wm, parseCommand(&.{ "katzensteg", "wm", "probe.embed.basic_sdl" }));
}

test "launcher rejects wm without a profile target" {
    try std.testing.expectEqual(Command.unknown, parseCommand(&.{ "katzensteg", "wm" }));
}
```

- [ ] **Step 2: Run launcher tests and verify failure**

Run:

```bash
zig build test
```

Expected: fail because `Command.wm` does not exist.

- [ ] **Step 3: Add command enum and parser branch**

Add `wm` to `Command`. In `parseCommand`, treat `args[1] == "wm"` as `.wm` only when a profile/target argument follows. Do not let `wm` fall through as a normal profile name.

- [ ] **Step 4: Update usage text**

Add:

```text
katzensteg wm <profile>
```

Describe it as an interactive terminal host for an embedded producer.

- [ ] **Step 5: Run tests**

Run:

```bash
zig build test
```

Expected: pass or fail only on later not-yet-implemented dispatch if added in the same edit.

### Task 2: Define WM Geometry And Chrome State

**Files:**
- Create: `src/katzensteg/wm_host.zig`
- Modify: `build.zig`

- [ ] **Step 1: Write geometry tests**

Create `wm_host.zig` with tests first:

```zig
test "wm window derives content rect inside text chrome" {
    const outer = Rect{ .row = 1, .col = 1, .rows = 20, .cols = 80 };
    const content = contentRectForOuter(outer);
    try std.testing.expectEqual(Rect{ .row = 3, .col = 2, .rows = 17, .cols = 78 }, content);
}

test "wm window clamps outer rect to terminal" {
    const clamped = clampOuterRect(
        .{ .row = 20, .col = 75, .rows = 10, .cols = 20 },
        .{ .rows = 24, .cols = 80 },
    );
    try std.testing.expect(clamped.row >= 1);
    try std.testing.expect(clamped.col >= 1);
    try std.testing.expect(clamped.row + clamped.rows - 1 <= 24);
    try std.testing.expect(clamped.col + clamped.cols - 1 <= 80);
}
```

Use a local `Rect` with the same 1-based cell convention as `PresentationRectCells`.

- [ ] **Step 2: Add build test**

In `build.zig`, add:

```zig
addUnitTest(b, test_step, "katzensteg-wm-host-test", "src/katzensteg/wm_host.zig", target, optimize, use_llvm, .{
    .termscene = termscene_mod,
});
```

Adjust dependencies if the file does not need `termscene`.

- [ ] **Step 3: Run tests and verify failure**

Run:

```bash
zig build test
```

Expected: fail because the WM types/functions are missing.

- [ ] **Step 4: Implement minimal geometry**

Implement:

- `Rect`
- `TerminalSize`
- `contentRectForOuter`
- `clampOuterRect`
- conversion from content rect to `render_batch_protocol.PresentationRectCells`

Use text chrome assumptions for slice 1:

- top title row consumes 1 row
- top separator/border consumes 1 row
- left/right border consumes 1 col each
- bottom border consumes 1 row

- [ ] **Step 5: Run tests**

Run:

```bash
zig build test
```

Expected: pass.

---

## Chunk 2: Single Producer Interactive Host

### Task 3: Model Producer Session Without Terminal I/O

**Files:**
- Modify: `src/katzensteg/wm_host.zig`

- [ ] **Step 1: Write producer state tests**

Add tests for pure state transitions:

```zig
test "wm producer records attach viewport detach shutdown events" {
    var log = ProtocolEventLog.init(std.testing.allocator, 8);
    defer log.deinit();

    try log.record(.attach_sent, "main");
    try log.record(.viewport_sent, "main");
    try log.record(.detach_sent, "main");
    try log.record(.shutdown_sent, "session");

    try std.testing.expectEqual(@as(usize, 4), log.len());
    try std.testing.expectEqual(EventKind.attach_sent, log.last().?.kind);
}
```

Adjust exact expectations after choosing the log API.

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
zig build test
```

Expected: fail because the log/session model is missing.

- [ ] **Step 3: Implement pure session state**

Implement:

- `EventKind`
- `ProtocolEvent`
- `ProtocolEventLog`
- `ProducerSessionState`
- `WmWindowState`

Keep this independent of child process spawning so tests stay cheap.

- [ ] **Step 4: Run tests**

Run:

```bash
zig build test
```

Expected: pass.

### Task 4: Launch One Embedded Producer

**Files:**
- Modify: `src/katzensteg/wm_host.zig`
- Modify: `src/katzensteg/launcher.zig`

- [ ] **Step 1: Add dispatch test at parser level only**

Do not spawn an app in a Zig unit test. Prove that `wm` preserves the target string:

```zig
test "launcher parses wm target" {
    const args = &.{ "katzensteg", "wm", "probe.embed.basic_sdl" };
    const wm = parseWmArgs(args).?;
    try std.testing.expectEqualStrings("probe.embed.basic_sdl", wm.profile_name);
}
```

- [ ] **Step 2: Implement `parseWmArgs`**

Return a small args struct:

```zig
const WmArgs = struct {
    profile_name: []const u8,
};
```

Keep options minimal in the first slice.

- [ ] **Step 3: Add launcher dispatch**

In `.wm`, call:

```zig
const exit_code = try wm_host.runProfile(allocator, wm.profile_name);
std.process.exit(exit_code);
```

Import `wm_host.zig`.

- [ ] **Step 4: Implement child argv construction for producer**

Inside `wm_host.runProfile`, launch:

```text
<current katzensteg executable> --embed-jsonl <profile>
```

Use `std.fs.selfExePathAlloc` where practical. This keeps the WM host using the public embed path instead of reaching into launcher internals.

- [ ] **Step 5: Run tests**

Run:

```bash
zig build test
```

Expected: pass.

### Task 5: Draw Text Chrome And Attach Inner Rect

**Files:**
- Modify: `src/katzensteg/wm_host.zig`
- Modify: `src/katzensteg/attach_host.zig` only if control-message factoring is needed

- [ ] **Step 1: Write chrome rendering tests**

Test rendered lines without a terminal:

```zig
test "wm chrome renders title and content hole" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    try renderChrome(out.writer(std.testing.allocator), .{
        .outer = .{ .row = 1, .col = 1, .rows = 5, .cols = 20 },
        .title = "probe",
        .focused = true,
    });

    try std.testing.expect(std.mem.indexOf(u8, out.items, "probe") != null);
}
```

Keep the test structural; exact Unicode border characters can change.

- [ ] **Step 2: Implement chrome renderer**

Use terminal cursor movement and text output owned by the WM host. Text decoration output must not go through the producer.

Use text first:

- title row
- horizontal separator
- left/right vertical border if it does not interfere with image placement
- status/debug row outside the content rect

- [ ] **Step 3: Send initial attach**

After spawning the child, write:

- `hello`
- `attach` with content rect
- host-selected id ranges
- upload policy

Prefer reusing or factoring `attach_host.writeInitialControl`.

- [ ] **Step 4: Apply frame batches**

Read child stdout as JSONL. For `frame_batch`, call `attach_protocol.parseFrameBatch`, then `terminal_batch_applier.applyFrameBatch` to write producer-owned bytes to the terminal.

Ignore unknown lifecycle lines at first, but log them.

- [ ] **Step 5: Run the interactive proof**

Build:

```bash
zig build
```

Run:

```bash
./zig-out/bin/katzensteg wm probe.embed.basic_sdl
```

Expected: the terminal shows WM-owned chrome and the producer renders inside the content rect.

---

## Chunk 3: Lifecycle And Viewport Pressure

### Task 6: Shutdown, Cleanup Drain, And Exit

**Files:**
- Modify: `src/katzensteg/wm_host.zig`

- [ ] **Step 1: Write pure lifecycle tests**

Test that closing a session schedules `shutdown` once and enters a draining state.

- [ ] **Step 2: Implement quit key path**

In interactive mode:

- `q` sends `shutdown`
- WM keeps reading stdout for cleanup/lifecycle lines
- after cleanup or timeout, terminate the child process if still alive
- restore terminal state

- [ ] **Step 3: Verify manually**

Run:

```bash
zig build
./zig-out/bin/katzensteg wm probe.embed.basic_sdl
```

Press `q`.

Expected:

- terminal chrome disappears or final state is clean enough to continue shell use
- no producer process remains
- debug log includes `shutdown_sent` and child exit

### Task 7: Move/Resize Sends Viewport

**Files:**
- Modify: `src/katzensteg/wm_host.zig`

- [ ] **Step 1: Write viewport state tests**

Prove that resizing a window changes the content rect and produces a viewport command payload.

- [ ] **Step 2: Add keyboard bindings**

Initial bindings can be simple:

- arrows: move
- shift/control arrows, or `h/j/k/l` variants: resize
- `q`: quit

Avoid consuming keys that must later route to the producer while the WM is in window-management mode.

- [ ] **Step 3: Send `viewport` on content rect change**

Write JSONL to child stdin:

```json
{"type":"viewport","window_id":"main","rect_cells":{"row":3,"col":2,"rows":17,"cols":78},"aspect":"fit"}
```

Use `render_batch_protocol.writeJsonString` for string fields.

- [ ] **Step 4: Verify manually**

Run:

```bash
zig build
./zig-out/bin/katzensteg wm probe.embed.basic_sdl
```

Move/resize the window.

Expected:

- status/debug geometry updates
- producer content follows the inner rect
- stale placements from previous rect are cleared by runtime batches

---

## Chunk 4: Multi-Producer Early Slice

### Task 8: Add Session List And Focus

**Files:**
- Modify: `src/katzensteg/wm_host.zig`

- [ ] **Step 1: Refactor single session into array/list**

If earlier tasks used a single `ProducerSession`, change host state to:

```zig
sessions: std.ArrayList(ProducerSession)
focused_index: ?usize
```

- [ ] **Step 2: Write focus tests**

Test next/previous focus changes active window and chrome state without spawning children.

- [ ] **Step 3: Add focus key**

Use `tab` or a simple key like `n` for next window.

- [ ] **Step 4: Render active/inactive chrome**

The focused window gets active title styling; inactive windows remain visible but muted.

### Task 9: Launch A Second Producer

**Files:**
- Modify: `src/katzensteg/wm_host.zig`

- [ ] **Step 1: Add command shape**

Keep this simple for the first multi-producer proof:

```bash
katzensteg wm <profile-a> <profile-b>
```

or an interactive `l` launch prompt if parsing multiple profiles makes the launcher awkward. Prefer multiple profile args first because it is testable.

- [ ] **Step 2: Allocate distinct id ranges per session**

Avoid cross-session cleanup conflicts by assigning non-overlapping ranges, for example:

- session 0 images `100000..199999`, placements `200000..299999`
- session 1 images `300000..399999`, placements `400000..499999`

- [ ] **Step 3: Verify multi-producer manually**

Run two lightweight profiles.

Expected:

- both windows render
- focus switches chrome
- closing one window does not corrupt the other
- terminating one producer does not terminate the other

---

## Chunk 5: Docs And Regression Tests

### Task 10: Document WM Usage

**Files:**
- Modify: `docs/katzensteg/launcher-usage.md`
- Modify: `docs/katzensteg/2026-04-30-wm-design.md` if implementation diverged

- [ ] **Step 1: Add usage examples**

Document:

```bash
./zig-out/bin/katzensteg wm probe.embed.basic_sdl
./zig-out/bin/katzensteg wm retroarch.sonic
```

Include current keybindings and lifecycle caveats.

- [ ] **Step 2: Run doc-adjacent smoke**

Run:

```bash
./zig-out/bin/katzensteg --help
./zig-out/bin/katzensteg --dry-run probe.embed.basic_sdl
```

Expected: help mentions `wm`; dry-run behavior unchanged.

### Task 11: Final Verification

**Files:**
- All touched files

- [ ] **Step 1: Run aggregate tests**

Run:

```bash
zig build test
```

Expected: pass.

- [ ] **Step 2: Run full build**

Run:

```bash
zig build
```

Expected: pass.

- [ ] **Step 3: Manual interactive proof**

Run:

```bash
./zig-out/bin/katzensteg wm probe.embed.basic_sdl
```

Exercise:

- initial attach
- move/resize if implemented
- quit/shutdown cleanup

Expected: no orphan child process, terminal usable after exit.

- [ ] **Step 4: Check worktree**

Run:

```bash
git status --short
```

Expected: only intentional source/docs/test changes. Do not include `.superpowers/brainstorm/`.
