import { type ChildProcessWithoutNullStreams, spawn } from "node:child_process";
import {
	appendFileSync,
	existsSync,
	mkdtempSync,
	readFileSync,
	rmSync,
} from "node:fs";
import type { Socket } from "node:net";
import type { Writable } from "node:stream";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type {
	ExtensionAPI,
	ExtensionContext,
	Theme,
} from "@earendil-works/pi-coding-agent";
import {
	type CellDimensions,
	getCellDimensions,
	type OverlayHandle,
	type SurfaceGeometry,
	type SurfaceHandle,
	type TuiMouseEvent,
	type TuiMouseEventResult,
	truncateToWidth,
	visibleWidth,
} from "@earendil-works/pi-tui";
import { type FrameBatch, PendingBatches } from "./katzensteg-batches.js";
import {
	expandHomePrefix,
	parseCommand,
	type SizePresetName,
	sameArgs,
} from "./katzensteg-command.js";
import {
	GameInteraction,
	type Observation,
	rgbaPng,
} from "./katzensteg-game.js";
import {
	bodyHasVisibleCells,
	clipCellsForBody,
	FRAME_OVERHEAD_ROWS,
	messageLogicalBodyRect,
	occlusionCellsForBody,
	type RectCells,
	statusLineVisible,
} from "./katzensteg-geometry.js";
import {
	makeTerminalBytesInputMessage,
	PointerInput,
} from "./katzensteg-input.js";
import {
	installHostEnvironment,
	interactiveHostState,
	listenForLaunches,
} from "./katzensteg-host.js";
import { registerGameTools } from "./katzensteg-tools.js";
import { PanelWindowControls } from "./katzensteg-window.js";

const liveGamePanels = new Set<SurfacePanel>();
let nextGamePanelId = 1;

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

