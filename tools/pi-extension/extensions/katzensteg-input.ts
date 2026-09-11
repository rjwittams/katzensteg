import type { TuiMouseEvent } from "@earendil-works/pi-tui";

export interface InputMessageEnvelope {
	type: "input";
	window_id: string;
	event: string;
	[key: string]: unknown;
}

/** Each surface owns button state; cancellation releases every held button. */
export class PointerInput {
	private buttons = 0;
	private last: TuiMouseEvent | undefined;

	encode(
		windowId: string,
		event: TuiMouseEvent,
	): InputMessageEnvelope | undefined {
		if (event.type === "click") return undefined;
		this.last = event;
		const button =
			event.button === "left"
				? 0
				: event.button === "middle"
					? 1
					: event.button === "right"
						? 2
						: -1;
		if (event.type === "press" && button >= 0) this.buttons |= 1 << button;
		if (event.type === "release" && button >= 0) this.buttons &= ~(1 << button);
		const kind =
			event.type === "press"
				? "pointerdown"
				: event.type === "release"
					? "pointerup"
					: event.type === "wheel"
						? "wheel"
						: "pointermove";
		return {
			type: "input",
			window_id: windowId,
			event: "pointer",
			kind,
			row: event.screenY + 1,
			col: event.screenX + 1,
			button: kind === "pointermove" || kind === "wheel" ? -1 : button,
			buttons: this.buttons,
			modifiers: {
				shift: event.shift,
				ctrl: event.ctrl,
				alt: event.alt,
				meta: false,
			},
			pointer_type: "mouse",
			...(kind === "wheel"
				? { delta_x: 0, delta_y: event.wheelSteps ?? 0, delta_mode: "line" }
				: {}),
		};
	}

	cancel(windowId: string): InputMessageEnvelope[] {
		const messages: InputMessageEnvelope[] = [];
		if (this.last) {
			for (const [index, button] of (
				["left", "middle", "right"] as const
			).entries()) {
				if (this.buttons & (1 << index)) {
					const message = this.encode(windowId, {
						...this.last,
						type: "release",
						button,
					});
					if (message) messages.push(message);
				}
			}
		}
		this.buttons = 0;
		return messages;
	}
}

export function makeTerminalBytesInputMessage(
	windowId: string,
	bytes: string,
): InputMessageEnvelope {
	// Pi has already resolved a standalone Escape. Encode it unambiguously so
	// the producer's stream parser does not wait for an escape-sequence suffix.
	return {
		type: "input",
		window_id: windowId,
		event: "terminal_bytes",
		bytes: bytes === "\x1b" ? "\x1b[27u" : bytes,
	};
}
