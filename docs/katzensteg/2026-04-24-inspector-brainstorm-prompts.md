# Katzensteg inspector brainstorm prompts

Date: 2026-04-24
Status: Future design prompts

This note captures questions that should be revisited when the implementation reaches a decision point and current reality matters more than today’s guess.

It is intentionally not a commitment document. It exists so later agents and future us can restart the design conversation with good prompts instead of rediscovering the same uncertainties.

## 1. Embedded server vs standalone inspector service

Use when:
- deciding whether to keep growing the current producer-hosted inspector
- evaluating a split into a standalone project/service such as a future Klouseau
- considering Rust/Axum/Tauri packaging

Prompts:
- What are the concrete pains of the current producer-hosted server model now?
- What workflows are blocked by not having a standalone inspector service/store?
- Is there still meaningful debugging value in letting the producer host the inspector directly?
- Should the standalone service become the default while keeping embedded mode as fallback?
- What is the minimum common protocol/data model that both modes must share?
- Does the producer push, does the service fetch, or do we need both directions for different use cases?
- If the producer connects to a service, how should capture enable/disable be signaled?
- Does a long-poll/subscription control channel make more sense than ad hoc polling?

## 2. Segment persistence format details

Use when:
- implementing persisted capture recording
- deciding exact JSONL layout and file boundaries
- deciding how much should be append-only vs derived

Prompts:
- Is `frames.jsonl` + `resources.jsonl` + `events.jsonl` enough, or do mappings deserve their own `mappings.jsonl`?
- Should resources be written as full snapshots, deltas, or periodic checkpoints plus deltas?
- What is the right directory-per-segment layout for crash tolerance and human inspectability?
- Do blob paths belong inside records as relative refs, ids, or both?
- When should derived summaries/indexes be generated: continuously, at finalize time, or lazily on read?
- What is the recovery story if a segment is interrupted mid-write?

## 3. Timeline / wall-time UX

Use when:
- implementing horizontal scrolling / zoom
- deciding how to visualize multiple capture periods
- deciding whether to show uncaptured gaps literally or abstractly

Prompts:
- What should the default view be when there are many frames: fixed-width scroll, zoomed fit-to-window, or a hybrid?
- How should segment boundaries appear visually?
- When should the UI show collapsed capture sections vs expanded wall time?
- What is the right trigger for “real wall time” mode?
- Should the default live view bias toward readability or literal time spacing?
- How should segment summaries appear in a zoomed-out view?

## 4. Resource preview/blob policy

Use when:
- implementing previews or serving blobs to the browser
- deciding whether transformation happens client-side or in the proxy/service

Prompts:
- What blob formats should be stored as authoritative payloads?
- Should the browser fetch raw blobs and adapt them client-side, or should the proxy/service normalize them to web-friendly formats?
- When do we want thumbnails vs original payloads?
- How aggressively should previews be cached or generated lazily?
- Are there resource types whose preview should be metadata-only even in a mature tool?

## 5. Frame explanation payload shape

Use when:
- enriching `/frame/<id>`
- deciding what should be embedded vs referenced

Prompts:
- Which mappings are genuinely needed to explain a frame vs just nice to have?
- Should `/frame/<id>` embed all frame-local events or only ids plus a compact summary?
- What are the smallest authoritative records that still let the UI explain “why composite?” and “what got uploaded/placed?” cleanly?
- Are any current synthesized UI fields masking a backend gap that should be fixed instead?

## 6. Event model and ordering

Use when:
- adding more event classes
- deciding whether the event model is strong enough for later trace export

Current minimum contract already decided:
- every event gets a global monotonic per-segment sequence number at record time
- that sequence is the authoritative reconstruction order
- source timestamp/thread/source-local order are optional secondary metadata

Prompts:
- Which event classes are truly first-class and which should remain derived summaries?
- What extra source-order metadata is worth storing beyond the authoritative per-segment sequence?
- Which events should be frame-bound, and which should remain segment-level?
- Are we accidentally overfitting event names to SDL/Katzensteg when a more generic pre-terminal shape would help later?

## 7. Comparing runs / terminals / configs

Use when:
- adding sessions screen and historical comparisons
- deciding what context belongs in session/run metadata

Prompts:
- What is the minimum metadata needed to compare two runs meaningfully?
- Do we compare by frame index, wall time, or semantic markers?
- How should terminal identity, output profile, and config snapshots be stored so comparisons are trustworthy?
- Which comparison views matter first: side-by-side frame detail, segment summaries, or performance charts?

## 8. Generalization beyond Katzensteg

Use when:
- considering Cleat integration
- considering a more general kitty/TUI devtools tool
- considering a future standalone project name and repo boundary

Prompts:
- Which parts of the current model are truly Katzensteg-specific vs generally “pre-terminal”?
- Can kitty-side image/resource/placement/timing models stand on their own without SDL mappings?
- What would a non-SDL producer need from the shared schema?
- Should SDL be modeled as one producer-specific metadata layer on top of a more general event/resource substrate?
- Is the right next step still Katzensteg-first, or has the shape become generic enough to split out?

## 9. Trace/export interoperability

Use when:
- considering Perfetto-like traces
- considering OpenTelemetry integration/export
- evaluating whether the internal model should bend toward external ecosystems

Prompts:
- What value are we hoping to get from Perfetto or OTel: storage, visualization, interoperability, or mental model?
- Which parts of the inspector model map cleanly to traces/spans/events, and which do not?
- Should export be a derived view, or should external trace compatibility influence the core runtime model?
- What would we lose by forcing ourselves into trace-shaped data too early?

## 10. Sessions/discovery UX

Use when:
- adding a sessions screen
- adding “connect to socket” or later remote endpoints

Prompts:
- What should the sessions screen show first: connected producers, historical runs, or both?
- How should the tool distinguish live sessions, persisted sessions, and disconnected-but-reopenable captures?
- Is manual “connect to socket” enough initially, or do we need discovery?
- How should later HTTP/TCP endpoints fit without distorting the local-first UDS workflow?

## Rule of thumb

When in doubt, re-ask:
- what is the smallest authoritative data we need to make the inspector explain reality cleanly?
- what belongs in the producer now vs the service/store later?
- are we solving a Katzensteg problem, or prematurely solving a future generic devtools problem?
