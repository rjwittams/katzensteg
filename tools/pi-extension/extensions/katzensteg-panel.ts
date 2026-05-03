import { appendFileSync, existsSync, mkdtempSync } from "node:fs";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionCommandContext, Theme } from "@mariozechner/pi-coding-agent";
import { type OverlayHandle, truncateToWidth, visibleWidth } from "@mariozechner/pi-tui";

const WINDOW_ID = "main" as const;
const IMAGE_IDS: [number, number] = [100000, 199999];
const PLACEMENT_IDS: [number, number] = [200000, 299999];
const DEFAULT_PROFILE = process.env.KATZENSTEG_PI_PROFILE || "sonic";
const DEFAULT_MODE = parseMode(process.env.KATZENSTEG_PANEL_MODE);
const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const DEFAULT_UPLOAD_HIGH_WATER = 10 * 1024 * 1024;
const DEBUG_LOG_PATH = "/tmp/katzensteg-pi-extension.log";

const VIEWPORT_ROW_OFFSET = 3; // top border + title + status
const VIEWPORT_COL_OFFSET = 1; // left border
const FRAME_OVERHEAD_ROWS = 4; // top border + title + status + bottom border
const FRAME_OVERHEAD_COLS = 2; // left/right borders
const PANEL_MARGIN = 1;
const PANEL_ASPECT: Aspect = "fit";
// Katzensteg's full-frame composite uses z=100. In a Pi overlay the host text
// chrome should remain readable, so neutralize that by default and let callers
// override when debugging terminal z behaviour.
const PANEL_Z_BASE = parseIntegerEnv(process.env.KATZENSTEG_PANEL_Z_BASE, -100);
const DEFAULT_WINDOW_POLICY = process.env.KATZENSTEG_PANEL_WINDOW_POLICY || process.env.KATZENSTEG_WINDOW_POLICY || "mirror";
const DEFAULT_REAL_WINDOW = process.env.KATZENSTEG_PANEL_REAL_WINDOW || process.env.KATZENSTEG_REAL_WINDOW || "show";
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
	| { kind: "profile"; profile: string };

interface RectCells {
	row: number;
	col: number;
	rows: number;
	cols: number;
}

interface OverlayRect extends RectCells {}

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
	aspect: Aspect;
	zBase: number;
	imageIds: [number, number];
	placementIds: [number, number];
	upload: { profile: UploadProfile; path?: string; highWater: number };
}

interface ViewportOptions {
	windowId: typeof WINDOW_ID;
	rectCells: RectCells;
	aspect: Aspect;
	zBase: number;
}

const SIZE_PRESETS: Record<SizePresetName, SizePreset> = {
	small: { name: "small", width: 44, height: 12 },
	medium: { name: "medium", width: 56, height: 20 },
	large: { name: "large", width: "50%", height: "85%" },
};

let activeController: PanelController | undefined;
let preferredProfile = DEFAULT_PROFILE;
let preferredSize: SizePresetName = "medium";