function allocateIdRanges(): {
	imageIds: [number, number];
	placementIds: [number, number];
} {
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
const REPO_ROOT = path.resolve(
	path.dirname(fileURLToPath(import.meta.url)),
	"../../..",
);
const DEFAULT_UPLOAD_HIGH_WATER = 10 * 1024 * 1024;
const DEBUG_LOG_PATH = "/tmp/katzensteg-pi-extension.log";

const PANEL_MARGIN = 1;
const PANEL_ASPECT: Aspect = "fit";
// Katzensteg's full-frame composite uses z=100. For inline panels we neutralize
// that (effective z=0) so host text chrome stays readable. The floating panel
// should sit on top of any inline panels, so it keeps katzensteg's native z.
const INLINE_Z_BASE = parseIntegerEnv(
	process.env.KATZENSTEG_PANEL_Z_BASE,
	-100,
);
const FLOATING_Z_BASE = parseIntegerEnv(
	process.env.KATZENSTEG_PANEL_FLOATING_Z_BASE,
	0,
);
const PANEL_WINDOW_POLICY = nonEmptyEnv(
	process.env.KATZENSTEG_PANEL_WINDOW_POLICY,
);
const PANEL_REAL_WINDOW = nonEmptyEnv(process.env.KATZENSTEG_PANEL_REAL_WINDOW);

type Aspect = "fit" | "stretch" | "cover";
type UploadProfile = "direct_apc" | "shm" | "file_whole" | "file_offset_ring";
type PanelMode = "layout" | "live";
interface PanelDetails {
	mode: PanelMode;
	profile: string;
	size: SizePresetName;
	// Extra arguments forwarded verbatim to the program launched under
	// katzensteg, appended after the profile's own configured args.
	args?: string[];
}

type OverlayRect = SurfaceGeometry;

interface TerminalCells {
	rows: number;
	cols: number;
}

interface ViewportSync {
	cellDimensions: CellDimensions;
	rect: RectCells;
	clip: RectCells | undefined;
	occlusions: RectCells[];
	generation: number;
}

interface SizePreset {
	name: SizePresetName;
	width: number | `${number}%`;
	height: number | `${number}%`;
}

interface DetachedMessage {
	type: "detached";
	window_id: string;
}

interface AttachOptions {
	generation: number;
	windowId: typeof WINDOW_ID;
	rectCells: RectCells;
	clipCells?: RectCells;
	occlusions: RectCells[];
	cellDimensions: CellDimensions;
	aspect: Aspect;
	zBase: number;
	imageIds: [number, number];
	placementIds: [number, number];
	upload: { profile: UploadProfile; path?: string; highWater: number };
}

interface ViewportOptions {
	generation: number;
	windowId: typeof WINDOW_ID;
	rectCells: RectCells;
	clipCells?: RectCells;
	occlusions: RectCells[];
	cellDimensions: CellDimensions;
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

const floatingPanels = new Set<PanelController>();
let nextFloatingLevel = 0;
const inlinePanels = new Set<SurfacePanel>();
let preferredProfile = DEFAULT_PROFILE;
let preferredArgs: string[] = [];
let preferredSize: SizePresetName = "medium";
let globalChunkSeq = 0;

export default function (pi: ExtensionAPI) {
	const hostState = interactiveHostState();
	let startingHost: Promise<void> | undefined;
	let shutdown = false;
	let hostContext: Pick<ExtensionContext, "ui"> | undefined;
	pi.on("session_start", async (_event, ctx) => {
		if (!ctx.hasUI || shutdown) return;
		hostContext = ctx;
		hostState.onLaunch = async (socket, title) => {
			if (shutdown || !hostContext) {
				socket.destroy();
				return;
			}
			await openPanel(hostContext, title, preferredSize, [], socket);
		};
		hostState.onError = (error) =>
			hostContext?.ui.notify(`Katzensteg host: ${error.message}`, "error");
		if (hostState.listener) return;
		if (!startingHost)
			startingHost = (async () => {
				try {
					const listener = await listenForLaunches(
						(socket, title) => {
							if (hostState.onLaunch) return hostState.onLaunch(socket, title);
							socket.destroy();
						},
						(error) => hostState.onError?.(error),
					);
					if (shutdown) {
						listener.close();
						return;
					}
					hostState.listener = listener;
					hostState.restoreEnvironment = installHostEnvironment(
						listener.target,
					);
					debugLog(`host.listen ${listener.target}`);
				} catch (error) {
					ctx.ui.notify(`Katzensteg host failed: ${String(error)}`, "error");
				}
			})();
		await startingHost;
		startingHost = undefined;
	});
	registerGameTools(
		pi,
		() => [...liveGamePanels].flatMap((panel) => panel.agentPanel() ?? []),
		(ctx, profile, args) =>
			openPanel(
				ctx,
				profile,
				preferredSize,
				args.map((arg) => expandHomePrefix(arg, os.homedir())),
			),
	);
	let heartbeatTimer: ReturnType<typeof setTimeout> | undefined;
	let heartbeatStopped = false;
	pi.on("session_shutdown", (event) => {
		shutdown = true;
		hostContext = undefined;
		hostState.onLaunch = undefined;
		hostState.onError = undefined;
		if (
			event.reason !== "new" &&
			event.reason !== "resume" &&
			event.reason !== "fork"
		) {
			hostState.restoreEnvironment?.();
			hostState.listener?.close();
			hostState.listener = undefined;
			hostState.restoreEnvironment = undefined;
		}
		heartbeatStopped = true;
		if (heartbeatTimer) clearTimeout(heartbeatTimer);
		debugLog("session_shutdown");
		for (const panel of floatingPanels) panel.close("session_shutdown");
		for (const panel of inlinePanels) panel.close("session_shutdown");
		inlinePanels.clear();
	});

	// Event loop lag heartbeat: schedule setImmediate every 100ms, measure how long
	// it actually takes to fire. Spikes mean the event loop was busy with something.
	let heartbeatPrev = process.hrtime.bigint();
	const heartbeat = (): void => {
		if (heartbeatStopped) return;
		const now = process.hrtime.bigint();
		const elapsedMs = Number((now - heartbeatPrev) / 1_000_000n);
		heartbeatPrev = now;
		if (elapsedMs > 150) debugLog(`pi.event_loop_lag_ms=${elapsedMs}`);
		heartbeatTimer = setTimeout(heartbeat, 100);
	};
	heartbeatTimer = setTimeout(heartbeat, 100);

	pi.registerMessageRenderer<PanelDetails>(
		"katzensteg-panel",
		(message, options, theme) => {
			const details = message.details;
			if (!details || !options.ui) return undefined;
			const controller = new SurfacePanel(theme, details);
			controller.attach(options.ui.trackSurface(controller, { mouse: true }));
			inlinePanels.add(controller);
			return controller;
		},
	);

	pi.registerCommand("katzensteg-panel", {
		description: "Show or control a Katzensteg embed panel",
		handler: async (args, ctx) => {
			const activeController = [...floatingPanels].at(-1);
			const command = parseCommand(args);
			debugLog(`command ${JSON.stringify(command)}`);
			// The launcher forwards extra args verbatim, so expand a leading ~
			// here (no shell does it for us). Other tokens stay literal.
			const home = os.homedir();
			const programArgs =
				command.kind === "open" ||
				command.kind === "inline" ||
				command.kind === "profile"
					? (command.args ?? []).map((arg) => expandHomePrefix(arg, home))
					: [];
			switch (command.kind) {
				case "toggle":
					if (activeController) {
						activeController.close("toggle");
						ctx.ui.notify("Closed Katzensteg panel", "info");
					} else {
						openPanel(ctx, preferredProfile, preferredSize, preferredArgs);
					}
					break;
				case "open":
					openPanel(
						ctx,
						command.profile ?? preferredProfile,
						preferredSize,
						programArgs,
					);
					break;
				case "inline":
					sendInlinePanel(
						pi,
						command.profile ?? preferredProfile,
						preferredSize,
						programArgs,
					);
					break;
				case "close":
					if (!activeController) {
						ctx.ui.notify("Katzensteg panel is not open", "warning");
						break;
					}
					activeController.close("command-close");
					ctx.ui.notify("Closed Katzensteg panel", "info");
					break;
				case "size":
					preferredSize = command.size;
					if (activeController instanceof PanelController)
						activeController.setSize(SIZE_PRESETS[command.size]);
					else
						ctx.ui.notify(
							`Set Katzensteg panel size to ${command.size}`,
							"info",
						);
					break;
				case "profile":
					// Switching profile resets program args to whatever this command
					// supplied (args are program-specific; don't carry them across
					// a profile change).
					preferredProfile = command.profile;
					preferredArgs = programArgs;
					if (activeController instanceof PanelController)
						activeController.setProfile(command.profile, preferredArgs);
					else openPanel(ctx, command.profile, preferredSize, preferredArgs);
					break;
			}
		},
	});
}

function sendInlinePanel(
	pi: ExtensionAPI,
	profile: string,
	sizeName: SizePresetName,
	args: string[],
): void {
	preferredProfile = profile;
	preferredArgs = args;
	preferredSize = sizeName;
	pi.sendMessage<PanelDetails>({
		customType: "katzensteg-panel",
		content: `Katzensteg panel · ${profile} · ${sizeName}`,
		display: true,
		details: {
			mode: DEFAULT_MODE,
			profile,
			size: sizeName,
			...(args.length > 0 ? { args } : {}),
		},
	});
}

function openPanel(
	ctx: Pick<ExtensionContext, "ui">,
	profile: string,
	sizeName: SizePresetName,
	args: string[],
	socket?: Socket,
): Promise<string> {
	if (!socket) {
		preferredProfile = profile;
		preferredArgs = args;
		preferredSize = sizeName;
	}
	const controller = new PanelController(
		ctx,
		socket ? "live" : DEFAULT_MODE,
		profile,
		SIZE_PRESETS[sizeName],
		args,
		socket,
	);
	floatingPanels.add(controller);
	const opened = new Promise<string>((resolve, reject) => {
		void controller
			.open(resolve)
			.then(() => reject(new Error("Panel closed before opening")))
			.catch((error: unknown) => {
				floatingPanels.delete(controller);
				ctx.ui.notify(
					`Katzensteg panel failed: ${error instanceof Error ? error.message : String(error)}`,
					"error",
				);
				reject(error);
			});
	});
	// Command callers may intentionally leave the panel opening in the background.
	void opened.catch(() => {});
	return opened;
}

class PanelController {
	private readonly zBase = FLOATING_Z_BASE + nextFloatingLevel++ * 10000;
	private readonly cascade = floatingPanels.size % 6;
	private readonly ctx: Pick<ExtensionContext, "ui">;
	private readonly mode: PanelMode;
	private profile: string;
	private size: SizePreset;
	private args: string[];
	private component: SurfacePanel | undefined;
	private done: (() => void) | undefined;
	private closed = false;

	private readonly socket: Socket | undefined;

	constructor(
		ctx: Pick<ExtensionContext, "ui">,
		mode: PanelMode,
		profile: string,
		size: SizePreset,
		args: string[] = [],
		socket?: Socket,
	) {
		this.socket = socket;
		this.ctx = ctx;
		this.mode = mode;
		this.profile = profile;
		this.size = size;
		this.args = args;
	}

	async open(onOpened: (id: string) => void): Promise<void> {
		try {
			await this.ctx.ui.custom<void>(
				(tui, theme, _keys, done) => {
					this.done = done;
					this.component = new SurfacePanel(
						theme,
						{
							mode: this.mode,
							profile: this.profile,
							size: this.size.name,
							args: this.args,
						},
						done,
						this.zBase,
						() => this.activate(),
						this.socket,
					);
					this.component.attach(
						tui.trackSurface(this.component, { mouse: true }),
					);
					if (this.closed) done();
					return this.component;
				},
				{
					overlay: true,
					overlayOptions: () => ({
						anchor: "top-right",
						nonCapturing: true,
						width: this.size.width,
						height: this.size.height,
						margin: PANEL_MARGIN,
						offsetX: -this.cascade * 4,
						offsetY: this.cascade * 2,
					}),
					onHandle: (handle) => {
						this.component?.setOverlay(handle);
						if (this.component && !this.closed)
							onOpened(this.component.gamePanelId);
					},
				},
			);
		} catch (error) {
			if (!this.component?.disposed) throw error;
		} finally {
			this.component?.dispose();
			if (!this.component) this.socket?.destroy();
			floatingPanels.delete(this);
		}
	}

	close(reason: string): void {
		debugLog(`controller.close ${reason}`);
		floatingPanels.delete(this);
		this.closed = true;
		this.done?.();
	}
	private activate(): void {
		if (this.closed || !floatingPanels.has(this)) return;
		if ([...floatingPanels].at(-1) === this) return;
		floatingPanels.delete(this);
		floatingPanels.add(this);
		this.component?.raise(FLOATING_Z_BASE + nextFloatingLevel++ * 10000);
	}
	setSize(size: SizePreset): void {
		this.size = size;
		this.component?.setSize(size);
	}
	setProfile(profile: string, args: string[] = []): void {
		if (profile === this.profile && sameArgs(args, this.args)) return;
		this.profile = profile;
		this.args = args;
		this.component?.setProfile(profile, args);
	}
}

/** One lifecycle and output path for floating and inline panels. */
export class SurfacePanel implements ActivePanel {
	readonly gamePanelId = `panel-${nextGamePanelId++}`;
	agentPanel() {
		const game = this.producer?.game;
		return !this.disposed && this.producer?.ready && game
			? { id: this.gamePanelId, profile: this.details.profile, game }
			: undefined;
	}
	private inputFocused = false;
	get focused(): boolean {
		return this.inputFocused;
	}
	set focused(value: boolean) {
		if (value && !this.inputFocused && !this.disposed)
			this.producer?.game?.cancel();
		if (!value && this.inputFocused && !this.disposed)
			this.producer?.sendInput(makeTerminalBytesInputMessage(WINDOW_ID, "\x1b[O"));
		this.inputFocused = value;
	}
	disposed = false;
	private readonly theme: Theme;
	private readonly floating: boolean;
	private zBase: number;
	private readonly activate: (() => void) | undefined;
	private readonly window: PanelWindowControls | undefined;
	private bodyCapture = false;
	private details: PanelDetails;
	private surface: SurfaceHandle | undefined;
	private overlay: OverlayHandle | undefined;
	private geometry: SurfaceGeometry | undefined;
	private sync: ViewportSync | undefined;
	private generation = 0;
	private producerEpoch = 0;
	private producer: ProducerConnection | undefined;
	private batches = new PendingBatches();
	private pendingCleanup = "";
	private pointer = new PointerInput();
	private status = "starting";
	private error: string | undefined;

	private socket: Socket | undefined;

	constructor(
		theme: Theme,
		details: PanelDetails,
		close?: () => void,
		zBase = INLINE_Z_BASE,
		activate?: () => void,
		socket?: Socket,
	) {
		this.socket = socket;
		this.theme = theme;
		this.zBase = zBase;
		this.activate = activate;
		this.details = details;
		liveGamePanels.add(this);
		this.floating = !!close;
		if (close)
			this.window = new PanelWindowControls(
				() => this.geometry?.bounds,
				(options) => this.overlay?.updateOptions(options),
				close,
			);
	}

	attach(surface: SurfaceHandle): void {
		this.surface = surface;
		surface.onGeometryChange((geometry) => this.onGeometry(geometry));
		surface.onRender((frame) => {
			if (this.pendingCleanup) {
				frame.write(this.pendingCleanup);
				this.pendingCleanup = "";
			}
			if (frame.disposed) {
				this.batches.flush(frame, false);
				this.dispose();
				return;
			}
			if (this.disposed) return;
			// Pi can receive its startup cell-size reply after our initial attach.
			// Re-read its cache on render; it already invalidates images on a reply.
			if (
				this.sync &&
				!sameCellDimensions(this.sync.cellDimensions, getCellDimensions())
			)
				this.onGeometry(this.geometry);
			if (!this.producer && this.sync) this.startProducer();
			const visible =
				!!frame.geometry &&
				!!this.sync &&
				bodyHasVisibleCells(
					this.sync.rect,
					this.sync.clip,
					this.sync.occlusions,
				);
			this.batches.flush(frame, visible);
		});
	}

	setOverlay(overlay: OverlayHandle): void {
		this.overlay = overlay;
	}
	raise(zBase: number): void {
		if (this.disposed) return;
		this.zBase = zBase;
		this.overlay?.focus();
		if (this.sync) {
			this.sync = { ...this.sync, generation: ++this.generation };
			this.batches.setGeneration(this.generation);
			this.producer?.setViewport(this.sync, this.zBase);
		}
		this.surface?.requestRender();
	}
	setSize(size: SizePreset): void {
		this.details = { ...this.details, size: size.name };
		this.overlay?.updateOptions({ width: size.width, height: size.height });
		this.surface?.requestRender();
	}
	setProfile(profile: string, args: string[]): void {
		this.socket?.destroy();
		this.socket = undefined;
		this.handleMouseCancel();
		this.producerEpoch++;
		this.producer?.stop("profile-change");
		this.producer = undefined;
		// Cleanup is deferred to the next legal graphics write, before the new
		// producer's first frame. Late callbacks from the old epoch are ignored.
		this.pendingCleanup += this.batches.dispose();
		this.batches = new PendingBatches();
		this.batches.setGeneration(this.generation);
		this.details = { ...this.details, profile, args };
		this.status = "starting";
		this.error = undefined;
		this.surface?.requestRender();
	}

	render(width: number): string[] {
		return renderPanelChrome(width, this.theme, {
			mode: this.details.mode,
			profile: this.details.profile,
			sizeName: this.details.size,
			rect: this.geometry,
			viewport: this.sync?.rect,
			status: this.status,
			error: this.error,
			panelRows: this.floating
				? (this.geometry?.bounds.height ??
					fallbackPanelRowsForSize(SIZE_PRESETS[this.details.size]))
				: fallbackPanelRowsForSize(SIZE_PRESETS[this.details.size]),
			zBase: this.zBase,
			focused: this.focused,
			closeButton: this.floating,
		});
	}
	invalidate(): void {}
	handleInput(data: string): void {
		this.producer?.game?.cancel();
		if (!this.disposed)
			this.producer?.sendInput(makeTerminalBytesInputMessage(WINDOW_ID, data));
	}
	handleMouse(event: TuiMouseEvent): TuiMouseEventResult | undefined {
		if (this.disposed || event.type === "click") return undefined;
		// Layout gestures capture the pointer without taking game input focus.
		const chrome = this.window?.handle(event);
		if (chrome) return chrome;
		const insideBody =
			event.x >= 1 &&
			event.x < event.width - 1 &&
			event.y >= 3 &&
			event.y < event.height - 1;
		if (!this.bodyCapture && !insideBody)
			return event.type === "press" ? { handled: true } : undefined;
		// Hovering over an unfocused panel must not compete with the agent.
		if (!this.focused && !this.bodyCapture && event.type !== "press")
			return { handled: true, render: false };
		// Let pi record mouse focus before raising the overlay explicitly.
		if (event.type === "press")
			queueMicrotask(() => {
				if (!this.disposed) this.activate?.();
			});
		this.producer?.game?.cancel();
		if (event.type === "press") this.bodyCapture = true;
		if (event.type === "release") this.bodyCapture = false;
		const message = this.pointer.encode(WINDOW_ID, event);
		if (message) this.producer?.sendInput(message);
		return {
			handled: true,
			capture: event.type === "press",
			focus: event.type === "press",
			render: event.type === "press",
		};
	}
	handleMouseCancel(): void {
		this.window?.cancel();
		this.bodyCapture = false;
		for (const message of this.pointer.cancel(WINDOW_ID))
			this.producer?.sendInput(message);
	}
	close(reason: string): void {
		debugLog(`panel.close ${reason}`);
		this.dispose();
	}
	dispose(): void {
		this.socket?.destroy();
		this.socket = undefined;
		if (this.disposed) return;
		liveGamePanels.delete(this);
		this.handleMouseCancel();
		this.disposed = true;
		this.producerEpoch++;
		this.producer?.stop("surface-disposed");
		this.producer = undefined;
		this.surface?.dispose();
		inlinePanels.delete(this);
	}

	private onGeometry(geometry: SurfaceGeometry | undefined): void {
		if (this.disposed) return;
		const oldHeight = this.geometry?.bounds.height;
		this.geometry = geometry;
		if (this.floating && oldHeight !== geometry?.bounds.height)
			this.surface?.requestRender();
		const body = geometry ? messageLogicalBodyRect(geometry) : undefined;
		const rect = body ?? this.sync?.rect;
		if (!rect) return;
		const clip =
			body && geometry
				? clipCellsForBody(body, geometry)
				: { row: rect.row, col: rect.col, rows: 0, cols: 0 };
		const occlusions =
			body && geometry ? occlusionCellsForBody(body, geometry) : [];
		const cellDimensions = { ...getCellDimensions() };
		if (
			this.sync &&
			sameCellDimensions(this.sync.cellDimensions, cellDimensions) &&
			sameRect(this.sync.rect, rect) &&
			sameOptionalRect(this.sync.clip, clip) &&
			this.sync.occlusions.length === occlusions.length &&
			this.sync.occlusions.every((rect, index) =>
				sameRect(rect, occlusions[index]),
			)
		)
			return;
		this.sync = {
			rect,
			clip,
			occlusions,
			cellDimensions,
			generation: ++this.generation,
		};
		this.batches.setGeneration(this.generation);
		this.producer?.setViewport(this.sync, this.zBase);
		debugLog(
			`surface.geometry gen=${this.generation} body=${formatRect(rect)} clip=${formatRect(clip)}`,
		);
		this.surface?.requestRender();
	}

	private startProducer(): void {
		const epoch = ++this.producerEpoch;
		const current = () => !this.disposed && epoch === this.producerEpoch;
		this.producer = createProducer(
			this.details.mode,
			this.details.profile,
			{
				onFrame: (batch) => {
					if (!current()) return;
					try {
						this.batches.enqueue(batch);
					} catch (error) {
						this.error = String(error);
						this.producer?.stop("invalid-output");
					}
					if (statusLineVisible(this.geometry))
						this.status = `streaming #${batch.seq}`;
					this.surface?.requestRender();
				},
				onClosed: () => {
					if (!current()) return;
					this.pendingCleanup += this.batches.dispose();
					this.surface?.requestRender();
				},
				onDetached: () => {
					if (current()) {
						this.status = "detached";
						this.surface?.requestRender();
					}
				},
				onStatus: (status) => {
					if (current()) {
						this.status = status;
						this.error = undefined;
						this.surface?.requestRender();
					}
				},
				onError: (error) => {
					if (current()) {
						this.error = error;
						this.surface?.requestRender();
					}
				},
			},
			this.zBase,
			this.details.args ?? [],
			this.socket,
		);
		this.socket = undefined;
		this.producer.start();
		if (this.sync) this.producer.setViewport(this.sync, this.zBase);
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
	focused: boolean;
	closeButton: boolean;
}

function renderPanelChrome(
	width: number,
	theme: Theme,
	args: PanelChromeArgs,
): string[] {
	const innerWidth = Math.max(1, width - 2);
	// Border color tracks focus state (matches terminal-surface-demo). Border
	// cell-color when focused → accent; otherwise → border. Plus a [focused]
	// suffix in the title so it's legible even when colors are subtle.
	const borderColor: "accent" | "border" = args.focused ? "accent" : "border";
	const row = (content: string) =>
		theme.fg(borderColor, "│") +
		fitCellText(content, innerWidth) +
		theme.fg(borderColor, "│");
	const lines: string[] = [];
	const focusedSuffix = args.focused ? " [focused]" : "";
	const title = ` 🐈 Katzensteg · ${args.mode} · ${args.profile} · ${args.sizeName}${focusedSuffix}`;
	const status = args.error
		? theme.fg("error", ` ${args.error}`)
		: theme.fg("dim", ` ${args.status}`);
	const rectLine = args.rect
		? ` rect ${`${args.rect.bounds.y},${args.rect.bounds.x} ${args.rect.bounds.height}x${args.rect.bounds.width}`} viewport ${formatRect(args.viewport)} z=${args.zBase}`
		: " waiting for rect";
	const bodyRows = Math.max(2, args.panelRows - FRAME_OVERHEAD_ROWS);
	lines.push(
		theme.fg(
			borderColor,
			`╭${"─".repeat(Math.max(0, innerWidth - 1))}${args.closeButton ? "×" : "─"}╮`,
		),
	);
	lines.push(row(theme.fg("accent", title)));
	lines.push(row(args.mode === "layout" ? theme.fg("dim", rectLine) : status));
	for (let i = 0; i < bodyRows; i++) lines.push(row(""));
	lines.push(theme.fg(borderColor, `╰${"─".repeat(innerWidth)}╯`));
	return lines;
}

function createProducer(
	mode: PanelMode,
	profile: string,
	callbacks: ProducerCallbacks,
	zBase: number,
	args: string[] = [],
	socket?: Socket,
): ProducerConnection {
	return mode === "live"
		? new KatzenstegProducer(profile, callbacks, zBase, args, socket)
		: new LayoutOnlyProducer(callbacks);
}

interface ProducerCallbacks {
	onClosed?: () => void;
	onFrame?: (batch: FrameBatch) => void;
	onDetached?: (message: DetachedMessage) => void;
	onStatus: (status: string) => void;
	onError?: (error: string) => void;
}

interface ProducerConnection {
	readonly game?: GameInteraction;
	readonly ready?: boolean;
	start(): void;
	setViewport(sync: ViewportSync, zBase: number): void;
	sendInput(message: object): void;
	stop(reason: string): void;
}

class LayoutOnlyProducer implements ProducerConnection {
	private latestSync: ViewportSync | undefined;
	private readonly callbacks: ProducerCallbacks;

	constructor(callbacks: ProducerCallbacks) {
		this.callbacks = callbacks;
	}

	start(): void {
		debugLog("producer.layout.start");
		this.callbacks.onStatus("layout-only");
	}

	setViewport(sync: ViewportSync): void {
		if (sameSync(this.latestSync, sync)) return;
		this.latestSync = sync;
		debugLog(
			`producer.layout.viewport ${formatRect(sync.rect)} clip=${formatRect(sync.clip)}`,
		);
		this.callbacks.onStatus(`layout viewport ${formatRect(sync.rect)}`);
	}

	sendInput(message: object): void {
		debugLog(`producer.layout.input ${JSON.stringify(message)}`);
	}

	stop(reason: string): void {
		debugLog(`producer.layout.stop reason=${reason}`);
	}
}

export class KatzenstegProducer implements ProducerConnection {
	private inputSupported = true;
	get ready(): boolean {
		return (
			!!this.control &&
			this.attached &&
			!this.control.destroyed &&
			!this.control.writableEnded
		);
	}
	readonly game = new GameInteraction({
		inputSupported: () => this.inputSupported,
		observe: (signal) => this.observe(signal),
		input: (message) => {
			if (!this.inputSupported)
				throw new Error("Observation-only source: input is unsupported");
			if (!this.ready) throw new Error("Game panel is not attached");
			this.sendInput(message);
		},
	});
	private observationId = 0;
	private pendingObservations = new Map<
		number,
		{ finish: (message?: Record<string, unknown>, error?: Error) => void }
	>();

	private observe(signal: AbortSignal): Promise<Observation | undefined> {
		signal.throwIfAborted();
		if (!this.ready)
			return Promise.reject(new Error("Game panel is not attached yet"));
		const id = ++this.observationId;
		const snapshotPath = path.join(this.uploadDir, `observation-${id}.rgba`);
		return new Promise((resolve, reject) => {
			const abort = () => finish(undefined, new Error("Observation cancelled"));
			const timer = setTimeout(
				() =>
					finish(
						undefined,
						new Error(
							"Producer did not answer observation request; it may still be starting, have exited, or need rebuilding",
						),
					),
				2000,
			);
			const finish = (message?: Record<string, unknown>, error?: Error) => {
				clearTimeout(timer);
				signal.removeEventListener("abort", abort);
				this.pendingObservations.delete(id);
				try {
					if (error) throw error;
					if (message?.error === "NoFrame") {
						resolve(undefined);
						return;
					}
					if (message?.error) throw new Error(String(message.error));
					const width = Number(message?.width),
						height = Number(message?.height);
					const frameId = Number(message?.frame_id),
						timestampMs = Number(message?.timestamp_ms);
					if (
						!Number.isSafeInteger(frameId) ||
						frameId < 1 ||
						!Number.isSafeInteger(timestampMs)
					)
						throw new Error("Invalid observation metadata");
					resolve(
						rgbaPng(width, height, readFileSync(snapshotPath)).then((png) => ({
							width,
							height,
							frameId,
							timestampMs,
							png,
						})),
					);
				} catch (error) {
					reject(error);
				} finally {
					rmSync(snapshotPath, { force: true });
				}
			};
			this.pendingObservations.set(id, { finish });
			signal.addEventListener("abort", abort, { once: true });
			this.writeControl(
				`${JSON.stringify({ type: "observe", window_id: WINDOW_ID, request_id: id, path: snapshotPath })}\n`,
			);
		});
	}
	private cancelAgent(reason: string): void {
		this.game.cancel(reason);
		for (const pending of [...this.pendingObservations.values()])
			pending.finish(undefined, new Error(reason));
	}

	private readonly profile: string;
	private readonly callbacks: ProducerCallbacks;
	private zBase: number;
	private readonly args: string[];
	private child: ChildProcessWithoutNullStreams | undefined;
	private get control(): Writable | undefined {
		return this.socket ?? this.child?.stdin;
	}
	private started = false;
	private carry = "";
	private attached = false;
	private latestSyncSent: ViewportSync | undefined;
	private killTimer: NodeJS.Timeout | undefined;
	private readonly uploadDir = mkdtempSync(
		path.join(os.tmpdir(), "katzensteg-pi-"),
	);
	private readonly uploadPath = path.join(this.uploadDir, "embed-upload.rgba");
	private readonly imageIds: [number, number];
	private readonly placementIds: [number, number];

	private readonly socket: Socket | undefined;

	constructor(
		profile: string,
		callbacks: ProducerCallbacks,
		zBase: number,
		args: string[] = [],
		socket?: Socket,
	) {
		this.socket = socket;
		this.profile = profile;
		this.callbacks = callbacks;
		this.zBase = zBase;
		this.args = args;
		const ranges = allocateIdRanges();
		this.imageIds = ranges.imageIds;
		this.placementIds = ranges.placementIds;
	}

	start(): void {
		if (this.started) return;
		this.started = true;
		if (this.socket) {
			const socket = this.socket;
			let finished = false;
			const closed = () => {
				if (finished) return;
				finished = true;
				this.cancelAgent("Game disconnected");
				if (this.killTimer) clearTimeout(this.killTimer);
				this.attached = false;
				rmSync(this.uploadDir, { recursive: true, force: true });
				this.callbacks.onClosed?.();
				this.callbacks.onStatus("disconnected");
			};
			socket.setEncoding("utf8");
			socket.on("data", (chunk: string) => this.onStdout(chunk));
			socket.on("error", (error) => this.callbacks.onError?.(error.message));
			socket.once("end", () => socket.destroy());
			socket.once("close", closed);
			if (socket.destroyed) closed();
			else socket.resume();
			return;
		}
		if (this.child) return;
		const bin = this.binaryPath();
		debugLog(
			`producer.live.start bin=${bin} profile=${this.profile} args=${JSON.stringify(this.args)}`,
		);
		this.callbacks.onStatus("launching");
		// Program args (after the profile) are forwarded to the launcher, which
		// appends them after the profile's own configured args.
		this.child = spawn(bin, ["--embed-jsonl", this.profile, ...this.args], {
			cwd: REPO_ROOT,
			stdio: ["pipe", "pipe", "pipe"],
			env: producerEnv(),
		});
		this.child.stdout.setEncoding("utf8");
		this.child.stderr.setEncoding("utf8");
		this.child.stdout.on("data", (chunk: string) => this.onStdout(chunk));
		this.child.stderr.on("data", (chunk: string) => this.onStderr(chunk));
		this.child.on("error", (error) => {
			this.cancelAgent("Game process failed");
			debugLog(`producer.live.error ${error.message}`);
			this.callbacks.onError?.(error.message);
		});
		this.child.on("close", (code, signal) => {
			this.cancelAgent("Game exited");
			debugLog(
				`producer.live.close code=${code ?? "null"} signal=${signal ?? "null"}`,
			);
			if (this.killTimer) clearTimeout(this.killTimer);
			rmSync(this.uploadDir, { recursive: true, force: true });
			this.child = undefined;
			this.attached = false;
			this.latestSyncSent = undefined;
			this.callbacks.onStatus(
				signal ? `exited ${signal}` : `exited ${code ?? 0}`,
			);
		});
	}

	setViewport(sync: ViewportSync, zBase: number): void {
		this.zBase = zBase;
		if (!this.control || this.control.destroyed || this.control.writableEnded) {
			debugLog(
				`producer.live.viewport skipped no child viewport=${formatRect(sync.rect)}`,
			);
			return;
		}
		if (!this.attached) {
			debugLog(
				`producer.live.attach ${formatRect(sync.rect)} clip=${formatRect(sync.clip)}`,
			);
			this.writeControl(
				makeAttachMessage({
					windowId: WINDOW_ID,
					generation: sync.generation,
					cellDimensions: sync.cellDimensions,
					rectCells: sync.rect,
					clipCells: sync.clip,
					occlusions: sync.occlusions,
					aspect: PANEL_ASPECT,
					zBase: this.zBase,
					imageIds: this.imageIds,
					placementIds: this.placementIds,
					upload: {
						profile: process.env.KATZENSTEG_OUTPUT_PROFILE === "shm" ? "shm" : "file_whole",
						path: this.uploadPath,
						highWater: DEFAULT_UPLOAD_HIGH_WATER,
					},
				}),
			);
			this.attached = true;
			this.latestSyncSent = sync;
			this.callbacks.onStatus("attached");
			return;
		}
		if (sameSync(this.latestSyncSent, sync)) {
			debugLog(`producer.live.viewport no-op ${formatRect(sync.rect)}`);
			return;
		}
		debugLog(
			`producer.live.viewport ${formatRect(sync.rect)} clip=${formatRect(sync.clip)}`,
		);
		this.writeControl(
			makeViewportMessage({
				windowId: WINDOW_ID,
				generation: sync.generation,
				cellDimensions: sync.cellDimensions,
				rectCells: sync.rect,
				clipCells: sync.clip,
				occlusions: sync.occlusions,
				aspect: PANEL_ASPECT,
				zBase: this.zBase,
			}),
		);
		this.latestSyncSent = sync;
		this.callbacks.onStatus("viewport");
	}

	sendInput(message: object): void {
		// Only the live producer needs to forward input to the actual katzensteg
		// child; layout-only is a debug stand-in. Drop silently when the child
		// is gone (panel closing) — no need to spam logs in that case.
		if (!this.ready || !this.inputSupported) return;
		if (!this.attached) return;
		this.writeControl(`${JSON.stringify(message)}\n`);
	}

	stop(reason: string): void {
		this.cancelAgent(reason);
		if (this.socket) {
			if (!this.socket.destroyed && !this.socket.writableEnded) {
				this.writeControl(makeShutdownMessage());
				this.socket.end();
				this.killTimer = setTimeout(() => this.socket?.destroy(), 3000);
			}
			this.attached = false;
			return;
		}
		const child = this.child;
		debugLog(
			`producer.live.stop reason=${reason} child=${child ? "yes" : "no"} attached=${this.attached}`,
		);
		if (!child) return;
		if (this.killTimer) clearTimeout(this.killTimer);
		if (child.stdin && !child.stdin.destroyed) {
			// Match the WM host: shutdown is the close primitive. The runtime handles
			// shutdown by flushing producer-owned delete placements and then emitting
			// a detached ack. Sending a separate detach first can make close ordering
			// harder to reason about and is unnecessary for panel teardown.
			this.writeControl(makeShutdownMessage());
			child.stdin.end();
		}
		if (child.exitCode === null && child.signalCode === null && !child.killed) {
			// The launcher owns child-group cleanup: 1500 ms grace, then TERM
			// and KILL 250 ms later. Do not interrupt that escalation.
			this.killTimer = setTimeout(() => {
				debugLog(
					`producer.live.stop timeout exitCode=${child.exitCode ?? "null"} signal=${child.signalCode ?? "null"} killed=${child.killed}`,
				);
				if (
					child.exitCode === null &&
					child.signalCode === null &&
					!child.killed
				)
					child.kill("SIGTERM");
			}, 3000);
		}
		this.attached = false;
		this.latestSyncSent = undefined;
	}

	private writeControl(message: string): void {
		const control = this.control;
		if (!control || control.destroyed || control.writableEnded) {
			debugLog(`producer.live.write skipped ${message.trim()}`);
			return;
		}
		debugLog(`producer.live.write ${message.trim()}`);
		if (
			this.socket &&
			control.writableLength + Buffer.byteLength(message) > 512 * 1024
		) {
			this.socket.destroy(new Error("Host control queue exceeded 512 KiB"));
			return;
		}
		control.write(message, (error) => {
			if (error)
				debugLog(`producer.live.write callback error=${error.message}`);
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
			try {
				const reply = JSON.parse(line);
				if (reply?.type === "presentation_status") {
					this.inputSupported = reply.input_supported !== false;
					if (!this.inputSupported) this.callbacks.onStatus("observation only");
					continue;
				}
				if (reply?.type === "observation") {
					this.pendingObservations.get(reply.request_id)?.finish(reply);
					continue;
				}
			} catch {
				/* The existing graphics parser reports malformed output. */
			}
			let message: FrameBatch | DetachedMessage | null;
			try {
				message = parseProducerLine(line);
			} catch (error) {
				this.callbacks.onError?.(String(error));
				this.stop("protocol-error");
				return;
			}
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
			debugLog(
				`producer.live.chunk seq=${seq} profile=${this.profile} bytes=${chunk.length} lines=${lines} frames=${frames} us=${us}`,
			);
		}
	}

	private onStderr(chunk: string): void {
		const lines = chunk
			.split(/\r?\n/)
			.map((line) => line.trim())
			.filter(Boolean);
		if (lines.length === 0) return;
		const last = lines.at(-1);
		if (!last) return;
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
		KATZENSTEG_OBSERVE: "1",
	};
	if (PANEL_WINDOW_POLICY) env.KATZENSTEG_WINDOW_POLICY = PANEL_WINDOW_POLICY;
	if (PANEL_REAL_WINDOW) env.KATZENSTEG_REAL_WINDOW = PANEL_REAL_WINDOW;
	debugLog(
		`producer.env trace_blocking=${env.KATZENSTEG_TRACE_BLOCKING ?? "(unset)"} threshold_ms=${env.KATZENSTEG_TRACE_BLOCKING_THRESHOLD_MS ?? "(unset)"} window_policy=${env.KATZENSTEG_WINDOW_POLICY ?? "(profile)"} real_window=${env.KATZENSTEG_REAL_WINDOW ?? "(profile)"}`,
	);
	return env;
}

function parseMode(value: string | undefined): PanelMode {
	return value === "layout" ? "layout" : "live";
}

function fallbackPanelRowsForSize(size: SizePreset): number {
	return typeof size.height === "number" ? size.height : 20;
}

function terminalGeometry(cellDimensions: CellDimensions) {
	const cells: TerminalCells = {
		rows: process.stdout.rows || 24,
		cols: process.stdout.columns || 80,
	};
	return {
		terminal_cells: cells,
		terminal_px: {
			w: cells.cols * cellDimensions.widthPx,
			h: cells.rows * cellDimensions.heightPx,
		},
	};
}

function sameCellDimensions(a: CellDimensions, b: CellDimensions): boolean {
	return a.widthPx === b.widthPx && a.heightPx === b.heightPx;
}

function makeAttachMessage(options: AttachOptions): string {
	return `${JSON.stringify({
		type: "attach",
		window_id: options.windowId,
		presentation_generation: options.generation,
		rect_cells: options.rectCells,
		occlusion_rects: options.occlusions,
		...(options.clipCells === undefined
			? {}
			: { clip_cells: options.clipCells }),
		...terminalGeometry(options.cellDimensions),
		aspect: options.aspect,
		z_base: options.zBase,
		id_ranges: {
			image: [options.imageIds],
			placement: [options.placementIds],
		},
		upload: {
			profile: options.upload.profile,
			...(options.upload.path === undefined
				? {}
				: { path: options.upload.path }),
			high_water: options.upload.highWater,
		},
	})}\n`;
}

function makeViewportMessage(options: ViewportOptions): string {
	return `${JSON.stringify({
		type: "viewport",
		window_id: options.windowId,
		presentation_generation: options.generation,
		rect_cells: options.rectCells,
		occlusion_rects: options.occlusions,
		...(options.clipCells === undefined
			? {}
			: { clip_cells: options.clipCells }),
		...terminalGeometry(options.cellDimensions),
		aspect: options.aspect,
		z_base: options.zBase,
	})}\n`;
}

function makeShutdownMessage(): string {
	return `${JSON.stringify({ type: "shutdown" })}\n`;
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
	if (typeof message.window_id !== "string" || typeof message.seq !== "number")
		return null;
	if (
		!Number.isSafeInteger(message.presentation_generation) ||
		Number(message.presentation_generation) < 0
	) {
		throw new Error(
			"Katzensteg producer lacks presentation generations; rebuild the local producer",
		);
	}
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
		presentation_generation: Number(message.presentation_generation),
		groups: {
			deletes: groups.deletes,
			uploads: groups.uploads,
			placements: groups.placements,
			after: groups.after,
		},
	};
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isStringArray(value: unknown): value is string[] {
	return (
		Array.isArray(value) && value.every((item) => typeof item === "string")
	);
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

function sameRect(a: RectCells, b: RectCells): boolean {
	return (
		a.row === b.row && a.col === b.col && a.rows === b.rows && a.cols === b.cols
	);
}

function sameOptionalRect(
	a: RectCells | undefined,
	b: RectCells | undefined,
): boolean {
	if (!a && !b) return true;
	if (!a || !b) return false;
	return sameRect(a, b);
}

function sameSync(a: ViewportSync | undefined, b: ViewportSync): boolean {
	if (!a) return false;
	return (
		sameCellDimensions(a.cellDimensions, b.cellDimensions) &&
		sameRect(a.rect, b.rect) &&
		sameOptionalRect(a.clip, b.clip) &&
		a.generation === b.generation
	);
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
