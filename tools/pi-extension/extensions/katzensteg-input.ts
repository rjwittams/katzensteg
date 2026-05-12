// Pure encoder: pi-tui PointerEvent → structured `input` message payload for
// the Katzensteg embed-jsonl channel. Shape is DOM-inspired but reuses the
// existing snake_case wire convention (rect_cells, clip_cells, terminal_cells).
//
// The wire envelope is built by callers (KatzenstegProducer.sendInput). This
// module just produces the payload body so it can be unit-tested without
// touching producer / IO.

import type { PointerEvent } from "@earendil-works/pi-tui";

export type PointerKind = "pointerdown" | "pointermove" | "pointerup" | "wheel";
export type DeltaMode = "pixel" | "line" | "page";
export type PointerType = "mouse" | "pen" | "touch";

export interface ModifierState {
	shift: boolean;
	ctrl: boolean;
	alt: boolean;
	meta: boolean;
}

export interface PointerWirePayload {
	event: "pointer";
	kind: PointerKind;
	row: number; // 1-indexed terminal cell (matches rect_cells convention)
	col: number; // 1-indexed terminal cell
	pixel_x?: number; // optional; host omits if pixel coords aren't available
	pixel_y?: number;
	button: number; // 0=left, 1=middle, 2=right, 3=back, 4=forward; -1 for move/wheel
	buttons: number; // bitmask; bit N = button N currently held (consistent with button index)
	delta_x?: number; // wheel only
	delta_y?: number;
	delta_mode?: DeltaMode; // DOM: pixel|line|page (SGR wheel is one click = one "line")
	modifiers: ModifierState;
	pointer_type: PointerType;
}

// pi-tui's PointerEvent uses 0-indexed cell coords and overloads button=3 for
// "no specific button (move event)". Our wire format uses 1-indexed cells (to
// match the rest of the protocol) and -1 for "no button" (DOM convention).
//
// pi-tui's PointerEvent.buttons bitmask is consistent with button index
// (bit 0 = left, bit 1 = middle, bit 2 = right) so it passes through unchanged.
// (DOM swaps middle/right in `buttons` for historical reasons; we don't inherit
// that quirk because our `buttons` mirrors pi-tui's, which is already clean.)
export function pointerEventToWire(event: PointerEvent): PointerWirePayload {
	const kind: PointerKind = event.type;
	const button = kind === "pointermove" || kind === "wheel" ? -1 : event.button;
	const payload: PointerWirePayload = {
		event: "pointer",
		kind,
		row: event.row + 1,
		col: event.col + 1,
		button,
		buttons: event.buttons,
		modifiers: {
			shift: event.shiftKey,
			ctrl: event.ctrlKey,
			alt: event.altKey,
			meta: event.metaKey,
		},
		pointer_type: "mouse",
	};
	if (kind === "wheel") {
		// SGR wheel reports one click step per event; line-mode matches that
		// granularity. Hosts that derive deltas from pixel input should override.
		payload.delta_x = event.deltaX;
		payload.delta_y = event.deltaY;
		payload.delta_mode = "line";
	}
	return payload;
}

export interface InputMessageEnvelope {
	type: "input";
	window_id: string;
	event: string;
	[k: string]: unknown;
}

// Convenience: wrap a pointer payload in the full `input` envelope so callers
// can pass the result straight to JSON.stringify.
export function makePointerInputMessage(windowId: string, event: PointerEvent): InputMessageEnvelope {
	return {
		type: "input",
		window_id: windowId,
		...pointerEventToWire(event),
	};
}

// Raw keystroke pass-through. pi-tui delivers keystrokes as the original
// terminal bytes via Component.handleInput(data: string); for now we forward
// them unchanged under event:"terminal_bytes" (the WM-compatible variant).
// A structured key event modeled on the kitty keyboard protocol is a future
// expansion (the producer's TerminalInputParser already decodes raw bytes, so
// nothing breaks if a host only sends terminal_bytes).
export function makeTerminalBytesInputMessage(windowId: string, bytes: string): InputMessageEnvelope {
	return {
		type: "input",
		window_id: windowId,
		event: "terminal_bytes",
		bytes,
	};
}