export default function (pi: ExtensionAPI) {
	pi.on("session_shutdown", () => {
		debugLog("session_shutdown");
		activeController?.close("session_shutdown");
		activeController = undefined;
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
					if (activeController) activeController.setSize(SIZE_PRESETS[command.size]);
					else ctx.ui.notify(`Set Katzensteg panel size to ${command.size}`, "info");
					break;
				case "profile":
					preferredProfile = command.profile;
					if (activeController) activeController.setProfile(command.profile);
					else openPanel(ctx, command.profile, preferredSize);
					break;
			}
		},
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
		if (this.latestViewport) this.scheduleViewportSync(this.currentGeneration, this.latestViewport);
	}

	render(width: number, theme: Theme): string[] {
		const innerWidth = Math.max(1, width - 2);
		const row = (content: string) => theme.fg("border", "│") + fitCellText(content, innerWidth) + theme.fg("border", "│");
		const lines: string[] = [];
		const title = ` 🐈 Katzensteg · ${this.mode} · ${this.profile} · ${this.size.name}`;
		const status = this.error ? theme.fg("error", ` ${this.error}`) : theme.fg("dim", ` ${this.status}`);
		const rectLine = this.latestOverlayRect
			? ` overlay ${formatRect(this.latestOverlayRect)} viewport ${formatRect(this.latestViewport)} z=${PANEL_Z_BASE}`
			: " waiting for overlay rect";

		const panelRows = this.latestOverlayRect?.rows ?? fallbackPanelRowsForSize(this.size);
		const bodyRows = Math.max(2, panelRows - FRAME_OVERHEAD_ROWS);

		lines.push(theme.fg("border", `╭${"─".repeat(innerWidth)}╮`));
		lines.push(row(theme.fg("accent", title)));
		lines.push(row(this.mode === "layout" ? theme.fg("dim", rectLine) : status));
		for (let i = 0; i < bodyRows; i++) lines.push(row(""));
		lines.push(theme.fg("border", `╰${"─".repeat(innerWidth)}╯`));
		return lines;
	}

	onOverlayRect(generation: number, rect: OverlayRect | undefined): void {
		if (this.closed || this.closing || generation !== this.currentGeneration || !rect) return;
		const viewport = innerViewport(rect);
		debugLog(`overlay.rect gen=${generation} raw=${formatRect(rect)} viewport=${formatRect(viewport)}`);
		if (!viewport) return;
		this.latestOverlayRect = rect;
		this.latestViewport = viewport;
		this.overlay?.invalidate();
		this.scheduleViewportSync(generation, viewport);
	}

	private scheduleViewportSync(generation: number, viewport: RectCells): void {
		this.overlay?.afterNextRender(() => {
			if (this.closed || this.closing || generation !== this.currentGeneration) {
				debugLog(`viewport.sync stale gen=${generation} current=${this.currentGeneration}`);
				return;
			}
			debugLog(`viewport.sync gen=${generation} viewport=${formatRect(viewport)}`);
			this.producer.setViewport(viewport);
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
		return this.mode === "live"
			? new KatzenstegProducer(profile, {
				onFrame: (batch) => this.onFrame(batch),
				onDetached: (message) => this.onDetached(message),
				onStatus: (status) => this.setStatus(status),
				onError: (error) => this.setError(error),
			})
			: new LayoutOnlyProducer({ onStatus: (status) => this.setStatus(status) });
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

interface ProducerCallbacks {
	onFrame?: (batch: FrameBatch) => void;
	onDetached?: (message: DetachedMessage) => void;
	onStatus: (status: string) => void;
	onError?: (error: string) => void;
}

interface ProducerConnection {
	start(): void;
	setViewport(viewport: RectCells): void;
	stop(reason: string): void;
}

class LayoutOnlyProducer implements ProducerConnection {
	private lastViewport: RectCells | undefined;

	constructor(private readonly callbacks: ProducerCallbacks) {}

	start(): void {
		debugLog("producer.layout.start");
		this.callbacks.onStatus("layout-only");
	}

	setViewport(viewport: RectCells): void {
		if (sameRect(this.lastViewport, viewport)) return;
		this.lastViewport = viewport;
		debugLog(`producer.layout.viewport ${formatRect(viewport)}`);
		this.callbacks.onStatus(`layout viewport ${formatRect(viewport)}`);
	}

	stop(reason: string): void {
		debugLog(`producer.layout.stop reason=${reason}`);
	}
}

class KatzenstegProducer implements ProducerConnection {
	private child: ChildProcessWithoutNullStreams | undefined;
	private carry = "";
	private attached = false;
	private lastViewportSent: RectCells | undefined;
	private killTimer: NodeJS.Timeout | undefined;
	private readonly uploadDir = mkdtempSync(path.join(os.tmpdir(), "katzensteg-pi-"));
	private readonly uploadPath = path.join(this.uploadDir, "embed-upload.rgba");

	constructor(
		private readonly profile: string,
		private readonly callbacks: ProducerCallbacks,
	) {}

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
			this.lastViewportSent = undefined;
			this.callbacks.onStatus(signal ? `exited ${signal}` : `exited ${code ?? 0}`);
		});
	}

	setViewport(viewport: RectCells): void {
		if (!this.child?.stdin) {
			debugLog(`producer.live.viewport skipped no child viewport=${formatRect(viewport)}`);
			return;
		}
		if (!this.attached) {
			debugLog(`producer.live.attach ${formatRect(viewport)}`);
			this.writeControl(makeAttachMessage({
				windowId: WINDOW_ID,
				rectCells: viewport,
				aspect: PANEL_ASPECT,
				zBase: PANEL_Z_BASE,
				imageIds: IMAGE_IDS,
				placementIds: PLACEMENT_IDS,
				upload: { profile: "file_whole", path: this.uploadPath, highWater: DEFAULT_UPLOAD_HIGH_WATER },
			}));
			this.attached = true;
			this.lastViewportSent = viewport;
			this.callbacks.onStatus("attached");
			return;
		}
		if (sameRect(this.lastViewportSent, viewport)) {
			debugLog(`producer.live.viewport no-op ${formatRect(viewport)}`);
			return;
		}
		debugLog(`producer.live.viewport ${formatRect(viewport)}`);
		this.writeControl(makeViewportMessage({ windowId: WINDOW_ID, rectCells: viewport, aspect: PANEL_ASPECT, zBase: PANEL_Z_BASE }));
		this.lastViewportSent = viewport;
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
		this.lastViewportSent = undefined;
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
		this.carry += chunk;
		for (;;) {
			const newline = this.carry.indexOf("\n");
			if (newline < 0) break;
			const line = this.carry.slice(0, newline);
			this.carry = this.carry.slice(newline + 1);
			const message = parseProducerLine(line);
			if (!message) {
				debugLog(`producer.live.stdout ignored ${line.slice(0, 160)}`);
				continue;
			}
			if (message.type === "frame_batch") this.callbacks.onFrame?.(message);
			else this.callbacks.onDetached?.(message);
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
	return {
		...process.env,
		KATZENSTEG_WINDOW_POLICY: DEFAULT_WINDOW_POLICY,
		KATZENSTEG_REAL_WINDOW: DEFAULT_REAL_WINDOW,
	};
}

function parseCommand(args: string): PanelCommand {
	const parts = args.trim().split(/\s+/).filter(Boolean);
	if (parts.length === 0) return { kind: "toggle" };
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

function innerViewport(rect: OverlayRect): RectCells | undefined {
	const row = rect.row + 1 + VIEWPORT_ROW_OFFSET;
	const col = rect.col + 1 + VIEWPORT_COL_OFFSET;
	const rows = rect.rows - FRAME_OVERHEAD_ROWS;
	const cols = rect.cols - FRAME_OVERHEAD_COLS;
	if (rows < 2 || cols < 2) return undefined;
	return { row, col, rows, cols };
}

function makeAttachMessage(options: AttachOptions): string {
	return JSON.stringify({
		type: "attach",
		window_id: options.windowId,
		rect_cells: options.rectCells,
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

function sameRect(a: RectCells | undefined, b: RectCells): boolean {
	return !!a && a.row === b.row && a.col === b.col && a.rows === b.rows && a.cols === b.cols;
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
