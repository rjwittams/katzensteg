import assert from "node:assert/strict";
import test from "node:test";
import type { ToolDefinition } from "@earendil-works/pi-coding-agent";
import { GameInteraction, rgbaPng } from "./katzensteg-game.js";
import { registerGameTools } from "./katzensteg-tools.js";

test("registered tools select a panel and return image content to the model", async () => {
	const tools = new Map<string, Pick<ToolDefinition, "execute">>();
	const game = new GameInteraction({
		observe: async () => ({
			frameId: 3,
			timestampMs: 100,
			width: 1,
			height: 1,
			png: rgbaPng(1, 1, Buffer.from([1, 2, 3, 255])),
		}),
		input: () => {},
	});
	registerGameTools(
		{
			registerTool: (tool) => {
				tools.set(tool.name, tool);
			},
		},
		() => [{ id: "panel-1", profile: "mi2", game }],
		async () => "panel-1",
	);
	assert.deepEqual(
		[...tools.keys()],
		[
			"katzensteg_open",
			"katzensteg_panels",
			"katzensteg_observe",
			"katzensteg_act",
		],
	);
	const observe = tools.get("katzensteg_observe");
	assert.ok(observe);
	// The implementation does not use an extension context.
	const result = await observe.execute(
		"test",
		{},
		undefined,
		undefined,
		undefined as never,
	);
	assert.equal(result.content[1].type, "image");
	assert.equal((result.details as { panel: string }).panel, "panel-1");
});

test("multiple panels require explicit selection", async () => {
	const tools = new Map<string, Pick<ToolDefinition, "execute">>();
	const game = new GameInteraction({
		observe: async () => undefined,
		input: () => {},
	});
	registerGameTools(
		{
			registerTool: (tool) => {
				tools.set(tool.name, tool);
			},
		},
		() => [
			{ id: "panel-1", profile: "mi2", game },
			{ id: "panel-2", profile: "sonic", game },
		],
		async () => "panel-3",
	);
	const observe = tools.get("katzensteg_observe");
	assert.ok(observe);
	await assert.rejects(
		observe.execute("test", {}, undefined, undefined, undefined as never),
		/panel-1.*panel-2/,
	);
});

test("open tool forwards profile and argv to the shared opener and rejects headless calls", async () => {
	const tools = new Map<string, Pick<ToolDefinition, "execute">>();
	const calls: { profile: string; args: string[] }[] = [];
	registerGameTools(
		{
			registerTool: (tool) => {
				tools.set(tool.name, tool);
			},
		},
		() => [],
		async (_ctx, profile, args) => {
			calls.push({ profile, args });
			return "panel-9";
		},
	);
	const open = tools.get("katzensteg_open");
	assert.ok(open);
	const params = {
		profile: "mi2",
		args: ["--path", "~/games/Monkey Island 2"],
	};
	const result = await open.execute("test", params, undefined, undefined, {
		hasUI: true,
	} as never);
	assert.deepEqual(calls, [params]);
	assert.deepEqual(result.details, { panel: "panel-9", profile: "mi2" });
	await assert.rejects(
		open.execute("test", params, undefined, undefined, {
			hasUI: false,
		} as never),
		/interactive/,
	);
	const abort = new AbortController();
	abort.abort();
	await assert.rejects(
		open.execute("test", params, abort.signal, undefined, {
			hasUI: true,
		} as never),
	);
	assert.equal(calls.length, 1);
});
