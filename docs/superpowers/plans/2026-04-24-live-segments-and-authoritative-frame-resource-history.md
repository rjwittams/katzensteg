# Live Segments + Authoritative Frame/Resource History Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a segment-aware live inspector API and UI for Katzensteg so capture periods are first-class, frames belong to segments, frame explanation is authoritative, and resource state is correct as-of the selected frame.

**Architecture:** Extend the current in-library inspector from a flat frame/resource snapshot into a bounded live segment store with explicit capture control, per-segment sequencing, frame-local events/mappings, and time-correct resource history. Then cut the browser UI over to the new segment/frame API directly, without preserving the old API shape.

**Tech Stack:** Zig, std HTTP-over-UDS inspector server, Python HTTP proxy, browser React/Babel UI, existing Katzensteg runtime/frame builder/intercept pipeline.

---

## File structure / responsibilities

### Existing files to modify
- `tools/katzensteg/inspector.zig`
  - Expand from flat frame/resource lists to segment-aware live store.
  - Define control endpoints and new segment/frame/resource API payloads.
- `tools/katzensteg/intercept_sink.zig`
  - Feed richer frame/event/resource records into the inspector.
- `tools/katzensteg/runtime.zig`
  - Own capture state transitions and expose enough state for segment lifecycle.
- `tools/katzensteg/frame_builder.zig`
  - Surface authoritative per-frame summary, mapping hints, and resource version records.
- `tools/katzensteg/inspect_web_proxy.py`
  - No protocol redesign required for this slice, but keep route passthrough working for new endpoints.
- `tools/katzensteg/inspector-web/mock-data.js`
  - Replace compatibility/synthetic adapter behavior with direct consumption of the new segment-aware API.
- `tools/katzensteg/inspector-web/app.jsx`
  - Switch UI state to segment-aware browsing.
- `tools/katzensteg/inspector-web/timeline.jsx`
  - Drive timeline from a selected segment frame index.
- `tools/katzensteg/inspector-web/panels.jsx`
  - Read authoritative frame detail and resource-as-of-frame data.

### New files that may be created if the implementation becomes unwieldy
- `tools/katzensteg/inspector_model.zig`
  - Optional extraction for segment/frame/event/resource record types if `inspector.zig` becomes too large.
- `tools/katzensteg/inspector_store.zig`
  - Optional extraction for bounded live segment storage and query helpers.

### Existing docs to update after code lands
- `docs/katzensteg/2026-04-24-inspector-full-function-checklist.md`
  - Mark completed items for this slice.
- `docs/katzensteg/2026-04-24-inspector-brainstorm-prompts.md`
  - Only if implementation resolves a prompt enough to remove/reword it.

---

## Chunk 1: Segment model and capture control API

### Task 1: Add explicit live segment records to the inspector model

**Files:**
- Modify: `tools/katzensteg/inspector.zig`
- Test: `tools/katzensteg/inspector.zig` Zig unit tests near existing inspector tests

- [ ] **Step 1: Add failing unit test for segment lifecycle bookkeeping**

Add a Zig test that exercises:
- inspector starts with zero segments
- starting capture creates one active segment
- stopping capture closes it
- repeated stop does not create a new segment

Test sketch:

```zig
test "inspector segment lifecycle is idempotent" {
    var logger = Logger.init(std.testing.allocator);
    defer logger.deinit();
    var inspector = try Inspector.init(std.testing.allocator, &logger, "/tmp/unused-test-sock");
    defer inspector.deinit();

    try std.testing.expectEqual(@as(usize, 0), inspector.segmentCount());
    try inspector.startCaptureForTest();
    try std.testing.expect(inspector.activeSegmentId() != null);
    try std.testing.expectEqual(@as(usize, 1), inspector.segmentCount());

    try inspector.startCaptureForTest();
    try std.testing.expectEqual(@as(usize, 1), inspector.segmentCount());

    try inspector.stopCaptureForTest();
    try std.testing.expectEqual(@as(?u64, null), inspector.activeSegmentId());
    try std.testing.expectEqual(@as(usize, 1), inspector.segmentCount());

    try inspector.stopCaptureForTest();
    try std.testing.expectEqual(@as(usize, 1), inspector.segmentCount());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test tools/katzensteg/inspector.zig`
Expected: FAIL because segment helpers/records do not exist yet.

- [ ] **Step 3: Add minimal segment record types and storage**

Implement in `tools/katzensteg/inspector.zig`:
- `SegmentRecord`
- bounded `segments` storage
- active segment tracking
- test-only helpers if needed:
  - `segmentCount()`
  - `activeSegmentId()`
  - `startCaptureForTest()`
  - `stopCaptureForTest()`

Keep fields minimal initially:

