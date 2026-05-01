# Attach Host Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `katzensteg attach --exec -- <argv...>` as a terminal-owning host for Katzensteg JSONL render peers.

**Architecture:** Keep `--embed-jsonl` as the producer mode and add a separate attach host mode. The host spawns any stdio JSONL peer, sends `hello`/`attach`, parses `frame_batch` JSONL, decodes the string-safe terminal byte chunks, and writes those bytes to the host terminal using shared terminal/Kitty mechanics. Socket transport, input events, overlays, menus, and multiple windows are preserved as protocol/UI extensions, not first-cut requirements.

**Tech Stack:** Zig 0.15.2, existing launcher executable, existing JSONL render batch protocol, existing `DirectTty`, Zig file-level tests, Python smoke tests.

---

## Scope And First-Cut Constraints

- Add host mode as `katzensteg attach --exec -- <program> [args...]`.
- `--exec` is argv-only. Do not add shell-string parsing.
- First cut supports one peer transport: stdio child process.
- The peer command may be `katzensteg --embed-jsonl <profile>`, `ssh ...`, `socat ...`, or another implementation of the protocol.
- The attach host owns the user terminal and writes decoded terminal bytes to it.
- The attach host sends the initial `hello` and `attach` messages.
- First cut uses a fixed/default attach geometry derived from the terminal size.
- First cut uses one `window_id`: `main`.
- First cut forwards no keyboard/mouse events to the peer.
- Socket mode is later, but the internal transport boundary must make `--socket <path>` straightforward.

## File Structure

- Modify `src/katzensteg/launcher.zig`
  - Add top-level `attach` command parsing.
  - Parse `attach --exec -- <argv...>`.
  - Dispatch to attach host implementation.
  - Keep existing profile launch and `--embed-jsonl` behavior unchanged.
- Create `src/katzensteg/attach_protocol.zig`
  - Parse peer JSONL messages needed by the host, starting with `frame_batch`.
  - Own decoded message structs and deinit logic.
  - Keep protocol-level parsing separate from terminal application.
- Create `src/katzensteg/terminal_batch_applier.zig`
  - Apply decoded batch groups to a writer in deterministic order: `deletes`, `uploads`, `placements`, `after`.
  - Keep this reusable for future direct/socket attach hosts.
- Create `src/katzensteg/attach_host.zig`
  - Spawn stdio peer.
  - Send `hello` and `attach`.
  - Read peer stdout JSONL.
  - Apply `frame_batch` messages to `DirectTty`.
  - Drain peer stderr to file or inherit policy as selected by caller.
- Create `scripts/katzensteg/test_attach_exec.py`
  - End-to-end smoke test with outer attach host and inner `katzensteg --embed-jsonl probe.embed.basic_sdl`.
- Modify `docs/katzensteg/launcher-usage.md`
  - Document `attach --exec --`.
  - Clarify difference between producer mode and host mode.

---

## Chunk 1: Attach CLI Shape

### Task 1: Parse `attach --exec -- <argv...>`

**Files:**
- Modify: `src/katzensteg/launcher.zig`

- [ ] **Step 1: Write failing parser tests**

Add tests near the existing launcher command parser tests:

```zig
test "launcher parses attach exec argv command" {
    const args = &.{ "katzensteg", "attach", "--exec", "--", "katzensteg", "--embed-jsonl", "probe.embed.basic_sdl" };
    try std.testing.expectEqual(Command.attach, parseCommand(args));
    const attach = parseAttachArgs(args).?;
    try std.testing.expectEqualStrings("katzensteg", attach.exec_argv[0]);
    try std.testing.expectEqualStrings("--embed-jsonl", attach.exec_argv[1]);
    try std.testing.expectEqualStrings("probe.embed.basic_sdl", attach.exec_argv[2]);
}

test "launcher rejects attach exec without argv terminator" {
    try std.testing.expect(parseAttachArgs(&.{ "katzensteg", "attach", "--exec", "katzensteg" }) == null);
    try std.testing.expect(parseAttachArgs(&.{ "katzensteg", "attach", "--exec", "--" }) == null);
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
zig test -lc -lSDL2 --dep termscene --dep katzensteg_sdl -Mroot=src/katzensteg/launcher.zig -Mtermscene=src/termscene/mod.zig -Mkatzensteg_sdl=src/katzensteg/sdl2.zig
```

