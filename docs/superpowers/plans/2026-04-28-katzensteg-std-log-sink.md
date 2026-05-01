# Katzensteg std.log Sink Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Katzensteg-owned `std.log` file sink and migrate Zig preload/runtime call sites away from embedded logging prefixes.

**Architecture:** `src/katzensteg/log.zig` remains the preload-safe file sink and exposes a `std.log` root log function plus scoped `Logger` wrappers. `src/katzensteg/preload.zig` installs that function through `std_options`; converted modules use scoped `std.log` or scoped `Logger` helpers and no longer own prefix strings.

**Tech Stack:** Zig 0.15.2, `std.log`, existing Katzensteg file logger, file-level `zig test`, `zig build`.

---

## Chunk 1: Central std.log Sink and Config Migration

### Task 1: Add testable log formatting

**Files:**
- Modify: `src/katzensteg/log.zig`

- [ ] **Step 1: Write the failing formatting test**

Add a test in `src/katzensteg/log.zig` for a pure helper that formats a line prefix from `std.log.Level`, scope, and message.

Expected behavior:

```zig
try std.testing.expectEqualStrings(
    "katzensteg: warn(config): unknown field",
    try formatStdLogLineForTest(std.testing.allocator, .warn, .config, "unknown field"),
);
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test src/katzensteg/log.zig -lc`

Expected: FAIL because the helper does not exist yet.

- [ ] **Step 3: Implement minimal formatting helper**

Add a small helper in `src/katzensteg/log.zig` that produces one formatted line without a trailing newline. Keep it allocation-backed for testability, and keep production write handling best-effort.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig test src/katzensteg/log.zig -lc`

Expected: PASS.

### Task 2: Add the std.log root function

**Files:**
- Modify: `src/katzensteg/log.zig`
- Modify: `src/katzensteg/preload.zig`

- [ ] **Step 1: Write or extend a failing test for `stdLogFn` behavior**

Add a testable adapter path in `src/katzensteg/log.zig` that proves `.warn` plus `.config` delegates to the central formatting policy.

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test src/katzensteg/log.zig -lc`

Expected: FAIL until the adapter exists.

- [ ] **Step 3: Implement `pub fn stdLogFn`**

Implement a `std.log`-compatible function in `src/katzensteg/log.zig`. It must not call `std.log`; it should format into a bounded buffer or use the existing `Logger.writeFmt` path without recursion.

- [ ] **Step 4: Wire the preload root**

In `src/katzensteg/preload.zig`, import `log.zig` and add:

```zig
pub const std_options = .{
    .logFn = log.stdLogFn,
};
```

- [ ] **Step 5: Run tests**

Run: `zig test src/katzensteg/log.zig -lc`

Expected: PASS.

### Task 3: Convert `config.zig`

**Files:**
- Modify: `src/katzensteg/config.zig`
- Modify callers in: `src/katzensteg/runtime.zig`

- [ ] **Step 1: Write failing compile/test check**

Update `src/katzensteg/config.zig` tests or add one if needed so the public API no longer requires a `Logger` argument. Attempt to run:

Run: `zig test src/katzensteg/config.zig -lc`

Expected: FAIL before the API and callers are updated.

- [ ] **Step 2: Convert config logging**

Remove `Logger` imports and optional logger parameters from:

```zig
loadRuntimeConfig
parseRuntimeConfigJsonSlice
applyRuntimeConfigEnvValue
```

Add:

```zig
const log = std.log.scoped(.config);
```

Replace local prefix-bearing messages with scoped calls such as:

```zig
log.warn("unknown composite_mode in config: {s}", .{value.string});
log.info("loaded config from {s}", .{path});
```

- [ ] **Step 3: Update runtime callers**

Update `src/katzensteg/runtime.zig` call sites to use the new config API without passing `runtime.logger` or `logger`.

- [ ] **Step 4: Run tests**

Run: `zig test src/katzensteg/config.zig -lc`

Expected: PASS.

### Task 4: Build verification

**Files:**
- No additional files expected.

- [ ] **Step 1: Run build**

Run: `zig build -Doptimize=Debug`

Expected: exit 0.

- [ ] **Step 2: Inspect remaining migration scope**

Run: `rg -n "katzensteg:|katzensteg-trace:|writeFmt|writeOnce|std\\.log" src/katzensteg -g '*.zig'`

Expected: `config.zig` no longer has embedded `katzensteg:` logging prefixes; launcher output and non-log producer display strings may still include `katzensteg:`.

### Task 5: Convert broader Zig producer-side logging

**Files:**
- Modify: `src/katzensteg/runtime.zig`
- Modify: `src/katzensteg/whiskers_client.zig`
- Modify: `src/katzensteg/intercept_sink.zig`
- Modify: `src/katzensteg/preload.zig`
- Modify: `src/katzensteg/frame_builder.zig`

- [ ] **Step 1: Convert runtime and whiskers**

Use `std.log.scoped(.runtime)` and `std.log.scoped(.whiskers)` for ordinary messages. Remove the `Logger` field from `WhiskersClient`.

- [ ] **Step 2: Convert intercept and preload**

Use `std.log.scoped(.intercept)`, `.sdl`, and `.gl`. Keep SDL trace logging behind `KATZENSTEG_TRACE_SDL`.

- [ ] **Step 3: Convert frame builder**

Use scoped `Logger` wrappers so existing `Logger` parameters and `writeOnce` suppression can remain in place.

- [ ] **Step 4: Run verification**

Run:

```bash
zig test --dep termscene --dep katzensteg_sdl -Mroot=src/katzensteg/frame_builder.zig -Mtermscene=src/termscene/mod.zig -Mkatzensteg_sdl=src/katzensteg/sdl2.zig -lc
zig build -Doptimize=Debug
```

Expected: both commands pass.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-04-28-katzensteg-std-log-sink-design.md docs/superpowers/plans/2026-04-28-katzensteg-std-log-sink.md src/katzensteg/log.zig src/katzensteg/preload.zig src/katzensteg/config.zig src/katzensteg/runtime.zig src/katzensteg/whiskers_client.zig src/katzensteg/intercept_sink.zig src/katzensteg/frame_builder.zig
git commit -m "feat: add katzensteg std log sink"
```
