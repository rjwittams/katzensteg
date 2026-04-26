# Katzensteg inspector full-function design

Date: 2026-04-24
Status: Approved design

## Purpose

Define the first end-to-end design for a **fully functional Katzensteg inspector**.

This design is optimized for **Katzensteg as the first producer**, while keeping the kitty-side resource, timing, and persistence model generic enough that it could later support:
- Cleat
- direct termscene producers
- broader kitty/TUI graphics inspection tools
- a future standalone inspector project such as **Klouseau**

This document is intentionally not a full implementation spec for every endpoint field. It defines:
- the target architecture
- the core data model
- the live API shape
- the persistence model
- the intended ownership boundaries
- the roadmap boundary between “needed for full function” and later generalization

## Goals

The inspector should let a developer answer, reliably and quickly:
- what happened in this capture period?
- what happened in this frame?
- why was a render strategy chosen?
- what SDL-side operations/resources became what kitty-side uploads/placements?
- what did the frame cost in time, bytes, placements, and skipped/dropped work?
- what resources were touched and how did they evolve?

It should support both:
- **live debugging** of a running producer
- **persisted historical capture** replayed through the same viewer model

## Non-goals for this milestone

Not required for the first full-function milestone:
- perfect generic multi-producer normalization
- full region-level provenance
- rich inline image payloads in JSON responses
- final desktop-app packaging choice
- committing to Perfetto or OpenTelemetry as the primary runtime model

Those remain important future directions.

---

## 1. Core model

The inspector is built around five first-class entities.

### 1.1 Segment

A **segment** is a capture period.

A segment:
- starts when capture turns on
- ends when capture turns off
- belongs to a session/run context
- contains frames, events, resource changes, and summary metadata

This is the primary time/navigation boundary for the first full-function design.

### 1.1a Capture control state machine

Capture control is part of the core model, not just UI sugar, because it creates segment boundaries.

Required control operations:
- `start capture`
- `stop capture`
- `clear live capture`
- later optionally `finalize/persist segment` when a proxy/service owns history

Minimum semantics:
- `start capture` when capture is off:
  - create a new active segment
  - emit capture/segment start events
- `start capture` when capture is already on:
  - no-op success
  - must not create a nested or duplicate segment
- `stop capture` when capture is on:
  - close the active segment
  - emit capture/segment end events
- `stop capture` when capture is already off:
  - no-op success
- `clear live capture`:
  - clears bounded in-memory live data
  - must not implicitly destroy already finalized/persisted segments owned by the proxy/service

If a proxy/service owns persistence later, `clear` applies to the producer's live window or current unfinalized live view, not historical recorded captures unless an explicit historical-delete API exists.

### 1.2 Frame

A **frame** is the main debug unit.

A frame:
- usually corresponds to a realized present
- belongs to exactly one segment
- carries timing, counts, fallback reasons, mappings, and touched-resource refs
- is the main unit selected in the timeline and frame detail panes

### 1.3 Event

An **event** is an ordered typed record within a segment.

Events may be:
- frame-bound
- segment-bound
- control/config/state events not naturally attached to a frame

Events provide ordering, explain transitions, and support future wall-time and trace-oriented views.

### 1.4 Resource

A **resource** is a typed object inspected across time.

Initial important resource kinds:
- SDL texture
- kitty image
- kitty placement
- later possibly transport/blob asset

Resources have stable ids and metadata. Preview payloads are referenced, not inlined.

### 1.4a Resource history rule

Resource history must be queryable **as of a selected frame/sequence point**, not only as a latest snapshot.

For the first full-function design, this means:
- persisted `resources.jsonl` cannot be modeled as only a latest-state dump
- each resource record must be either:
  - a full snapshot record with an effective sequence/frame range, or
  - a delta/change record with enough information to reconstruct state at a selected frame
- the viewer-facing API must be able to answer either:
  - "give me resource X as of frame F", or
  - "give me resource history/change records sufficient to reconstruct resource X as of frame F"

The initial recommended rule is:
- resource changes are append-only records in `resources.jsonl`
- each record includes the segment id plus the event sequence/frame boundary at which it became effective
- the service may build indexes/checkpoints later, but the authoritative persisted model must preserve time-correct resource state for historical frame replay

### 1.5 Mapping

A **mapping** is an explicit cross-layer relationship.

For the first full-function milestone, mappings are primarily **operation-level**:
- `SDL_UpdateTexture` -> kitty upload
- `SDL_RenderCopy` -> kitty placement
- unsupported blend mode -> composite fallback

Region-level provenance is deferred.

---

## 2. Time model

### 2.1 Primary model: segmented capture timeline

The primary time model is **segmented capture periods**.

This means:
- the UI should show captured sections cleanly
- frames are ordered within a segment
- segments have real start/end timestamps
- zoom/scroll should eventually operate within and across segments

### 2.2 Deferred alternate mode: expanded real wall time

Later, the inspector may offer a mode that expands uncaptured or idle gaps in real wall time.

That is explicitly a later presentation mode layered on top of the same segment/frame/event model.

### 2.3 Why not full event-first tracing now

