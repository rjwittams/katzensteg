import type {
	OverlayOptions,
	SurfaceRect,
	TuiMouseEvent,
	TuiMouseEventResult,
} from "@earendil-works/pi-tui";

type Edges = { left: boolean; right: boolean; top: boolean; bottom: boolean };
type Drag = { x: number; y: number; bounds: SurfaceRect; edges?: Edges };

/** Floating-panel chrome gestures. Body events are left to the producer. */
export class PanelWindowControls {
	private drag: Drag | undefined;
	private readonly bounds: () => SurfaceRect | undefined;
	private readonly update: (options: Partial<OverlayOptions>) => void;
	private readonly close: () => void;

	constructor(
		bounds: () => SurfaceRect | undefined,
		update: (options: Partial<OverlayOptions>) => void,
		close: () => void,
	) {
		this.bounds = bounds;
		this.update = update;
		this.close = close;
	}

	handle(event: TuiMouseEvent): TuiMouseEventResult | undefined {
		if (this.drag) {
			if (event.type === "release") {
				this.cancel();
				return { handled: true };
			}
			if (event.type !== "drag") return { handled: true, render: false };
			const { bounds, edges } = this.drag;
			const dx = event.screenX - this.drag.x;
			const dy = event.screenY - this.drag.y;
			let { x, y, width, height } = bounds;
			if (!edges) {
				x += dx;
				y += dy;
			} else {
				if (edges.left) {
					width = Math.max(42, bounds.width - dx);
					x += bounds.width - width;
				}
				if (edges.right) width = Math.max(42, bounds.width + dx);
				if (edges.top) {
					height = Math.max(10, bounds.height - dy);
					y += bounds.height - height;
				}
				if (edges.bottom) height = Math.max(10, bounds.height + dy);
			}
			// The host clamps positions and sizes. The next gesture starts from
			// its committed bounds, never from an unclamped requested position.
			this.update({ col: x, row: y, width, height });
			return { handled: true, render: true };
		}
		if (event.type !== "press" || event.button !== "left") return undefined;
		const bounds = this.bounds();
		if (!bounds) return undefined;
		if (event.y === 0 && event.x === bounds.width - 2) {
			this.close();
			return { handled: true };
		}
		const edges: Edges = {
			left: event.x === 0,
			right: event.x === bounds.width - 1,
			top: event.y === 0,
			bottom: event.y === bounds.height - 1,
		};
		const resize = Object.values(edges).some(Boolean);
		if (!resize && event.y !== 1) return undefined;
		this.drag = {
			x: event.screenX,
			y: event.screenY,
			bounds: { ...bounds },
			edges: resize ? edges : undefined,
		};
		return { capture: true, focus: true };
	}

	cancel(): void {
		this.drag = undefined;
	}
}
