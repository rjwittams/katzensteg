# Embed Protocol Note: Renderer-Declared ID Needs and Deferred Clear Blocks

Date: 2026-04-28
Status: design note for follow-up protocol work

## Problem

The current embed protocol shape assumes the host can grant image/placement ID ranges up front in the initial `attach` message.

That is awkward for real hosts such as Pi because:

- the **host** does not know how many image / placement IDs a renderer will need
- the **renderer** does not know which ID ranges are safe until the host grants them
- the **host** should not have to synthesize cleanup commands for a renderer's IDs
- fixed giant ranges are wasteful and make host-side emergency cleanup impractical

The current fallback idea of having clients track all IDs, or emit broad brute-force delete loops, is not desirable.

This note was prompted by the Pi extension prototype, which exposed two additional lifecycle issues:

- the host can successfully send `detach`, but if it immediately marks the panel closed it may drop the renderer's delete-only cleanup batch
- the launcher process can be killed while the launched target process (for example RetroArch) survives, continuing to play audio and/or render

Those are not ID-allocation issues, but they are part of the same embed protocol/lifetime contract and should be addressed by the protocol/launcher follow-up.

## Desired properties

We want a protocol where:

1. the renderer declares its resource needs
2. the host grants concrete safe ranges
3. the renderer provides the host with an opaque cleanup payload
4. the host can replay that cleanup payload later if the normal detach/shutdown path fails

That keeps ownership clean:

- renderer knows what it created and how to clear it
- host stores and replays cleanup bytes, but does not need to understand per-ID renderer state

## Proposed direction

Use a small handshake anchored on `attach`.

### Recommended flow

1. **host -> renderer**: `attach`
   - window id
   - geometry / aspect
   - upload policy
   - no final image/placement ranges yet

2. **renderer -> host**: `requires`
   - declares how many image IDs it currently needs
   - declares how many placement IDs it currently needs
   - can be extended later if more resource classes appear

3. **host -> renderer**: `grant`
   - grants concrete safe ranges for the requested resources

4. **renderer -> host**: `defer_clear`
   - returns an opaque cleanup payload / clear-all block for everything created under the current grant
   - host stores this payload verbatim

5. normal `frame_batch` traffic proceeds

## Why this should happen on attach

This negotiation should happen as part of attachment to a host-managed window, not as a precomputed host-side allocation.

Reasons:

- `attach` is already the lifecycle moment where host and renderer agree that a concrete visible surface exists
- the renderer can declare actual current needs instead of forcing the host to guess
- geometry still naturally belongs to `attach`
- later `viewport` remains a geometry update, not a resource negotiation message

This is preferable to sending guessed ranges directly in the initial host message.

## Cleanup model

`detach` remains the normal polite cleanup path.

Expected `detach` semantics:

1. host sends `detach`
2. renderer synchronously/urgently emits a final cleanup `frame_batch` that removes currently known visible placements
3. renderer then suppresses future presentation for that window until a new attach/grant flow
4. host should continue draining frame batches until it receives the cleanup batch or a timeout/producer exit occurs

The host must not assume that simply writing `detach` has cleared the terminal. Cleanup is complete only after the host has replayed the renderer-authored cleanup bytes.

However, hosts also need an emergency fallback when:

- renderer exits unexpectedly
- host exits unexpectedly and later wants recovery behavior
- detach/shutdown does not complete cleanly
- the host must terminate the producer before a detach cleanup batch is observed

For that reason, the renderer-provided `defer_clear` payload should be treated as the host's saved fallback cleanup block.

The host should not need to manufacture its own delete commands.

## Shutdown and producer lifetime

The current prototype sends a `shutdown` message, but the current protocol parser only understands `attach`, `viewport`, and `detach`. A protocol follow-up should either implement `shutdown` explicitly or remove it from host examples so clients do not rely on a no-op.

Recommended `shutdown` semantics if implemented:

1. treat the window as detached, emitting/draining cleanup as above if needed
2. request orderly termination of the launched target app
3. drain pending render batches enough for cleanup to reach the host
4. exit the producer/launcher process

The launcher must own the launched target process tree in embed mode. If the host terminates the launcher, the target app must not survive as an orphan. The Pi prototype observed this failure mode with RetroArch continuing to play audio after the `katzensteg --embed-jsonl` launcher process was killed.

Implementation options to evaluate:

- process group/session ownership and process-group termination on launcher shutdown
- explicit signal handling in the launcher for SIGTERM/SIGINT
- target-child termination when stdin/control pipe closes
- target-child termination when render/control forwarding threads fail

The important contract is: in the current owned-panel model, the producer lifetime is owned by the host panel, and closing the panel must eventually stop the launched target.

## Host drain responsibilities

Hosts must distinguish between:

- logical panel closed to the user
- cleanup batch drained and replayed
- producer process fully terminated

The host may hide UI chrome immediately, but it should keep the producer connection alive long enough to receive and replay cleanup bytes from `detach` where possible. If the renderer exits or a timeout fires first, the host may replay its saved `defer_clear` fallback instead.

This is especially important because raw frame batches may arrive after the host has decided to close the panel. Those batches must not be blindly dropped if they are the cleanup response to `detach`.

## Cursor/terminal-state note

Normal Kitty placements use the current terminal cursor as an input register for placement origin. `C=1` prevents the terminal from moving the cursor after placement, but it does not avoid the absolute cursor move needed before placement.

Therefore, a host that replays opaque graphics chunks must assume raw writes can clobber cursor state and must restore its own cursor state after raw writes if it depends on it. The renderer should still emit correct minimal graphics bytes, but the host owns its TUI cursor/composer state.

## Later re-request / renegotiation

A future extension should allow the renderer to request more resources later.

Possible flow:

1. renderer -> host: another `requires`
2. host -> renderer: new `grant`
3. renderer -> host: replacement `defer_clear`

The host should then replace its saved cleanup payload with the newest one.

## Non-goals

This note does **not** specify:

- exact JSON field names
- whether `requires` and `grant` should be separate messages or folded into a tighter exchange
- whether the renderer can begin partial rendering before grant
- persistence / recovery semantics across host restarts
- exact process-group implementation details
- whether `shutdown` is mandatory or optional for all hosts

The main point is the ownership model:

- renderer declares needs
- host grants ranges
- renderer supplies cleanup payload
- host stores opaque cleanup payload for fallback use

## Implication for current Pi extension work

The current Pi extension should be treated as a prototype around the existing protocol, not as proof that fixed host-chosen ID ranges are the right long-term model.

The protocol follow-up should move cleanup and allocation responsibility to a negotiated handshake as described above.

Additionally, the current Pi prototype should not be considered correct until:

- `detach` cleanup batches are observable and replayed before the host stops accepting frames
- producer/launcher shutdown reliably terminates the launched target process tree
- the protocol either supports `shutdown` or examples stop sending it
