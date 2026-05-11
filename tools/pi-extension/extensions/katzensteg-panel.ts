import { appendFileSync, existsSync, mkdtempSync } from "node:fs";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionCommandContext, Theme } from "@earendil-works/pi-coding-agent";
import { type MessageHandle, type OverlayHandle, type SurfaceRect, truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import {
	FRAME_OVERHEAD_COLS,
	FRAME_OVERHEAD_ROWS,
	VIEWPORT_COL_OFFSET,
	VIEWPORT_ROW_OFFSET,
	clipCellsForBody,
	messageLogicalBodyRect,
	type RectCells,
	statusLineVisible,
} from "./katzensteg-geometry.js";

const WINDOW_ID = "main" as const;
// Each producer needs its own kitty image/placement id range — the terminal's
// kitty graphics state is shared, so two producers using the same id range
// would clobber each other's uploads.
//
// Counters do not recycle: each new producer takes the next IMAGE_RANGE_SIZE
// slot regardless of whether older producers are still alive. In a long-lived
// pi session this means the counter monotonically advances. The kitty image-id
// space is 32-bit (4_294_967_296 possible ids); with IMAGE_RANGE_SIZE=10000
// that's ~430k producers per pi process. Process restart resets the counters,
// so practical exhaustion is unrealistic — but if it ever matters, switch to
// a freelist of returned ranges.
const IMAGE_RANGE_BASE = 100000;
const PLACEMENT_RANGE_BASE = 200000;
const IMAGE_RANGE_SIZE = 10000;
const PLACEMENT_RANGE_SIZE = 10000;
let nextImageRangeBase = IMAGE_RANGE_BASE;
let nextPlacementRangeBase = PLACEMENT_RANGE_BASE;

function allocateIdRanges(): { imageIds: [number, number]; placementIds: [number, number] } {
	const imageStart = nextImageRangeBase;
	nextImageRangeBase += IMAGE_RANGE_SIZE;
	const placementStart = nextPlacementRangeBase;
	nextPlacementRangeBase += PLACEMENT_RANGE_SIZE;
	return {
		imageIds: [imageStart, imageStart + IMAGE_RANGE_SIZE - 1],
		placementIds: [placementStart, placementStart + PLACEMENT_RANGE_SIZE - 1],
	};
}
const DEFAULT_PROFILE = process.env.KATZENSTEG_PI_PROFILE || "sonic";
const DEFAULT_MODE = parseMode(process.env.KATZENSTEG_PANEL_MODE);
const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const DEFAULT_UPLOAD_HIGH_WATER = 10 * 1024 * 1024;
const DEBUG_LOG_PATH = "/tmp/katzensteg-pi-extension.log";

const PANEL_MARGIN = 1;
const PANEL_ASPECT: Aspect = "fit";
// Katzensteg's full-frame composite uses z=100. For inline panels we neutralize
// that (effective z=0) so host text chrome stays readable. The floating panel
// should sit on top of any inline panels, so it keeps katzensteg's native z.
const INLINE_Z_BASE = parseIntegerEnv(process.env.KATZENSTEG_PANEL_Z_BASE, -100);
const FLOATING_Z_BASE = parseIntegerEnv(process.env.KATZENSTEG_PANEL_FLOATING_Z_BASE, 0);
const PANEL_WINDOW_POLICY = nonEmptyEnv(process.env.KATZENSTEG_PANEL_WINDOW_POLICY);
const PANEL_REAL_WINDOW = nonEmptyEnv(process.env.KATZENSTEG_PANEL_REAL_WINDOW);
// The launcher gives an embed producer 1500ms after shutdown before SIGTERM.
// Keep the panel alive longer than that so producer-authored delete batches can
// drain instead of leaving stale kitty placements behind.
const CLOSE_DRAIN_MS = 2500;
const CLOSE_AFTER_CLEANUP_MS = 150;

type Aspect = "fit" | "stretch" | "cover";
type UploadProfile = "direct_apc" | "file_whole" | "file_offset_ring";
type PanelMode = "layout" | "live";
type SizePresetName = "small" | "medium" | "large";
type PanelCommand =
	| { kind: "toggle" }
	| { kind: "open"; profile?: string }
	| { kind: "close" }
	| { kind: "size"; size: SizePresetName }
	| { kind: "profile"; profile: string }
	| { kind: "inline"; profile?: string };

interface PanelDetails {
	mode: PanelMode;
	profile: string;
	size: SizePresetName;
}

type OverlayRect = SurfaceRect;

interface TerminalCells {
	rows: number;
	cols: number;
}

interface ViewportSync {
	rect: RectCells;
	clip: RectCells | undefined;
	terminal: TerminalCells;
}

interface SizePreset {
	name: SizePresetName;
	width: number | `${number}%`;
	height: number | `${number}%`;
}

interface FrameBatch {
	type: "frame_batch";
	window_id: string;
	seq: number;
	groups: {
		deletes: string[];
		uploads: string[];
		placements: string[];
		after: string[];
	};
}

interface DetachedMessage {
	type: "detached";
	window_id: string;
}

interface AttachOptions {
	windowId: typeof WINDOW_ID;
	rectCells: RectCells;
	clipCells?: RectCells;
	terminalCells?: TerminalCells;
	aspect: Aspect;
	zBase: number;
	imageIds: [number, number];
	placementIds: [number, number];
	upload: { profile: UploadProfile; path?: string; highWater: number };
}

interface ViewportOptions {
	windowId: typeof WINDOW_ID;
	rectCells: RectCells;
	clipCells?: RectCells;
	terminalCells?: TerminalCells;
	aspect: Aspect;
	zBase: number;
}

const SIZE_PRESETS: Record<SizePresetName, SizePreset> = {
	small: { name: "small", width: 44, height: 12 },
	medium: { name: "medium", width: 56, height: 20 },
	large: { name: "large", width: "50%", height: "85%" },
};

interface ActivePanel {
	close(reason: string): void;
}

let activeController: ActivePanel | undefined;
const inlinePanels = new Set<InlinePanelController>();
let preferredProfile = DEFAULT_PROFILE;
let preferredSize: SizePresetName = "medium";
let globalChunkSeq = 0;

export default function (pi: ExtensionAPI) {
	pi.on("session_shutdown", () => {
		debugLog("session_shutdown");
		activeController?.close("session_shutdown");
		activeController = undefined;
		for (const panel of inlinePanels) panel.close("session_shutdown");
		inlinePanels.clear();
	});

	// Event loop lag heartbeat: schedule setImmediate every 100ms, measure how long
	// it actually takes to fire. Spikes mean the event loop was busy with something.
	let heartbeatPrev = process.hrtime.bigint();
	const heartbeat = (): void => {
		const now = process.hrtime.bigint();
		const elapsedMs = Number((now - heartbeatPrev) / 1_000_000n);
		heartbeatPrev = now;
		if (elapsedMs > 150) debugLog(`pi.event_loop_lag_ms=${elapsedMs}`);
		setTimeout(() => setImmediate(heartbeat), 100);
	};
	setImmediate(heartbeat);

	pi.registerMessageRenderer<PanelDetails>("katzensteg-panel", (message, options, theme) => {
		const details = message.details;
		const tui = options.tui;
		const handle = options.handle;
		if (!details || !tui || !handle) return undefined;
		const controller = new InlinePanelController(tui, theme, handle, details);
		inlinePanels.add(controller);
		return controller;
	});

	pi.registerCommand("katzensteg-panel", {
		description: "Show or control a Katzensteg embed panel",
		handler: async (args, ctx) => {
			const command = parseCommand(args);
			debugLog(`command ${JSON.stringify(command)}`);
			switch (command.kind) {
				case "toggle":
					if (activeController) {
						activeController.close("toggle");
						activeController = undefined;
						ctx.ui.notify("Closed Katzensteg panel", "info");
					} else {
						openPanel(ctx, preferredProfile, preferredSize);
					}
					break;
				case "open":
					openPanel(ctx, command.profile ?? preferredProfile, preferredSize);
					break;
				case "inline":
					sendInlinePanel(pi, command.profile ?? preferredProfile, preferredSize);
					break;
				case "close":
					if (!activeController) {
						ctx.ui.notify("Katzensteg panel is not open", "warning");
						break;
					}
					activeController.close("command-close");
					activeController = undefined;
					ctx.ui.notify("Closed Katzensteg panel", "info");
					break;
				case "size":
					preferredSize = command.size;
					if (activeController instanceof PanelController) activeController.setSize(SIZE_PRESETS[command.size]);
					else ctx.ui.notify(`Set Katzensteg panel size to ${command.size}`, "info");
					break;
				case "profile":
					preferredProfile = command.profile;
					if (activeController instanceof PanelController) activeController.setProfile(command.profile);
					else openPanel(ctx, command.profile, preferredSize);
					break;
			}
		},
	});
}

function sendInlinePanel(pi: ExtensionAPI, profile: string, sizeName: SizePresetName): void {
	preferredProfile = profile;
	preferredSize = sizeName;
	pi.sendMessage<PanelDetails>({
		customType: "katzensteg-panel",
		content: `Katzensteg panel · ${profile} · ${sizeName}`,
		display: true,
		details: { mode: DEFAULT_MODE, profile, size: sizeName },
	});
}

function openPanel(ctx: ExtensionCommandContext, profile: string, sizeName: SizePresetName): void {
	preferredProfile = profile;
	preferredSize = sizeName;
	activeController?.close("replace-open");
	const controller = new PanelController(ctx, DEFAULT_MODE, profile, SIZE_PRESETS[sizeName]);
	activeController = controller;
	void controller.open().catch((error: unknown) => {
		if (activeController === controller) activeController = undefined;
		ctx.ui.notify(`Katzensteg panel failed: ${error instanceof Error ? error.message : String(error)}`, "error");
	});
}

class PanelController {
	private overlay: OverlayRun | undefined;
	private producer: ProducerConnection;
	private currentGeneration = 0;
	private closing = false;
	private closed = false;
	private cleanupSeen = false;
	private closeTimer: NodeJS.Timeout | undefined;
	private latestOverlayRect: OverlayRect | undefined;
	private latestViewport: RectCells | undefined;
	private latestSync: ViewportSync | undefined;
	private status = "starting";
	private error: string | undefined;

	constructor(
		private readonly ctx: ExtensionCommandContext,
		private readonly mode: PanelMode,
		private profile: string,
		private size: SizePreset,
	) {
		this.producer = this.createProducer(profile);
	}

	async open(): Promise<void> {
		debugLog(`controller.open mode=${this.mode} profile=${this.profile} size=${this.size.name}`);
		this.closing = false;
		this.closed = false;
		this.cleanupSeen = false;
		this.producer.start();
		await this.openOverlay();
	}

	close(reason: string): void {
		if (this.closed || this.closing) return;
		debugLog(`controller.close reason=${reason}`);
		this.closing = true;
		this.cleanupSeen = false;
		this.status = "closing";
		this.overlay?.invalidate();
		this.producer.stop(reason);
		this.scheduleCloseFinish(reason, CLOSE_DRAIN_MS);
	}

	setSize(size: SizePreset): void {
		if (this.closed || this.closing || this.size.name === size.name) return;
		debugLog(`controller.setSize ${this.size.name} -> ${size.name}`);
		this.size = size;
		void this.replaceOverlay();
	}

	setProfile(profile: string): void {
		if (this.closed || this.closing || this.profile === profile) return;
		debugLog(`controller.setProfile ${this.profile} -> ${profile}`);
		this.profile = profile;
		this.producer.stop("profile-change");
		this.producer = this.createProducer(profile);
		this.producer.start();
		this.overlay?.invalidate();
		if (this.latestSync) this.scheduleViewportSync(this.currentGeneration, this.latestSync);
	}

	render(width: number, theme: Theme): string[] {
		return renderPanelChrome(width, theme, {
			mode: this.mode,
			profile: this.profile,
			sizeName: this.size.name,
			rect: this.latestOverlayRect,
			viewport: this.latestViewport,
			status: this.status,
			error: this.error,
			panelRows: this.latestOverlayRect?.totalRows ?? fallbackPanelRowsForSize(this.size),
			zBase: FLOATING_Z_BASE,
		});
	}

	onOverlayRect(generation: number, rect: OverlayRect | undefined): void {
		if (this.closed || this.closing || generation !== this.currentGeneration || !rect) return;
		const body = messageLogicalBodyRect(rect);
		if (!body) return;
		const clip = clipCellsForBody(body, rect);
		debugLog(`overlay.rect gen=${generation} raw=${formatRect(rect)} body=${formatRect(body)} clip=${formatRect(clip)}`);
		this.latestOverlayRect = rect;
		this.latestViewport = body;
		this.overlay?.invalidate();
		const sync: ViewportSync = {
			rect: body,
			clip,
			// terminal_cells.rows here is an approximation (overlay bottom edge,
			// not the actual terminal height) — PanelController doesn't carry a
			// TUI reference. This is benign in practice: the producer only uses
			// terminal_cells.rows to derive a pixel-per-cell hint via
			// scaledPixelExtent, and only when terminal_px is also supplied. We
			// don't send terminal_px, so the field is decorative for floating
			// overlays. If we ever start sending terminal_px (or scaling becomes
			// terminal-relative for other reasons), wire the real height through.
			terminal: { rows: rect.row + rect.rows, cols: rect.cols },
		};
		this.latestSync = sync;
		this.scheduleViewportSync(generation, sync);
	}

	private scheduleViewportSync(generation: number, sync: ViewportSync): void {
		this.overlay?.afterNextRender(() => {
			if (this.closed || this.closing || generation !== this.currentGeneration) {
				debugLog(`viewport.sync stale gen=${generation} current=${this.currentGeneration}`);
				return;
			}
			debugLog(`viewport.sync gen=${generation} viewport=${formatRect(sync.rect)} clip=${formatRect(sync.clip)}`);
			this.producer.setViewport(sync);
		});
	}

	private async openOverlay(): Promise<void> {
		const generation = ++this.currentGeneration;
		const overlay = new OverlayRun(this.ctx, this, generation);
		this.overlay = overlay;
		debugLog(`overlay.open gen=${generation} size=${this.size.name} width=${String(this.size.width)} height=${String(this.size.height)}`);
		await overlay.run();
		debugLog(`overlay.done gen=${generation} current=${this.currentGeneration} closed=${this.closed}`);
		if (this.overlay === overlay) this.overlay = undefined;
		if (!this.closed && !this.closing && generation === this.currentGeneration) this.close("overlay-ended");
	}

	private async replaceOverlay(): Promise<void> {
		if (this.closed) return;
		const previous = this.overlay;
		debugLog(`overlay.replace fromGen=${this.currentGeneration}`);
		this.currentGeneration++;
		if (previous) await previous.closeAndWait();
		if (!this.closed) void this.openOverlay();
	}

	private createProducer(profile: string): ProducerConnection {
		return createProducer(this.mode, profile, {
			onFrame: (batch) => this.onFrame(batch),
			onDetached: (message) => this.onDetached(message),
			onStatus: (status) => this.setStatus(status),
			onError: (error) => this.setError(error),
		}, FLOATING_Z_BASE);
	}

	private onFrame(batch: FrameBatch): void {
		if (this.closed) return;
		if (this.closing) {
			this.status = `closing #${batch.seq}`;
			const bytes = cleanupTerminalChunks(batch).join("");
			if (bytes.length > 0) {
				this.cleanupSeen = true;
				const cleanupOnly = isCleanupOnlyBatch(batch);
				debugLog(`controller.cleanup batch seq=${batch.seq} bytes=${bytes.length} cleanupOnly=${cleanupOnly}`);
				this.overlay?.writeRaw(bytes);
				if (cleanupOnly) this.scheduleCloseFinish("cleanup-drained", CLOSE_AFTER_CLEANUP_MS);
			}
			this.overlay?.invalidate();
			return;
		}
		this.status = `streaming #${batch.seq}`;
		const bytes = orderedTerminalChunks(batch).join("");
		if (bytes.length > 0) this.overlay?.writeRaw(bytes);
		this.overlay?.invalidate();
	}

	private onDetached(message: DetachedMessage): void {
		debugLog(`controller.detached window=${message.window_id} closing=${this.closing}`);
		if (this.closed) return;
		if (this.closing) this.scheduleCloseFinish("detached", 0);
		else this.status = "detached";
	}

	private scheduleCloseFinish(reason: string, delayMs: number): void {
		if (this.closeTimer) clearTimeout(this.closeTimer);
		this.closeTimer = setTimeout(() => this.finishClose(reason), delayMs);
	}

	private finishClose(reason: string): void {
		if (this.closed) return;
		debugLog(`controller.finishClose reason=${reason} cleanupSeen=${this.cleanupSeen}`);
		this.closed = true;
		this.closing = false;
		if (this.closeTimer) {
			clearTimeout(this.closeTimer);
			this.closeTimer = undefined;
		}
		this.currentGeneration++;
		const overlay = this.overlay;
		this.overlay = undefined;
		overlay?.close();
	}

	private setStatus(status: string): void {
		this.status = status;
		this.error = undefined;
		this.overlay?.invalidate();
	}

	private setError(error: string): void {
		this.error = error;
		this.overlay?.invalidate();
	}

	getSize(): SizePreset {
		return this.size;
	}
}

class OverlayRun {
	private handle: OverlayHandle | undefined;
	private unsubscribe: (() => void) | undefined;
	private done: (() => void) | undefined;
	private component: PanelComponent | undefined;
	private finishedResolve!: () => void;
	readonly finished = new Promise<void>((resolve) => {
		this.finishedResolve = resolve;
	});

	constructor(
		private readonly ctx: ExtensionCommandContext,
		private readonly controller: PanelController,
		private readonly generation: number,
	) {}

	async run(): Promise<void> {
		try {
			await this.ctx.ui.custom<void>(
				(tui, theme, _keybindings, done) => {
					this.done = done;
					this.component = new PanelComponent(tui, theme, this.controller);
					return this.component;
				},
				{
					overlay: true,
					overlayOptions: {
						anchor: "top-right",
						nonCapturing: true,
						width: this.controller.getSize().width,
						height: this.controller.getSize().height,
						margin: PANEL_MARGIN,
					},
					onHandle: (handle) => {
						this.handle = handle;
						debugLog(`overlay.handle gen=${this.generation}`);
						this.unsubscribe = handle.onRectChange((rect) => this.controller.onOverlayRect(this.generation, rect));
					},
				},
			);
		} finally {
			debugLog(`overlay.finally gen=${this.generation}`);
			this.unsubscribe?.();
			this.unsubscribe = undefined;
			this.finishedResolve();
		}
	}

	close(): void {
		debugLog(`overlay.close gen=${this.generation}`);
		this.done?.();
	}

	async closeAndWait(): Promise<void> {
		this.close();
		await this.finished;
	}

	invalidate(): void {
		this.component?.invalidate();
	}

	afterNextRender(callback: () => void): void {
		this.component?.afterNextRender(callback);
	}

	writeRaw(data: string): void {
		this.component?.writeRaw(data);
	}
}

class PanelComponent {
	readonly width: number;

	constructor(
		private readonly tui: { writeRaw(data: string): void; afterNextRender(callback: () => void): void; requestRender(): void },
		private readonly theme: Theme,
		private readonly controller: PanelController,
	) {
		const size = controller.getSize();
		this.width = typeof size.width === "number" ? size.width : 56;
	}

	render(width: number): string[] {
		return this.controller.render(width, this.theme);
	}

	invalidate(): void {
		this.tui.requestRender();
	}

	afterNextRender(callback: () => void): void {
		this.tui.afterNextRender(callback);
	}

	writeRaw(data: string): void {
		this.tui.writeRaw(data);
	}
}

interface PanelChromeArgs {
	mode: PanelMode;
	profile: string;
	sizeName: SizePresetName;
	rect: OverlayRect | undefined;
	viewport: RectCells | undefined;
	status: string;
	error: string | undefined;
	panelRows: number;
	zBase: number;
}

function renderPanelChrome(width: number, theme: Theme, args: PanelChromeArgs): string[] {
	const innerWidth = Math.max(1, width - 2);
	const row = (content: string) => theme.fg("border", "│") + fitCellText(content, innerWidth) + theme.fg("border", "│");
	const lines: string[] = [];
	const title = ` 🐈 Katzensteg · ${args.mode} · ${args.profile} · ${args.sizeName}`;
	const status = args.error ? theme.fg("error", ` ${args.error}`) : theme.fg("dim", ` ${args.status}`);
	const rectLine = args.rect
		? ` rect ${formatRect(args.rect)} viewport ${formatRect(args.viewport)} z=${args.zBase}`
		: " waiting for rect";
	const bodyRows = Math.max(2, args.panelRows - FRAME_OVERHEAD_ROWS);
	lines.push(theme.fg("border", `╭${"─".repeat(innerWidth)}╮`));
	lines.push(row(theme.fg("accent", title)));
	lines.push(row(args.mode === "layout" ? theme.fg("dim", rectLine) : status));
	for (let i = 0; i < bodyRows; i++) lines.push(row(""));
	lines.push(theme.fg("border", `╰${"─".repeat(innerWidth)}╯`));
	return lines;
}

function createProducer(mode: PanelMode, profile: string, callbacks: ProducerCallbacks, zBase: number): ProducerConnection {
	return mode === "live" ? new KatzenstegProducer(profile, callbacks, zBase) : new LayoutOnlyProducer(callbacks);
}

interface InlinePanelTui {
	writeRaw(data: string): void;
	afterNextRender(callback: () => void): void;
	requestRender(): void;
	// Pi's TUI exposes terminal dimensions on its public `terminal` property.
	// We need the row count to compute clip_cells correctly when an inline
	// message is partially or fully scrolled out of the viewport; rect.cols
	// already mirrors terminal.columns.
	terminal: { rows: number; columns: number };
}

class InlinePanelController implements ActivePanel {
	private readonly producer: ProducerConnection;
	private unsubscribe: (() => void) | undefined;
	private started = false;
	private startScheduled = false;
	private closing = false;
	private closed = false;
	private cleanupSeen = false;
	private latestRect: OverlayRect | undefined;
	private latestViewport: RectCells | undefined;
	private latestSync: ViewportSync | undefined;
	private status = "starting";
	private error: string | undefined;
	private closeTimer: NodeJS.Timeout | undefined;

	constructor(
		private readonly tui: InlinePanelTui,
		private readonly theme: Theme,
		private readonly handle: MessageHandle,
		private readonly details: PanelDetails,
	) {
		this.producer = createProducer(details.mode, details.profile, {
			onFrame: (batch) => this.onFrame(batch),
			onDetached: (message) => this.onDetached(message),
			onStatus: (status) => this.setStatus(status),
			onError: (error) => this.setError(error),
		}, INLINE_Z_BASE);
	}

	render(width: number): string[] {
		if (!this.started && !this.startScheduled && !this.closed) {
			this.startScheduled = true;
			this.tui.afterNextRender(() => this.start());
		}
		// The inline component's line count must be stable across rect changes:
		// pi-tui handles scroll clipping itself, and rendering fewer lines when
		// the message partly scrolls off the top would shrink the buffered
		// surface (and the producer's body rect with it). Use the configured
		// preset height, never the visible rect height.
		const panelRows = fallbackPanelRowsForSize(SIZE_PRESETS[this.details.size]);
		return renderPanelChrome(width, this.theme, {
			mode: this.details.mode,
			profile: this.details.profile,
			sizeName: this.details.size,
			rect: this.latestRect,
			viewport: this.latestViewport,
			status: this.status,
			error: this.error,
			panelRows,
			zBase: INLINE_Z_BASE,
		});
	}

	invalidate(): void {}

	close(reason: string): void {
		if (this.closed || this.closing) return;
		debugLog(`inline.close reason=${reason}`);
		this.closing = true;
		this.cleanupSeen = false;
		this.status = "closing";
		this.unsubscribe?.();
		this.unsubscribe = undefined;
		this.producer.stop(reason);
		this.scheduleCloseFinish(reason, CLOSE_DRAIN_MS);
		this.tui.requestRender();
	}

	private start(): void {
		// Guard against `closing` too: close() may run synchronously before the
		// afterNextRender callback that calls start(); without this we'd kick
		// off the producer during the close-drain phase.
		if (this.started || this.closed || this.closing) return;
		this.started = true;
		this.startScheduled = false;
		debugLog(`inline.start mode=${this.details.mode} profile=${this.details.profile}`);
		this.producer.start();
		this.unsubscribe = this.handle.onRectChange((rect) => this.onRectChange(rect));
	}

	private onRectChange(rect: OverlayRect | undefined): void {
		if (this.closed || this.closing) return;
		if (!rect) {
			// Surface scrolled fully off-screen. If we already attached, send a
			// zero-clip at the last known logical body so the producer stops
			// emitting placements; otherwise just clear our render state.
			this.latestRect = undefined;
			this.latestViewport = undefined;
			if (this.latestSync) {
				// row/col on a zero-sized clip are irrelevant — the producer
				// emits no placements either way — but we anchor at the body's
				// own origin to match the convention used elsewhere (the WM's
				// computeClipForRect does the same).
				const zeroSync: ViewportSync = {
					rect: this.latestSync.rect,
					clip: { row: this.latestSync.rect.row, col: this.latestSync.rect.col, rows: 0, cols: 0 },
					terminal: this.latestSync.terminal,
				};
				this.latestSync = zeroSync;
				this.tui.afterNextRender(() => {
					if (this.closed || this.closing) return;
					this.producer.setViewport(zeroSync);
				});
			}
			this.tui.requestRender();
			return;
		}
		const body = messageLogicalBodyRect(rect);
		if (!body) return;
		const clip = clipCellsForBody(body, rect);
		const terminal: TerminalCells = { rows: this.tui.terminal.rows, cols: this.tui.terminal.columns };
		const sync: ViewportSync = { rect: body, clip, terminal };
		this.latestRect = rect;
		this.latestViewport = body;
		this.latestSync = sync;
		debugLog(`inline.rect ${formatRect(rect)} body=${formatRect(body)} clip=${formatRect(clip)}`);
		this.tui.afterNextRender(() => {
			if (this.closed || this.closing) return;
			this.producer.setViewport(sync);
		});
		this.tui.requestRender();
	}

	private onFrame(batch: FrameBatch): void {
		if (this.closed) return;
		if (this.closing) {
			this.status = `closing #${batch.seq}`;
			const bytes = cleanupTerminalChunks(batch).join("");
			if (bytes.length > 0) {
				this.cleanupSeen = true;
				this.tui.writeRaw(bytes);
				if (isCleanupOnlyBatch(batch)) this.scheduleCloseFinish("cleanup-drained", CLOSE_AFTER_CLEANUP_MS);
			}
			this.tui.requestRender();
			return;
		}
		const bytes = orderedTerminalChunks(batch).join("");
		debugLog(
			`inline.frame seq=${batch.seq} d=${batch.groups.deletes.length} u=${batch.groups.uploads.length} p=${batch.groups.placements.length} a=${batch.groups.after.length} bytes=${bytes.length} clip=${formatRect(this.latestSync?.clip)}`,
		);
		// Always flush producer bytes — they go via writeRaw and bypass pi-tui's
		// buffer, so they never trigger redraws.
		if (bytes.length > 0) this.tui.writeRaw(bytes);
		// Only mutate the status line (chrome row 2) and request a re-render
		// when the status line is actually inside the viewport. If it's scrolled
		// above the top, changing it causes pi-tui's diff to land at
		// firstChanged < viewportTop, which forces a clearing full redraw — and
		// the screen clear takes every kitty placement on screen with it,
		// causing all producers' images to flicker.
		if (this.statusLineVisible()) {
			this.status = `streaming #${batch.seq}`;
			this.tui.requestRender();
		}
	}

	private statusLineVisible(): boolean {
		return statusLineVisible(this.latestRect);
	}

	private onDetached(message: DetachedMessage): void {
		debugLog(`inline.detached window=${message.window_id} closing=${this.closing}`);
		if (this.closed) return;
		if (this.closing) this.scheduleCloseFinish("detached", 0);
		else this.status = "detached";
		this.tui.requestRender();
	}

	private scheduleCloseFinish(reason: string, delayMs: number): void {
		if (this.closeTimer) clearTimeout(this.closeTimer);
		this.closeTimer = setTimeout(() => this.finishClose(reason), delayMs);
	}

	private finishClose(reason: string): void {
		if (this.closed) return;
		debugLog(`inline.finishClose reason=${reason} cleanupSeen=${this.cleanupSeen}`);
		this.closed = true;
		this.closing = false;
		if (this.closeTimer) {
			clearTimeout(this.closeTimer);
			this.closeTimer = undefined;
		}
		inlinePanels.delete(this);
	}

	private setStatus(status: string): void {
		this.status = status;
		this.error = undefined;
		this.tui.requestRender();
	}

	private setError(error: string): void {
		this.error = error;
		this.tui.requestRender();
	}
}

interface ProducerCallbacks {
	onFrame?: (batch: FrameBatch) => void;
	onDetached?: (message: DetachedMessage) => void;
	onStatus: (status: string) => void;
	onError?: (error: string) => void;
}

interface ProducerConnection {
	start(): void;
	setViewport(sync: ViewportSync): void;
	stop(reason: string): void;
}

class LayoutOnlyProducer implements ProducerConnection {
	private latestSync: ViewportSync | undefined;

	constructor(private readonly callbacks: ProducerCallbacks) {}

	start(): void {
		debugLog("producer.layout.start");
		this.callbacks.onStatus("layout-only");
	}

	setViewport(sync: ViewportSync): void {
		if (sameSync(this.latestSync, sync)) return;
		this.latestSync = sync;
		debugLog(`producer.layout.viewport ${formatRect(sync.rect)} clip=${formatRect(sync.clip)}`);
		this.callbacks.onStatus(`layout viewport ${formatRect(sync.rect)}`);
	}

	stop(reason: string): void {
		debugLog(`producer.layout.stop reason=${reason}`);
	}
}

class KatzenstegProducer implements ProducerConnection {
	private child: ChildProcessWithoutNullStreams | undefined;
	private carry = "";
	private attached = false;
	private latestSyncSent: ViewportSync | undefined;
	private killTimer: NodeJS.Timeout | undefined;
	private readonly uploadDir = mkdtempSync(path.join(os.tmpdir(), "katzensteg-pi-"));
	private readonly uploadPath = path.join(this.uploadDir, "embed-upload.rgba");
	private readonly imageIds: [number, number];
	private readonly placementIds: [number, number];

	constructor(
		private readonly profile: string,
		private readonly callbacks: ProducerCallbacks,
		private readonly zBase: number,
	) {
		const ranges = allocateIdRanges();
		this.imageIds = ranges.imageIds;
		this.placementIds = ranges.placementIds;
	}

	start(): void {
		if (this.child) return;
		const bin = this.binaryPath();
		debugLog(`producer.live.start bin=${bin} profile=${this.profile}`);
		this.callbacks.onStatus("launching");
		this.child = spawn(bin, ["--embed-jsonl", this.profile], {
			cwd: REPO_ROOT,
			stdio: ["pipe", "pipe", "pipe"],
			env: producerEnv(),
		});
		this.child.stdout.setEncoding("utf8");
		this.child.stderr.setEncoding("utf8");
		this.child.stdout.on("data", (chunk: string) => this.onStdout(chunk));
		this.child.stderr.on("data", (chunk: string) => this.onStderr(chunk));
		this.child.on("error", (error) => {
			debugLog(`producer.live.error ${error.message}`);
			this.callbacks.onError?.(error.message);
		});
		this.child.on("close", (code, signal) => {
			debugLog(`producer.live.close code=${code ?? "null"} signal=${signal ?? "null"}`);
			if (this.killTimer) clearTimeout(this.killTimer);
			this.child = undefined;
			this.attached = false;
			this.latestSyncSent = undefined;
			this.callbacks.onStatus(signal ? `exited ${signal}` : `exited ${code ?? 0}`);
		});
	}

	setViewport(sync: ViewportSync): void {
		if (!this.child?.stdin) {
			debugLog(`producer.live.viewport skipped no child viewport=${formatRect(sync.rect)}`);
			return;
		}
		if (!this.attached) {
			debugLog(`producer.live.attach ${formatRect(sync.rect)} clip=${formatRect(sync.clip)}`);
			this.writeControl(makeAttachMessage({
				windowId: WINDOW_ID,
				rectCells: sync.rect,
				clipCells: sync.clip,
				terminalCells: sync.terminal,
				aspect: PANEL_ASPECT,
				zBase: this.zBase,
				imageIds: this.imageIds,
				placementIds: this.placementIds,
				upload: { profile: "file_whole", path: this.uploadPath, highWater: DEFAULT_UPLOAD_HIGH_WATER },
			}));
			this.attached = true;
			this.latestSyncSent = sync;
			this.callbacks.onStatus("attached");
			return;
		}
		if (sameSync(this.latestSyncSent, sync)) {
			debugLog(`producer.live.viewport no-op ${formatRect(sync.rect)}`);
			return;
		}
		debugLog(`producer.live.viewport ${formatRect(sync.rect)} clip=${formatRect(sync.clip)}`);
		this.writeControl(makeViewportMessage({
			windowId: WINDOW_ID,
			rectCells: sync.rect,
			clipCells: sync.clip,
			terminalCells: sync.terminal,
			aspect: PANEL_ASPECT,
			zBase: this.zBase,
		}));
		this.latestSyncSent = sync;
		this.callbacks.onStatus("viewport");
	}

	stop(reason: string): void {
		const child = this.child;
		debugLog(`producer.live.stop reason=${reason} child=${child ? "yes" : "no"} attached=${this.attached}`);
		if (!child) return;
		if (child.stdin && !child.stdin.destroyed) {
			// Match the WM host: shutdown is the close primitive. The runtime handles
			// shutdown by flushing producer-owned delete placements and then emitting
			// a detached ack. Sending a separate detach first can make close ordering
			// harder to reason about and is unnecessary for panel teardown.
			this.writeControl(makeShutdownMessage());
			child.stdin.end();
		}
		if (child.exitCode === null && child.signalCode === null && !child.killed) {
			this.killTimer = setTimeout(() => {
				debugLog(`producer.live.stop timeout exitCode=${child.exitCode ?? "null"} signal=${child.signalCode ?? "null"} killed=${child.killed}`);
				if (child.exitCode === null && child.signalCode === null && !child.killed) child.kill("SIGTERM");
			}, 1000);
		}
		this.attached = false;
		this.latestSyncSent = undefined;
	}

	private writeControl(message: string): void {
		if (!this.child?.stdin || this.child.stdin.destroyed) {
			debugLog(`producer.live.write skipped ${message.trim()}`);
			return;
		}
		debugLog(`producer.live.write ${message.trim()}`);
		this.child.stdin.write(message, (error) => {
			if (error) debugLog(`producer.live.write callback error=${error.message}`);
		});
	}

	private onStdout(chunk: string): void {
		const start = process.hrtime.bigint();
		const seq = ++globalChunkSeq;
		this.carry += chunk;
		let lines = 0;
		let frames = 0;
		for (;;) {
			const newline = this.carry.indexOf("\n");
			if (newline < 0) break;
			const line = this.carry.slice(0, newline);
			this.carry = this.carry.slice(newline + 1);
			lines++;
			const message = parseProducerLine(line);
			if (!message) {
				debugLog(`producer.live.stdout ignored ${line.slice(0, 160)}`);
				continue;
			}
			if (message.type === "frame_batch") {
				frames++;
				this.callbacks.onFrame?.(message);
			} else this.callbacks.onDetached?.(message);
		}
		const us = Number((process.hrtime.bigint() - start) / 1000n);
		if (us >= 1000 || lines > 0) {
			debugLog(`producer.live.chunk seq=${seq} profile=${this.profile} bytes=${chunk.length} lines=${lines} frames=${frames} us=${us}`);
		}
	}

	private onStderr(chunk: string): void {
		const lines = chunk.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
		if (lines.length === 0) return;
		const last = lines[lines.length - 1]!;
		debugLog(`producer.live.stderr ${last}`);
		this.callbacks.onError?.(last);
	}

	private binaryPath(): string {
		const envPath = process.env.KATZENSTEG_BIN;
		if (envPath && envPath.trim().length > 0) return envPath;
		const localBuild = path.join(REPO_ROOT, "zig-out/bin/katzensteg");
		if (existsSync(localBuild)) return localBuild;
		return "katzensteg";
	}
}

function producerEnv(): NodeJS.ProcessEnv {
	const env: NodeJS.ProcessEnv = {
		...process.env,
	};
	if (PANEL_WINDOW_POLICY) env.KATZENSTEG_WINDOW_POLICY = PANEL_WINDOW_POLICY;
	if (PANEL_REAL_WINDOW) env.KATZENSTEG_REAL_WINDOW = PANEL_REAL_WINDOW;
	debugLog(
		`producer.env trace_blocking=${env.KATZENSTEG_TRACE_BLOCKING ?? "(unset)"} threshold_ms=${env.KATZENSTEG_TRACE_BLOCKING_THRESHOLD_MS ?? "(unset)"} window_policy=${env.KATZENSTEG_WINDOW_POLICY ?? "(profile)"} real_window=${env.KATZENSTEG_REAL_WINDOW ?? "(profile)"}`,
	);
	return env;
}

function parseCommand(args: string): PanelCommand {
	const parts = args.trim().split(/\s+/).filter(Boolean);
	if (parts.length === 0) return { kind: "toggle" };
	if (parts[0] === "inline") return { kind: "inline", profile: parts.slice(1).join(" ") || undefined };
	if (parts[0] === "open") return { kind: "open", profile: parts.slice(1).join(" ") || undefined };
	if (parts[0] === "close") return { kind: "close" };
	if (parts[0] === "size" && isSizePreset(parts[1])) return { kind: "size", size: parts[1] };
	if (parts[0] === "profile" && parts[1]) return { kind: "profile", profile: parts.slice(1).join(" ") };
	if (isSizePreset(parts[0])) return { kind: "size", size: parts[0] };
	return { kind: "open", profile: parts.join(" ") };
}

function parseMode(value: string | undefined): PanelMode {
	return value === "layout" ? "layout" : "live";
}

function isSizePreset(value: string | undefined): value is SizePresetName {
	return value === "small" || value === "medium" || value === "large";
}

function fallbackPanelRowsForSize(size: SizePreset): number {
	return typeof size.height === "number" ? size.height : 20;
}

function makeAttachMessage(options: AttachOptions): string {
	return JSON.stringify({
		type: "attach",
		window_id: options.windowId,
		rect_cells: options.rectCells,
		...(options.clipCells === undefined ? {} : { clip_cells: options.clipCells }),
		...(options.terminalCells === undefined ? {} : { terminal_cells: options.terminalCells }),
		aspect: options.aspect,
		z_base: options.zBase,
		id_ranges: { image: [options.imageIds], placement: [options.placementIds] },
		upload: {
			profile: options.upload.profile,
			...(options.upload.path === undefined ? {} : { path: options.upload.path }),
			high_water: options.upload.highWater,
		},
	}) + "\n";
}

function makeViewportMessage(options: ViewportOptions): string {
	return JSON.stringify({
		type: "viewport",
		window_id: options.windowId,
		rect_cells: options.rectCells,
		...(options.clipCells === undefined ? {} : { clip_cells: options.clipCells }),
		...(options.terminalCells === undefined ? {} : { terminal_cells: options.terminalCells }),
		aspect: options.aspect,
		z_base: options.zBase,
	}) + "\n";
}

function makeShutdownMessage(): string {
	return JSON.stringify({ type: "shutdown" }) + "\n";
}

function parseProducerLine(line: string): FrameBatch | DetachedMessage | null {
	let message: unknown;
	try {
		message = JSON.parse(line);
	} catch {
		return null;
	}
	if (!isRecord(message)) return null;
	if (message.type === "detached") {
		if (typeof message.window_id !== "string") return null;
		return { type: "detached", window_id: message.window_id };
	}
	if (message.type !== "frame_batch") return null;
	if (typeof message.window_id !== "string" || typeof message.seq !== "number") return null;
	if (!isRecord(message.groups)) return null;
	const groups = message.groups;
	if (!isStringArray(groups.deletes)) return null;
	if (!isStringArray(groups.uploads)) return null;
	if (!isStringArray(groups.placements)) return null;
	if (!isStringArray(groups.after)) return null;
	return {
		type: "frame_batch",
		window_id: message.window_id,
		seq: message.seq,
		groups: { deletes: groups.deletes, uploads: groups.uploads, placements: groups.placements, after: groups.after },
	};
}

function orderedTerminalChunks(batch: FrameBatch): string[] {
	return [...batch.groups.deletes, ...batch.groups.uploads, ...batch.groups.placements, ...batch.groups.after];
}

function cleanupTerminalChunks(batch: FrameBatch): string[] {
	// While closing, replay renderer-authored cleanup but do not accept any late
	// uploads or placements that could make the panel visible again after detach.
	return [...batch.groups.deletes, ...batch.groups.after];
}

function isCleanupOnlyBatch(batch: FrameBatch): boolean {
	return batch.groups.deletes.length > 0 && batch.groups.uploads.length === 0 && batch.groups.placements.length === 0;
}

function isRecord(value: unknown): value is Record<string, any> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isStringArray(value: unknown): value is string[] {
	return Array.isArray(value) && value.every((item) => typeof item === "string");
}

function fitCellText(value: string, width: number): string {
	const truncated = truncateToWidth(value, width, "…");
	return truncated + " ".repeat(Math.max(0, width - visibleWidth(truncated)));
}

function parseIntegerEnv(value: string | undefined, fallback: number): number {
	if (value === undefined || value.trim().length === 0) return fallback;
	const parsed = Number.parseInt(value, 10);
	return Number.isFinite(parsed) ? parsed : fallback;
}

function nonEmptyEnv(value: string | undefined): string | undefined {
	if (value === undefined) return undefined;
	const trimmed = value.trim();
	return trimmed.length > 0 ? trimmed : undefined;
}

function sameRect(a: RectCells | undefined, b: RectCells): boolean {
	return !!a && a.row === b.row && a.col === b.col && a.rows === b.rows && a.cols === b.cols;
}

function sameOptionalRect(a: RectCells | undefined, b: RectCells | undefined): boolean {
	if (!a && !b) return true;
	if (!a || !b) return false;
	return a.row === b.row && a.col === b.col && a.rows === b.rows && a.cols === b.cols;
}

function sameSync(a: ViewportSync | undefined, b: ViewportSync): boolean {
	if (!a) return false;
	return sameRect(a.rect, b.rect)
		&& sameOptionalRect(a.clip, b.clip)
		&& a.terminal.rows === b.terminal.rows
		&& a.terminal.cols === b.terminal.cols;
}

function formatRect(rect: RectCells | undefined): string {
	if (!rect) return "none";
	return `${rect.row},${rect.col} ${rect.rows}x${rect.cols}`;
}

function debugLog(message: string): void {
	try {
		appendFileSync(DEBUG_LOG_PATH, `${new Date().toISOString()} ${message}\n`);
	} catch {
		// ignore debug logging failures
	}
}
