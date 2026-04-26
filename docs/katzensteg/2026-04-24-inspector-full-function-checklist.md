# Katzensteg inspector full-function checklist

Date: 2026-04-24
Status: Working checklist

Working checklist for getting the Katzensteg inspector to a genuinely full-function state, based on:
- `docs/superpowers/specs/2026-04-24-katzensteg-inspector-full-function-design.md`
- `docs/katzensteg/2026-04-23-inspector-ui-designer-handoff.md`

Scope for now:
- optimize for Katzensteg as the first producer
- keep the kitty-side resource and persistence model generic enough for future reuse
- treat a standalone inspector service/store as the likely destination
- keep embedded producer-hosted inspection as a useful fallback/dev mode

## Suggested implementation order

### 1. Core live model completeness
- [ ] Add first-class `segment` model
- [ ] Add active-segment state to capture status
- [ ] Add segment summaries:
  - [ ] frame count
  - [ ] event count
  - [ ] bytes uploaded
  - [ ] skipped/dropped counts
  - [ ] dominant strategies/fallbacks
- [ ] Add stable `segment_id`
- [ ] Add stable per-segment event sequencing
- [ ] Audit all current frame/resource ids for persistence-safe use

### 2. Core inspector endpoints
- [ ] enrich `/capture/status`
  - [ ] active segment
  - [ ] retention/window info
  - [ ] producer identity
  - [ ] control-state metadata
- [ ] define `/capture/start`
  - [ ] idempotent repeated-start behavior
  - [ ] active-segment creation on off -> on only
- [ ] define `/capture/stop`
  - [ ] idempotent repeated-stop behavior
  - [ ] segment close on on -> off only
- [ ] define `/capture/clear`
  - [ ] clear live capture semantics
  - [ ] explicit non-deletion of finalized historical segments
- [ ] add `/segments`
- [ ] add `/segment/<id>`
- [ ] add `/frames?segment=<id>`
- [ ] enrich `/frame/<id>` to be authoritative for frame explanation
- [ ] add `/resource/<kind>/<id>`
- [ ] add fetchable blob/asset endpoint
- [ ] viewer cutover can change the inspector API directly; no backward-compatibility shim is required

### 3. Frame explanation data
- [ ] ensure each frame records:
  - [ ] timestamps
  - [ ] timing buckets
  - [ ] queue depth
  - [ ] skipped presents
  - [ ] dropped stale work/batches
  - [ ] strategy selected
  - [ ] fallback reasons
  - [ ] counts for copies/fills/lines/uploads/placements
  - [ ] bytes uploaded
- [ ] add touched-resource refs per frame
- [ ] add frame-local event refs/payloads
- [ ] add operation-level mappings to `/frame/<id>`

### 4. Event coverage
- [ ] capture/control events
  - [ ] capture start
  - [ ] capture stop
  - [ ] segment start
  - [ ] segment end
  - [ ] config snapshot/change
- [ ] frame/render decision events
  - [ ] present realized
  - [ ] skipped present
  - [ ] dropped stale work/batch
  - [ ] strategy chosen
  - [ ] fallback chosen
- [ ] resource lifecycle events
  - [ ] texture create/update/destroy
  - [ ] kitty image upload/delete/evict
  - [ ] placement create/update/delete

### 5. Resource coverage
- [ ] ensure typed resource model includes at least:
  - [ ] SDL textures
  - [ ] kitty images
  - [ ] kitty placements
- [ ] record dimensions / format / blend metadata cleanly
- [ ] track latest-touch or touched-by-frame info
- [ ] make resource lookup stable across live and persisted modes
- [ ] define resource history representation explicitly
  - [ ] snapshot records, delta records, or checkpoint-plus-delta
  - [ ] effective frame/sequence boundary for each resource record
  - [ ] resource lookup as-of selected frame/sequence point
- [ ] keep kitty-side resource modeling generic enough for future non-SDL producers

### 6. Mapping coverage
- [ ] add operation-level mappings for:
  - [ ] `SDL_UpdateTexture` -> upload
  - [ ] `SDL_RenderCopy` / `SDL_RenderCopyEx` -> placement or composite contribution
  - [ ] unsupported blend mode -> fallback reason
  - [ ] null/fullscreen copy approximations -> explanation records
- [ ] make mapping records explicit about whether they are:
  - [ ] direct
  - [ ] approximated
  - [ ] fallback-driven
- [ ] keep region-level provenance explicitly deferred for now

### 7. Persistence model
- [ ] define segment directory layout
- [ ] append `frames.jsonl`
- [ ] append `resources.jsonl`
  - [ ] preserve resource history, not only latest state
  - [ ] support reconstruction as-of selected frame/sequence point
- [ ] append `events.jsonl`
- [ ] decide whether `mappings.jsonl` is needed or frame-embedded mappings are enough initially
- [ ] define blob naming/reference scheme
- [ ] store blob format/mime explicitly
- [ ] support crash-tolerant append/recovery behavior
- [ ] later derive optional summary/index files

### 8. Proxy/service recording
- [ ] let proxy/service mark segments as recorded/finalized
- [ ] serve persisted captures through the same viewer-facing API shape
- [ ] keep viewer semantics stable between live and persisted modes
- [ ] keep bounded live retention in producer separate from long-term retention in proxy/service

### 9. Timeline/navigation UX
- [ ] add horizontal scrolling
- [ ] add zoom in/out
- [ ] add segment-aware navigation
- [ ] add captured-section visualization
- [ ] later add expanded real wall-time mode
- [ ] later add rolling-window live mode option

### 10. Top-level tool UX later
- [ ] sessions screen
  - [ ] connected live producers
  - [ ] historical sessions/runs
- [ ] connect-to flow for alternate socket path
- [ ] later connect-to flow for HTTP/TCP endpoint if needed
- [ ] open persisted capture root
- [ ] groundwork for comparing runs / terminals / configs

### 11. Architecture modes
- [ ] keep embedded producer-hosted inspector workable as fallback/dev mode
- [ ] design toward standalone inspector service/store as the intended destination
- [ ] keep common data model and API shape across both modes
- [ ] avoid coupling viewer behavior to transport ownership

### 12. Deferred but important
- [ ] evaluate Perfetto-like trace export ideas once end-to-end shape exists
- [ ] evaluate OpenTelemetry-shaped export/interoperability later
- [ ] revisit general “pre-terminal event” modeling when broadening beyond Katzensteg
- [ ] revisit how this could become a more generic kitty/TUI devtools tool later
- [ ] revisit richer preview/blob serving policy later

## End-state success criteria

The inspector should feel “full function” when a developer can:
- browse captured segments cleanly
- inspect a frame and understand why it rendered the way it did
- inspect SDL-side and kitty-side resources separately
- see explicit SDL -> kitty operation mappings
- understand strategy/fallback/performance costs from authoritative data
- preserve captures to disk and reopen them through the same viewer model