```zig
pub const SegmentRecord = struct {
    id: u64,
    start_ts_ns: i128,
    end_ts_ns: ?i128 = null,
    frame_count: u64 = 0,
    event_count: u64 = 0,
    bytes_uploaded: u64 = 0,
    skipped_presents: u64 = 0,
    dropped_batches: u64 = 0,
};
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig test tools/katzensteg/inspector.zig`
Expected: PASS for the new lifecycle test.

- [ ] **Step 5: Commit**

```bash
git add tools/katzensteg/inspector.zig
git commit -m "feat: add live segment model to inspector"
```

### Task 2: Add capture control endpoint semantics

**Files:**
- Modify: `tools/katzensteg/inspector.zig`
- Modify: `tools/katzensteg/runtime.zig`
- Test: `tools/katzensteg/inspector.zig` Zig unit tests

- [ ] **Step 1: Add failing unit test for `/capture/start`, `/capture/stop`, and `/capture/clear` semantics**

Add a test that invokes handler helpers directly and asserts:
- `start` is idempotent
- `stop` is idempotent
- `clear` clears live state but does not break future capture

Sketch the assertions in test form rather than using raw sockets if possible.

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test tools/katzensteg/inspector.zig`
Expected: FAIL because control semantics are incomplete/implicit.

- [ ] **Step 3: Implement explicit control-state transitions**

In `tools/katzensteg/inspector.zig` and `tools/katzensteg/runtime.zig`:
- make `start capture` create a segment only on off -> on
- make `stop capture` close a segment only on on -> off
- make `clear` wipe live in-memory capture state
- return explicit JSON control state from:
  - `/capture/start`
  - `/capture/stop`
  - `/capture/clear`
  - `/capture/status`

Expected JSON shape should include at least:

```json
{
  "enabled": true,
  "active_segment_id": 3,
  "segments": 1
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig test tools/katzensteg/inspector.zig`
Expected: PASS.

- [ ] **Step 5: Build to catch runtime integration errors**

Run: `zig build`
Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
git add tools/katzensteg/inspector.zig tools/katzensteg/runtime.zig
git commit -m "feat: define capture control semantics for inspector"
```

---

## Chunk 2: Segment-aware frame/event/resource storage

### Task 3: Add per-segment monotonic event sequencing and frame ownership

**Files:**
- Modify: `tools/katzensteg/inspector.zig`
- Modify: `tools/katzensteg/intercept_sink.zig`
- Test: `tools/katzensteg/inspector.zig`

- [ ] **Step 1: Add failing unit test for per-segment event ordering**

Test should assert:
- events recorded into one segment get strictly increasing sequence ids
- new segment restarts its own sequence namespace only if explicitly designed that way; otherwise keep ids globally unique and document the choice
- frames recorded while no active segment are rejected or attached only after a segment exists (pick one implementation path and assert it)

Recommended implementation contract for this slice:
- `event_seq` monotonic within segment, starting at 1 for each segment

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test tools/katzensteg/inspector.zig`
Expected: FAIL because event sequencing/storage is not implemented.

- [ ] **Step 3: Implement event records with authoritative sequence ordering**

Add event store support in `tools/katzensteg/inspector.zig`:

```zig
pub const EventRecord = struct {
    segment_id: u64,
    event_seq: u64,
    frame_id: ?u64 = null,
    ts_ns: i128,
    kind: []const u8,
    thread: []const u8,
    payload_json: []const u8,
};
```

Use owned strings only if required; otherwise use enums/typed payload structs internally and serialize at response time.

- [ ] **Step 4: Attach frames to active segment at record time**

Update `noteFrame` path so every frame stores:
- `segment_id`
- `frame_id`
- optional sequence references to its local events/mappings

- [ ] **Step 5: Run tests and build**

Run:
- `zig test tools/katzensteg/inspector.zig`
- `zig build`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add tools/katzensteg/inspector.zig tools/katzensteg/intercept_sink.zig
git commit -m "feat: record frames and events within live segments"
```

### Task 4: Make resources versioned as-of-frame, not latest-only

**Files:**
- Modify: `tools/katzensteg/frame_builder.zig`
- Modify: `tools/katzensteg/inspector.zig`
- Modify: `tools/katzensteg/intercept_sink.zig`
- Test: `tools/katzensteg/inspector.zig`

- [ ] **Step 1: Add failing unit test for historical resource correctness**

Test shape:
- record frame 1 with resource state A
- mutate resource to state B
- record frame 2
- query resource as-of frame 1 and frame 2
- assert frame 1 still sees A, frame 2 sees B

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test tools/katzensteg/inspector.zig`
Expected: FAIL because only latest resource state is stored.

- [ ] **Step 3: Add versioned resource records**

Recommended record shape:

```zig
pub const ResourceVersionRecord = struct {
    segment_id: u64,
    event_seq: u64,
    frame_id: ?u64,
    kind: ResourceKind,
    resource_key: u64,
    image_id: u32,
    placement_id: u32,
    w: i32,
    h: i32,
    format: u32,
    blend_mode: i32,
    update_count: u64,
};
```

Use append-only version records. Query helpers should return the latest record whose effective sequence is <= selected frame/event boundary.

- [ ] **Step 4: Teach `frame_builder` / `intercept_sink` to emit version records when resources change**

At minimum, version records should be emitted when:
- texture state changes materially
- composite image id changes
- composite placement id changes
- tile image/placement state changes in tiled mode

- [ ] **Step 5: Add a query helper for resource-as-of-frame**

In `tools/katzensteg/inspector.zig`, add helper(s) such as:
- `resourceVersionAtFrame(...)`
- `resourcesTouchedByFrame(...)`

- [ ] **Step 6: Run tests and build**

Run:
- `zig test tools/katzensteg/inspector.zig`
- `zig build`

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add tools/katzensteg/frame_builder.zig tools/katzensteg/inspector.zig tools/katzensteg/intercept_sink.zig
git commit -m "feat: add versioned live resource history for inspector"
```

---

## Chunk 3: Segment-aware read API

### Task 5: Add `/segments`, `/segment/<id>`, and `/frames?segment=<id>`

**Files:**
- Modify: `tools/katzensteg/inspector.zig`
- Test: `tools/katzensteg/inspector.zig`

- [ ] **Step 1: Add failing tests for segment-aware read endpoints**

Add tests that verify JSON from helper methods or request handling for:
- `/segments`
- `/segment/<id>`
- `/frames?segment=<id>`

Prefer direct helper tests over full socket tests if possible.

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test tools/katzensteg/inspector.zig`
Expected: FAIL because endpoints do not exist yet.

- [ ] **Step 3: Implement endpoint handlers and serializers**

In `tools/katzensteg/inspector.zig`:
- extend path parsing to handle query strings cleanly
- add `/segments`
- add `/segment/<id>`
- add `/frames?segment=<id>`

Frame index payload should be timeline-friendly and small, e.g.:

```json
{
  "id": 41,
  "segment_id": 3,
  "ts_ns": 123,
  "present_ns": 456,
  "queue_depth": 2,
  "strategy_short": "composite"
}
```

- [ ] **Step 4: Run tests and build**

Run:
- `zig test tools/katzensteg/inspector.zig`
- `zig build`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/katzensteg/inspector.zig
git commit -m "feat: add segment-aware inspector read endpoints"
```

### Task 6: Make `/frame/<id>` authoritative for frame explanation

**Files:**
- Modify: `tools/katzensteg/inspector.zig`
- Modify: `tools/katzensteg/frame_builder.zig`
- Modify: `tools/katzensteg/intercept_sink.zig`
- Test: `tools/katzensteg/inspector.zig`

- [ ] **Step 1: Add failing test for authoritative frame detail**

Test should assert that `/frame/<id>` returns:
- frame summary
- fallback reasons
- frame-local events
- operation-level mappings
- touched resource refs

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test tools/katzensteg/inspector.zig`
Expected: FAIL because current frame detail is too sparse.

- [ ] **Step 3: Add frame-local event references and touched resources**

Extend stored frame records with refs or embedded slices to:
- event sequence range or explicit event ids
- touched resource ids/keys
- image/placement ids already known from summaries

- [ ] **Step 4: Add minimal operation-level mapping records**

Implement enough mapping support for the current real use cases:
- upload mapping
- placement mapping
- fallback mapping

Suggested internal shape:

```zig
pub const MappingRecord = struct {
    segment_id: u64,
    frame_id: u64,
    kind: []const u8,
    source_resource_key: u64 = 0,
    image_id: u32 = 0,
    placement_id: u32 = 0,
    reason: ?[]const u8 = null,
};
```

- [ ] **Step 5: Serialize those mappings in `/frame/<id>`**

Keep payloads compact and typed enough for the browser UI to stop inferring them.

- [ ] **Step 6: Run tests and build**

Run:
- `zig test tools/katzensteg/inspector.zig`
- `zig build`

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add tools/katzensteg/inspector.zig tools/katzensteg/frame_builder.zig tools/katzensteg/intercept_sink.zig
git commit -m "feat: make inspector frame detail authoritative"
```

---

## Chunk 4: Browser cutover to the new API

### Task 7: Replace flat-frame browser adapter with segment-aware adapter

**Files:**
- Modify: `tools/katzensteg/inspector-web/mock-data.js`
- Test: manual browser/proxy check via Playwright screenshot and curl

- [ ] **Step 1: Remove old flat API assumptions from the adapter**

Delete dependency on:
- `/frames` as the primary source of all frame browsing
- `/frame/latest` as the only rich frame source
- latest-only resources as if they were historically correct

- [ ] **Step 2: Add segment-aware fetch flow**

Implement a flow like:
1. fetch `/capture/status`
2. fetch `/segments`
3. select active/latest segment
4. fetch `/frames?segment=<id>`
5. fetch `/frame/<selected>`
6. fetch `/resource/<kind>/<id>` only when needed by selected panels

- [ ] **Step 3: Make adapter preserve the new connection/error banner behavior**

Keep the current connection-state UX while changing data sources.

- [ ] **Step 4: Verify with curl that new routes are used correctly**

Run commands like:

```bash
curl -s http://127.0.0.1:8024/inspect/segments
curl -s "http://127.0.0.1:8024/inspect/frames?segment=1"
curl -s http://127.0.0.1:8024/inspect/frame/1
```

Expected: valid JSON matching the new model.

- [ ] **Step 5: Commit**

```bash
git add tools/katzensteg/inspector-web/mock-data.js
git commit -m "feat: switch inspector web adapter to segment-aware api"
```

### Task 8: Make the React UI browse segments and authoritative frame/resource state

**Files:**
- Modify: `tools/katzensteg/inspector-web/app.jsx`
- Modify: `tools/katzensteg/inspector-web/timeline.jsx`
- Modify: `tools/katzensteg/inspector-web/panels.jsx`
- Test: manual browser check + Playwright screenshot

- [ ] **Step 1: Add selected-segment state in the app shell**

In `app.jsx`:
- track selected segment
- default to active/latest segment
- reset selected frame when segment changes

- [ ] **Step 2: Make timeline operate on one segment at a time**

In `timeline.jsx`:
- render frame index for the selected segment
- keep current empty-state safety guards
- do not yet implement horizontal scroll/zoom in this slice

- [ ] **Step 3: Make panels fetch/use authoritative frame/resource data**

In `panels.jsx`:
- stop assuming latest-only resource metadata is good enough
- use touched resource refs from `/frame/<id>`
- only show frame-local events/mappings from the authoritative frame payload

- [ ] **Step 4: Manual validation in browser**

Validate this workflow:
1. start capture
2. produce frames
3. stop capture
4. segment appears
5. selecting a frame shows authoritative counts/timings/fallbacks
6. resources shown for that frame are historically correct for that frame

- [ ] **Step 5: Save screenshot proof**

Run:

```bash
npx playwright screenshot http://127.0.0.1:8024 /tmp/katzensteg-playwright/segment-aware.png
```

Expected: UI renders and shows segment/frame state rather than a flat latest-only model.

- [ ] **Step 6: Commit**

```bash
git add tools/katzensteg/inspector-web/app.jsx tools/katzensteg/inspector-web/timeline.jsx tools/katzensteg/inspector-web/panels.jsx
git commit -m "feat: browse live capture by segment and authoritative frame state"
```

---

## Chunk 5: Documentation and verification

### Task 9: Update docs/checklists to reflect completed slice

**Files:**
- Modify: `docs/katzensteg/2026-04-24-inspector-full-function-checklist.md`
- Modify: `docs/katzensteg/2026-04-24-inspector-brainstorm-prompts.md` (only if necessary)

- [ ] **Step 1: Mark completed checklist items**

Update checklist entries completed by this slice, especially:
- segment model
- control endpoints
- segment-aware frame API
- per-segment event sequencing
- live resource history correctness
- viewer cutover

- [ ] **Step 2: Remove or reword prompts only if they are truly resolved**

Do not delete future prompts unless implementation made them obsolete.

- [ ] **Step 3: Commit**

```bash
git add docs/katzensteg/2026-04-24-inspector-full-function-checklist.md docs/katzensteg/2026-04-24-inspector-brainstorm-prompts.md
git commit -m "docs: update inspector checklist after live segment slice"
```

### Task 10: Final verification pass

**Files:**
- No file changes required unless fixes are found

- [ ] **Step 1: Run the full build**

Run: `zig build`
Expected: PASS.

- [ ] **Step 2: Validate live inspector API manually**

Run representative commands:

```bash
curl -s http://127.0.0.1:8024/inspect/capture/status
curl -s http://127.0.0.1:8024/inspect/segments
curl -s "http://127.0.0.1:8024/inspect/frames?segment=<id>"
curl -s http://127.0.0.1:8024/inspect/frame/<id>
```

Expected: coherent JSON with segment-aware structure.

- [ ] **Step 3: Validate browser workflow manually**

Check:
- start capture
- generate frames
- stop capture
- select segment
- inspect frame
- confirm resources/events/mappings are frame-correct

- [ ] **Step 4: Commit any final fixes if needed**

```bash
git add <fixed-files>
git commit -m "fix: polish live segment inspector slice"
```

---

Plan complete and saved to `docs/superpowers/plans/2026-04-24-live-segments-and-authoritative-frame-resource-history.md`. Ready to execute?