A fully trace-first model is attractive long-term, but for the first full-function inspector it adds too much complexity.

The chosen approach keeps enough event structure to later export or adapt toward:
- Perfetto-like traces
- OpenTelemetry-shaped exports
- more general terminal devtools

without making those the initial source of truth.

---

## 3. Architecture and ownership

### 3.1 Intended destination

The intended destination is a **standalone inspector service/store**.

This service may eventually live outside the ttytris repo and may plausibly become a separate project, possibly with a Rust/Axum/Tauri implementation.

### 3.2 Compatibility/dev fallback

An **embedded producer-hosted inspector** remains allowed as:
- a compatibility mode
- a development fallback
- a simpler local bootstrap path

### 3.3 Hard requirement

Regardless of topology, the inspector must keep:
- one common data model
- one common viewer-facing API shape
- one common persistence model

The viewer should not care whether data came from:
- a live embedded server
- a standalone service/store
- a persisted segment directory replayed by the proxy/service

### 3.4 Mode A: producer-hosted inspector

In this mode:
- the producer hosts a server/socket
- the proxy or browser-facing tool connects to it
- the producer owns bounded live state

This is useful now and remains useful later.

### 3.5 Mode B: standalone service/store

This is the preferred long-term mode.

In this mode:
- the service owns the rendezvous/listening endpoint
- the producer connects if configured or if a well-known endpoint exists
- the producer continues normally if the service is absent
- the service records, retains, and serves captured data

This is better suited for:
- multi-run workflows
- historical retention
- future multi-producer support
- packaging as a real devtools application

### 3.6 Responsibility split

#### Producer responsibilities
- generate authoritative live segment/frame/event/resource/mapping data
- retain only a bounded live window
- degrade cleanly when no inspector service is present
- avoid requiring persistence to function normally

#### Proxy/service responsibilities
- connect to one or more producers
- record and finalize segments
- persist capture data to disk
- serve historical captures using the same viewer API shape
- later support sessions/runs/comparisons

---

## 4. Live API shape

The live API should mirror the persisted data model closely.

### 4.1 Core endpoints

#### `/capture/status`
Returns:
- session/config snapshot
- capture enabled state
- active segment id if any
- live retention metadata
- control-state metadata needed to drive the UI safely

#### `/capture/start`
Starts capture.

Required semantics:
- idempotent success if capture is already on
- creates a new active segment only on the off -> on transition
- returns enough state for the UI to know the active segment id and capture state

#### `/capture/stop`
Stops capture.

Required semantics:
- idempotent success if capture is already off
- closes the active segment only on the on -> off transition
- returns enough state for the UI to know capture is off and the just-closed segment if applicable

#### `/capture/clear`
Clears bounded live capture state.

Required semantics:
- clears live in-memory capture state and indexes used by the live viewer
- must not delete already finalized/persisted historical segments unless a separate explicit historical-delete API exists
- if capture is currently on, implementation may either reject clear or define clear-as-reset-and-open-new-segment, but this must be explicit in the concrete implementation contract

#### `/segments`
Returns a segment index for the current live view.

Each segment record should include:
- `segment_id`
- start/end time
- frame count
- event count
- summary counters

#### `/segment/<id>`
Returns:
- full segment metadata
- summary stats
- maybe lightweight indexes/references for frames/resources/events

#### `/frames?segment=<id>`
Returns a segment frame index suitable for timeline rendering.

There is no requirement to preserve the current pre-segment viewer API unchanged. The inspector/viewer may change in step with the new segment-aware API.

#### `/frame/<id>`
This is the main explanatory endpoint.

It should authoritatively include:
- frame summary
- timing/counts/strategy/fallbacks
- frame-local events
- operation-level mappings
- touched-resource refs

Resources themselves may still be fetched separately.

#### `/resources`
Returns a resource index/query surface.

Useful filters later may include:
- kind
- segment
- active/inactive
- touched-by-frame

#### `/resource/<kind>/<id>`
Returns full metadata for a typed resource.

#### `/blobs/<id>` or `/asset/<id>`
Returns blob/preview payloads referenced by resource or frame records.

Blob refs should carry explicit format/mime information.

### 4.2 Frame payload standard

For first full function, `/frame/<id>` should be strong enough to explain a frame without forcing the UI to reconstruct meaning from unrelated endpoints.

It should include:
- summary/timings/counts
- fallback reasons
- frame-local events
- operation-level mappings
- refs to touched resources

But it does **not** need to inline large preview payloads.

---

## 5. Persistence model

### 5.1 Storage shape

Persisted capture uses:
- **directory per segment**
- append-friendly JSONL streams
- blob files alongside

### 5.2 Initial files

A segment directory should support at least:
- `frames.jsonl`
- `resources.jsonl`
- `events.jsonl`

`resources.jsonl` is a history stream, not merely a latest-state inventory. Resource records must be sufficient to reconstruct resource state as of a selected frame/sequence point.

A later `mappings.jsonl` is acceptable if mappings become too large or awkward to store only inside frame records.

### 5.3 Blob/payload handling

Large preview and raw payloads should be separate files referenced by id/path/format metadata.

