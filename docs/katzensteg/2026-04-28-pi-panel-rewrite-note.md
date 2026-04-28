# Pi Panel Rewrite Note

Date: 2026-04-28
Status: implementation guidance

## Goal

The Pi extension panel must be written so its lifecycle is obvious and debuggable.

The previous prototype mixed overlay lifecycle, process lifecycle, protocol state, resize handling, and raw terminal writes in one tangled object. That made it possible for Pi to think the panel was closed while Katzensteg frames were still being pumped to the terminal.

## Required modes

The panel must support a layout-only mode that does not touch Katzensteg.

Use `KATZENSTEG_PANEL_MODE`:

- `layout`: no process, no protocol, no raw APC writes; show overlay rect and computed viewport only
- `live`: spawn Katzensteg and use the embed protocol

This lets us debug overlay sizing, geometry, resize, and close behavior independently from Katzensteg.

## Ownership rules

For the current integration:

- Pi owns the producer process.
- One logical panel owns at most one producer process.
- Closing the panel stops the producer.
- Profile changes restart the producer.
- Size changes must not restart the producer; they recreate/reconfigure the overlay and send a viewport update.
- A stale overlay generation must never write raw terminal bytes or drive protocol state.

Persistent detached producers are future work and require a stronger protocol cleanup/reconnect story.

## Object boundaries

### PanelController

Single source of truth for the logical panel.

Owns:

- desired open/closed state
- current profile
- current size preset
- current overlay generation
- current producer connection
- current viewport

Receives overlay rect changes and passes viewport changes to the producer.

### OverlayRun

Owns one Pi overlay instance.

Does only:

- render fixed-height panel chrome
- report rect changes to controller with its generation
- expose raw write / after-render methods for the current generation
- close itself

No process or protocol logic.

### ProducerConnection

Owns either a real Katzensteg process or a layout-only mock.

Does only:

- start/stop
- attach / viewport / detach / shutdown
- parse frame batches
- report frames/status back to controller

No overlay lifecycle logic.

## Sizing

Use explicit panel `height`, not `maxHeight`, for presets.

The component must render exactly `height` rows:

- top border
- title row
- status/debug row
- viewport body rows
- bottom border

The viewport rect is derived from the overlay rect and fixed panel chrome:

- viewport row starts after top border + title + status
- viewport col starts inside the left border
- viewport rows = panel height - fixed chrome rows
- viewport cols = panel width - left/right borders

Layout-only mode should display both the raw overlay rect and computed viewport rect.

## Logging

Debug logs go to `/tmp/katzensteg-pi-extension.log` and should include:

- commands received
- overlay generation open/close
- raw overlay rects
- computed viewport rects
- attach/viewport messages sent
- producer start/stop/exit

## Non-goals for this pass

- no persistent producer reattach
- no host-authored cleanup loops
- no protocol resource negotiation implementation here
- no attempt to optimize frame pacing until lifecycle correctness is established