Expected: FAIL because `Command.attach` and `parseAttachArgs` do not exist.

- [ ] **Step 3: Implement minimal parser**

Add:

```zig
const AttachArgs = struct {
    exec_argv: []const []const u8,
};
```

Rules:

- `katzensteg attach --exec -- <argv...>` is valid.
- `--exec` must appear before `--`.
- argv after `--` must be non-empty.
- `--socket` is reserved and should return invalid for now.
- Unknown attach options return invalid.

Update `usageText()` to include:

```text
katzensteg attach --exec -- <program> [args...]
```

- [ ] **Step 4: Run launcher tests**

Run the same `zig test ... launcher.zig` command.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/katzensteg/launcher.zig
git commit -m "feat: parse attach exec command"
```

---

## Chunk 2: Host-Side Protocol Decode And Terminal Apply

### Task 2: Parse `frame_batch` JSONL For The Host

**Files:**
- Create: `src/katzensteg/attach_protocol.zig`

- [ ] **Step 1: Write failing parser test**

Create:

```zig
test "attach protocol parses frame batch groups" {
    const line =
        \\{"type":"frame_batch","window_id":"main","seq":2,"groups":{"deletes":["\u001b_Ga=d;\u001b\\"],"uploads":["\u001b_Ga=t;\u001b\\"],"placements":["\u001b[1;1H\u001b_Ga=p;\u001b\\"],"after":[]}}
    ;
    var batch = try parseFrameBatch(std.testing.allocator, line);
    defer batch.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("main", batch.window_id);
    try std.testing.expectEqual(@as(u64, 2), batch.seq);
    try std.testing.expectEqual(@as(usize, 1), batch.groups.uploads.len);
    try std.testing.expect(std.mem.indexOfScalar(u8, batch.groups.uploads[0], 0x1b) != null);
}
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
zig test src/katzensteg/attach_protocol.zig
```

Expected: FAIL because file/function do not exist.

- [ ] **Step 3: Implement minimal parser**

Implement:

- `FrameBatch`
- `FrameBatchGroups`
- `parseFrameBatch(allocator, line)`
- `deinit`

Use `std.json.parseFromSlice(std.json.Value, ...)`, validate `type == "frame_batch"`, duplicate decoded strings into owned slices, and reject missing groups.

- [ ] **Step 4: Run parser test**

Run:

```bash
zig test src/katzensteg/attach_protocol.zig
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/katzensteg/attach_protocol.zig
git commit -m "feat: parse attach frame batches"
```

### Task 3: Apply Decoded Batch Groups To A Terminal Writer

**Files:**
- Create: `src/katzensteg/terminal_batch_applier.zig`
- Test: `src/katzensteg/terminal_batch_applier.zig`

- [ ] **Step 1: Write failing ordering test**

Create:

```zig
test "terminal batch applier writes groups in presentation order" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    try applyFrameBatch(out.writer(std.testing.allocator), .{
        .deletes = &.{"D"},
        .uploads = &.{"U"},
        .placements = &.{"P"},
        .after = &.{"A"},
    });

    try std.testing.expectEqualStrings("DUPA", out.items);
}
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
zig test src/katzensteg/terminal_batch_applier.zig
```

Expected: FAIL because file/function do not exist.

- [ ] **Step 3: Implement minimal applier**

Implement:

```zig
pub const BatchGroupsView = struct {
    deletes: []const []const u8,
    uploads: []const []const u8,
    placements: []const []const u8,
    after: []const []const u8,
};

