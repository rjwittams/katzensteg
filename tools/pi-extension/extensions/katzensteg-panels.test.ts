import assert from "node:assert/strict";
import test from "node:test";
import type {
	ExtensionAPI,
	ExtensionCommandContext,
	ToolDefinition,
} from "@earendil-works/pi-coding-agent";
import type { Component, OverlayOptions } from "@earendil-works/pi-tui";

test("floating panels coexist at separate depths and close independently", async () => {
	const previousMode = process.env.KATZENSTEG_PANEL_MODE;
	process.env.KATZENSTEG_PANEL_MODE = "layout";
	const { default: extension } = await import("./katzensteg-panel.js");
	if (previousMode === undefined) delete process.env.KATZENSTEG_PANEL_MODE;
	else process.env.KATZENSTEG_PANEL_MODE = previousMode;
	let command:
		| ((args: string, ctx: ExtensionCommandContext) => Promise<void>)
		| undefined;
	let shutdown: (() => void) | undefined;
	let raises = 0;
	const tools = new Map<string, ToolDefinition>();
	const panels: {
		component: Component;
		closed: boolean;
		options: OverlayOptions;
	}[] = [];
	const custom: ExtensionCommandContext["ui"]["custom"] = (factory, options) =>
		new Promise((resolve) => {
			void Promise.resolve(
				factory(
					{
						trackSurface: () => ({
							onGeometryChange: (callback: (geometry: object) => void) => {
								callback({
									bounds: { x: 0, y: 0, width: 200, height: 20 },
									clip: { x: 0, y: 0, width: 200, height: 20 },
									contentOffset: 0,
								});
							},
							onRender: () => {},
							requestRender: () => {},
							dispose: () => {},
						}),
					} as never,
					{ fg: (_color: string, text: string) => text } as never,
					undefined as never,
					(value) => {
						entry.closed = true;
						resolve(value);
					},
				),
			).then((component) => {
				entry.component = component;
				options?.onHandle?.({
					focus: () => {
						raises++;
					},
					updateOptions: () => {},
				} as never);
				panels.push(entry);
			});
			const entry = {
				component: undefined as unknown as Component,
				closed: false,
				options:
					typeof options?.overlayOptions === "function"
						? options.overlayOptions()
						: (options?.overlayOptions ?? {}),
			};
		});
	const ctx = {
		ui: { custom, notify: () => {} },
	} as unknown as ExtensionCommandContext;
	extension({
		registerTool: (tool: ToolDefinition) => {
			tools.set(tool.name, tool);
		},
		registerMessageRenderer: () => {},
		registerCommand: (
			_name: string,
			definition: { handler: typeof command },
		) => {
			command = definition.handler;
		},
		on: (_event: string, handler: () => void) => {
			shutdown = handler;
		},
	} as unknown as ExtensionAPI);
	try {
		await command!("open mi2", ctx);
		await command!("open sonic", ctx);
		assert.equal(panels.length, 2);
		assert.ok(panels.every((panel) => !panel.closed));
		const depths = panels.map((panel) =>
			Number(/z=(-?\d+)/.exec(panel.component.render(200).join("\n"))![1]),
		);
		assert.equal(depths[1] - depths[0], 10000);
		assert.notEqual(panels[0].options.offsetX, panels[1].options.offsetX);
		panels[0].component.handleMouse?.({
			type: "press",
			button: "left",
			x: 5,
			y: 5,
			screenX: 5,
			screenY: 5,
			width: 200,
			height: 20,
			shift: false,
			alt: false,
			ctrl: false,
		});
		await Promise.resolve();
		assert.equal(raises, 1);
		const raisedDepth = Number(
			/z=(-?\d+)/.exec(panels[0].component.render(200).join("\n"))![1],
		);
		assert.ok(raisedDepth > depths[1]);
		await command!("close", ctx);
		assert.equal(panels[0].closed, true);
		assert.equal(panels[1].closed, false);
		await command!("open mi2", ctx);
		const opened = await tools
			.get("katzensteg_open")!
			.execute("open", { profile: "sonic" }, undefined, undefined, {
				...ctx,
				hasUI: true,
			});
		assert.equal(panels.length, 4);
		assert.match((opened.details as { panel: string }).panel, /^panel-\d+$/);
		assert.ok(panels[3].component.render(200).join("\n").includes("sonic"));
		shutdown!();
		assert.ok(panels.every((panel) => panel.closed));
	} finally {
		shutdown?.();
	}
});