The system should optimize for:
- append friendliness
- crash tolerance
- human inspectability
- later indexing/compaction

### 5.4 Optional derived files later

Later the service may add:
- `summary.json`
- indexes
- caches
- thumbnails or transformed previews

Those are derived conveniences, not the primary append path.

---

## 6. Identity and ordering rules

The model requires stable ids so that live and persisted data can be matched and served consistently.

### 6.1 Required ids

At minimum:
- `session_id`
- `segment_id`
- `frame_id`
- `event_seq` or equivalent monotonic per-segment sequence number
- typed resource ids such as:
  - `texture_key`
  - `image_id`
  - `placement_id`

### 6.2 Relationships

Needed relationships include:
- event -> segment
- event -> optional frame
- frame -> segment
- mapping -> frame
- mapping -> source op/resource ref(s)
- mapping -> output effect/resource ref(s)

### 6.3 Ordering contract

The minimum ordering contract is defined now, not deferred.

For the first full-function inspector:
- every persisted/live event record gets a **global monotonic per-segment sequence number** at record time
- this sequence is the authoritative ordering key for reconstruction and replay within a segment
- records may additionally carry:
  - source timestamp
  - thread/source identity
  - source-local sequence if useful

But those are secondary metadata. The authoritative cross-thread order used by the inspector is the per-segment monotonic sequence assigned when the event enters the inspector record stream.

This keeps frame/event/resource reconstruction deterministic even with producer/replay/render thread boundaries.
-
-### 6.3 Why this matters
+### 6.4 Why this matters

### 6.3 Why this matters

Stable ids are required for:
- replay and debugging correctness
- append-friendly persistence
- multi-run comparison later
- resource inspection and cross-layer references

---

## 7. Data needed for “full function”

### 7.1 Session/segment data

Needed:
- session identity
- producer identity
- terminal identity / capability snapshot / chosen output profile
- config snapshot
- capture enabled state
- active segment id
- segment start/end timestamps
- segment summary counters and dominant strategy/fallback summaries

### 7.2 Frame data

Needed:
- frame id / segment id / timestamps
- present duration and timing buckets
- queue depth / skipped presents / dropped stale work
- strategy selected
- fallback reasons
- operation counts
- bytes uploaded
- touched resources
- operation-level mappings
- frame-local events

### 7.3 Event classes

The first full-function inspector should treat the following as first-class events.

#### Capture/control
- capture start/stop
- segment start/end
- config snapshot/change

#### Frame/render decision
- present realized
- skipped present
- dropped stale work/batch
- strategy chosen
- fallback chosen

#### Resource lifecycle
- texture create/update/destroy
- kitty image upload/delete/evict
- placement create/update/delete

### 7.4 Resource data

Needed:
- resource kind
- stable id
- dimensions / format / blend / lifetime metadata
- latest-touch or touched-by-frame info
- blob refs for previews/raw payloads where available

### 7.5 Mapping data

Needed for first milestone:
- source operation kind/id
- destination effect kind/id
- resource refs involved
- explanation/reason
- whether direct, approximated, or fallback-driven

---

## 8. UI implications

### 8.1 Timeline

The timeline should evolve toward:
- horizontal scrolling
- zoom
- segment-aware navigation
- captured-section visualization
- later optional expanded real wall-time mode
- later optional rolling-window live mode

### 8.2 Future top-level tool views

The architecture should leave room for later views such as:
- sessions screen
- connected live producers
- historical sessions/runs
- “connect to socket” or later URL-based connections
- open persisted capture roots
- compare runs/terminals/configurations

These are roadmap items, not first-milestone blockers.

---

## 9. Scope and genericity boundary

### 9.1 First optimization target

The first full-function inspector is intentionally optimized for **Katzensteg**.

That means the design may include:
- SDL-specific operation records
- SDL-oriented mapping explanations
- Katzensteg-specific strategy/fallback language

### 9.2 Future generic direction

However, the design should avoid unnecessarily hardcoding SDL semantics into generic layers such as:
- kitty resource modeling
- timing buckets
- segment/frame/event structure
- persistence layout

This keeps a path open toward:
- Cleat
- direct termscene instrumentation
- generic kitty/TUI inspection
- later trace/export adaptation

### 9.3 Deferred generalization

True multi-producer normalization should be deferred until after a good Katzensteg end-to-end implementation proves the rough shape.

---

## 10. Recommended implementation stance

Use the following stance going forward:

- treat **standalone inspector service/store** as the intended destination
- keep **embedded producer-hosted server** as a supported fallback/dev mode
- build around a **segment / frame / event / resource / mapping** model
- make `/frame/<id>` authoritative for frame explanation
- keep resource previews as **fetchable blob refs**, not inline payloads
- use **directory-per-segment + JSONL streams + blob files** for persistence
- optimize first for **Katzensteg**, while preserving a path to future generic devtools work

## Follow-on docs

This design is accompanied by:
- a checklist doc in `docs/katzensteg/`
- a brainstorm-prompts doc in `docs/katzensteg/`

Those docs capture end-state requirements and future decision points respectively.