pub fn applyFrameBatch(writer: anytype, groups: BatchGroupsView) !void
```

Write chunks in order: `deletes`, `uploads`, `placements`, `after`.

- [ ] **Step 4: Run applier test**

Run:

```bash
zig test src/katzensteg/terminal_batch_applier.zig
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/katzensteg/terminal_batch_applier.zig
git commit -m "feat: apply terminal render batches"
```

---

## Chunk 3: Attach Host Over Exec Stdio

### Task 4: Add Attach Host Core

**Files:**
- Create: `src/katzensteg/attach_host.zig`
- Modify: `src/katzensteg/launcher.zig`

- [ ] **Step 1: Write focused attach host command test**

In `attach_host.zig`, add a small test that builds the initial control messages without spawning:

```zig
test "attach host writes hello and attach control messages" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    try writeInitialControl(out.writer(std.testing.allocator), .{
        .window_id = "main",
        .rect_cells = .{ .row = 1, .col = 1, .rows = 24, .cols = 80 },
        .image_ids = .{ .start = 100000, .end = 199999 },
        .placement_ids = .{ .start = 200000, .end = 299999 },
    });

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"type\":\"hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"type\":\"attach\"") != null);
}
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
zig test -lc --dep termscene --dep katzensteg_sdl -Mroot=src/katzensteg/attach_host.zig -Mtermscene=src/termscene/mod.zig -Mkatzensteg_sdl=src/katzensteg/sdl2.zig
```

Expected: FAIL because attach host does not exist.

- [ ] **Step 3: Implement control writer and host options**

Implement:

- `AttachOptions`
- `AttachGeometry`
- `writeInitialControl`
- default id ranges:
  - images: `100000..199999`
  - placements: `200000..299999`

Use `render_batch_protocol.writeJsonString` or equivalent small helper so message writing is safe.

- [ ] **Step 4: Run attach host unit test**

Run the same `zig test ... attach_host.zig` command.

Expected: PASS.

- [ ] **Step 5: Wire launcher dispatch**

In `launcher.zig`:

- import `attach_host.zig`
- when command is `attach`, call `attach_host.runExec(allocator, attach.exec_argv)`
- return its exit code

Add a launcher test proving attach command dispatch does not affect existing profile command parsing.

- [ ] **Step 6: Run launcher and attach host tests**

Run:

```bash
zig test -lc -lSDL2 --dep termscene --dep katzensteg_sdl -Mroot=src/katzensteg/launcher.zig -Mtermscene=src/termscene/mod.zig -Mkatzensteg_sdl=src/katzensteg/sdl2.zig
zig test -lc --dep termscene --dep katzensteg_sdl -Mroot=src/katzensteg/attach_host.zig -Mtermscene=src/termscene/mod.zig -Mkatzensteg_sdl=src/katzensteg/sdl2.zig
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/katzensteg/launcher.zig src/katzensteg/attach_host.zig
git commit -m "feat: add attach exec host command"
```

### Task 5: Implement Exec Transport Loop

**Files:**
- Modify: `src/katzensteg/attach_host.zig`

- [ ] **Step 1: Write fake peer integration test**

Prefer a Python smoke test if Zig spawning makes this too awkward. The fake peer should:

- read control JSONL from stdin
- emit one `frame_batch` JSONL line to stdout
- exit

The host should:

- spawn the fake peer with `attach --exec --`
- not print JSONL itself
- apply decoded batch bytes to a captured writer in the unit path, or complete successfully in the smoke path

- [ ] **Step 2: Run test to verify failure**

Run the selected test.

Expected: FAIL because the exec loop does not read/apply peer frames yet.

- [ ] **Step 3: Implement exec transport**

In `attach_host.runExec`:

- open `DirectTty.init()`
- spawn child with stdin pipe and stdout pipe
- write initial `hello` and `attach` to child stdin
- read child stdout line-by-line
- parse `frame_batch`
- apply groups to `tty.file.deprecatedWriter()` or a streaming writer
- keep child stderr inherited or drained to host stderr for now
- best-effort terminal cleanup on exit via `DirectTty.deinit()`

Important: do not send protocol JSONL to host stdout in attach mode. The attach host owns the terminal.

- [ ] **Step 4: Run fake peer test**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/katzensteg/attach_host.zig scripts/katzensteg/test_attach_exec_fake_peer.py
git commit -m "feat: run attach exec stdio transport"
```

