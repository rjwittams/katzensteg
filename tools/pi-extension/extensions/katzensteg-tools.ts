import { Type } from "@earendil-works/pi-ai";
import {
	defineTool,
	type ExtensionAPI,
	type ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import type { GameInteraction, Observation } from "./katzensteg-game.js";

export interface GamePanel {
	id: string;
	profile: string;
	game: GameInteraction;
}
export function registerGameTools(
	pi: Pick<ExtensionAPI, "registerTool">,
	panels: () => GamePanel[],
	openPanel: (
		ctx: ExtensionContext,
		profile: string,
		args: string[],
	) => Promise<string>,
): void {
	pi.registerTool(
		defineTool({
			name: "katzensteg_open",
			label: "Open game panel",
			description:
				"Open a floating game panel using the same launcher and UI as /katzensteg-panel open. Supply a Katzensteg profile such as mi2 and optional program arguments. Returns the panel ID; the game may still be starting. Use katzensteg_panels to check availability before observing or acting.",
			parameters: Type.Object({
				profile: Type.String({ minLength: 1 }),
				args: Type.Optional(Type.Array(Type.String())),
			}),
			async execute(_id, params, signal, _update, ctx) {
				signal?.throwIfAborted();
				if (!ctx.hasUI)
					throw new Error("Opening a game panel requires an interactive pi UI");
				const panel = await openPanel(ctx, params.profile, params.args ?? []);
				return {
					content: [
						{
							type: "text",
							text: `Opened ${params.profile} in ${panel}. The game may still be starting.`,
						},
					],
					details: { panel, profile: params.profile },
				};
			},
		}),
	);
	const select = (id?: string): GamePanel => {
		const available = panels();
		const panel = id
			? available.find((p) => p.id === id)
			: available.length === 1
				? available[0]
				: undefined;
		if (!panel)
			throw new Error(
				`Choose an open live panel. Available: ${available.map((p) => `${p.id} (${p.profile})`).join(", ") || "none; use katzensteg_open first"}`,
			);
		return panel;
	};
	const result = (
		panel: GamePanel,
		frame: Observation,
		afterFrame?: number,
	) => {
		const details = {
			panel: panel.id,
			profile: panel.profile,
			frameId: frame.frameId,
			timestampMs: frame.timestampMs,
			width: frame.width,
			height: frame.height,
			...(afterFrame === undefined
				? {}
				: { newerFrame: frame.frameId > afterFrame }),
		};
		return {
			content: [
				{
					type: "text" as const,
					text: `${JSON.stringify(details)}\nCoordinates are zero-based pixels in this full game image. A newer frame does not guarantee the game has finished responding.`,
				},
				{
					type: "image" as const,
					data: frame.png.toString("base64"),
					mimeType: "image/png",
				},
			],
			details,
		};
	};
	pi.registerTool(
		defineTool({
			name: "katzensteg_panels",
			label: "Game panels",
			description:
				"List live Katzensteg game panels available for observation and input. Panels still starting are omitted. Open games using katzensteg_open.",
			parameters: Type.Object({}),
			async execute() {
				const available = panels().map(({ id, profile }) => ({ id, profile }));
				return {
					content: [{ type: "text", text: JSON.stringify(available) }],
					details: { panels: available },
				};
			},
		}),
	);
	pi.registerTool(
		defineTool({
			name: "katzensteg_observe",
			label: "Observe game",
			description:
				"Capture the full game image from an open Katzensteg panel, independent of terminal clipping. Supports SDL renderer profiles such as mi2. Optionally wait for a frame newer than afterFrame; a paused game may return the same frame on timeout.",
			parameters: Type.Object({
				panel: Type.Optional(Type.String()),
				afterFrame: Type.Optional(Type.Integer({ minimum: 0 })),
				timeoutMs: Type.Optional(Type.Integer({ minimum: 0, maximum: 5000 })),
			}),
			async execute(_id, params, signal) {
				const panel = select(params.panel);
				return result(
					panel,
					await panel.game.observe(params, signal),
					params.afterFrame,
				);
			},
		}),
	);
	const pointer = (type: "move" | "click") =>
		Type.Object({
			type: Type.Literal(type),
			x: Type.Integer({ minimum: 0 }),
			y: Type.Integer({ minimum: 0 }),
			button: Type.Optional(
				Type.Union([
					Type.Literal("left"),
					Type.Literal("middle"),
					Type.Literal("right"),
				]),
			),
		});
	pi.registerTool(
		defineTool({
			name: "katzensteg_act",
			label: "Act in game",
			description:
				"Perform up to 16 ordered actions in an open game panel and return an observation. Move/click coordinates use full screenshot pixels. Keys are taps: printable ASCII, arrows, enter, escape, space, tab, backspace, f1–f8. Wait at most 10 seconds total. Human interaction cancels agent control; held mouse buttons are released on cancellation. Observe before choosing coordinates.",
			parameters: Type.Object({
				panel: Type.Optional(Type.String()),
				actions: Type.Array(
					Type.Union([
						pointer("move"),
						pointer("click"),
						Type.Object({ type: Type.Literal("key"), key: Type.String() }),
						Type.Object({
							type: Type.Literal("wait"),
							ms: Type.Integer({ minimum: 0, maximum: 5000 }),
						}),
					]),
					{ minItems: 1, maxItems: 16 },
				),
			}),
			async execute(_id, params, signal) {
				const panel = select(params.panel);
				const observation = result(
					panel,
					await panel.game.act(params.actions, signal),
				);
				const actions = params.actions.map((action) => {
					switch (action.type) {
						case "move":
							return `Moved pointer to (${action.x}, ${action.y})`;
						case "click":
							return `Clicked ${action.button ?? "left"} at (${action.x}, ${action.y})`;
						case "key":
							return `Pressed ${JSON.stringify(action.key)}`;
						case "wait":
							return `Waited ${action.ms} ms`;
					}
				});
				return {
					...observation,
					content: [
						{ type: "text" as const, text: actions.join("\n") },
						...observation.content,
					],
					details: { ...observation.details, actions: params.actions },
				};
			},
		}),
	);
}