---

## Chunk 4: Real Katzensteg Producer Smoke

### Task 6: Add End-To-End Attach Smoke Test

**Files:**
- Create: `scripts/katzensteg/test_attach_exec.py`
- Modify: `docs/katzensteg/launcher-usage.md`

- [ ] **Step 1: Write smoke test**

Create a Python `unittest` that runs:

```bash
./zig-out/bin/katzensteg attach --exec -- ./zig-out/bin/katzensteg --embed-jsonl probe.embed.basic_sdl
```

Test constraints:

- require the default `zig build` first or invoke it in the test
- run with a timeout
- assert process starts and exits/terminates cleanly
- assert no raw JSONL appears in the parent stdout if stdout is captured
- use `/tmp/katzensteg-*.log` or profile output only for diagnostics

If testing real terminal drawing from CI is fragile, make this a local smoke script and keep the fake peer test as the deterministic automated test.

- [ ] **Step 2: Run smoke to verify failure before implementation is complete**

Run:

```bash
python3 scripts/katzensteg/test_attach_exec.py
```

Expected before implementation: FAIL.

- [ ] **Step 3: Fix attach host until smoke passes**

Common failure modes:

- attach host writes JSONL to stdout instead of terminal bytes
- control messages are not flushed before child waits for attach
- parser rejects escaped ESC bytes
- terminal cleanup closes the wrong fd
- child stdout/stderr policies leak human launcher output

- [ ] **Step 4: Document usage**

Update `docs/katzensteg/launcher-usage.md` with:

```sh
./zig-out/bin/katzensteg attach --exec -- ./zig-out/bin/katzensteg --embed-jsonl probe.embed.basic_sdl
```

Explain:

- outer process is host/terminal owner
- inner command is any stdio JSONL peer
- `--embed-jsonl` is just one producer implementation
- socket transport will reuse the host protocol/presenter path later

- [ ] **Step 5: Run focused verification**

Run:

```bash
zig test src/katzensteg/attach_protocol.zig
zig test src/katzensteg/terminal_batch_applier.zig
zig test -lc --dep termscene --dep katzensteg_sdl -Mroot=src/katzensteg/attach_host.zig -Mtermscene=src/termscene/mod.zig -Mkatzensteg_sdl=src/katzensteg/sdl2.zig
zig test -lc -lSDL2 --dep termscene --dep katzensteg_sdl -Mroot=src/katzensteg/launcher.zig -Mtermscene=src/termscene/mod.zig -Mkatzensteg_sdl=src/katzensteg/sdl2.zig
zig build
python3 scripts/katzensteg/test_embed_render_batches.py
python3 scripts/katzensteg/test_attach_exec.py
```

Expected: PASS, except any explicitly marked local-only terminal smoke should report SKIP when no TTY is available.

- [ ] **Step 6: Commit**

```bash
git add scripts/katzensteg/test_attach_exec.py docs/katzensteg/launcher-usage.md
git commit -m "test: prove attach exec host"
```

---

## Future Work

- `katzensteg attach --socket <path>` transport.
- Host-side resize/reattach messages when terminal size changes.
- Host-side overlays and menus.
- Focused keyboard/mouse events from PTY owner to renderer process.
- Multiple `window_id`s and attach/detach lifecycle.
- Optional richer metadata mode for hosts that do not want opaque terminal bytes.
