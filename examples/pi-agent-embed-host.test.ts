import {
  makeAttachMessage,
  makeDetachMessage,
  makeShutdownMessage,
  makeViewportMessage,
  orderedTerminalChunks,
  parseDetachedLine,
  parseFrameBatchLine,
} from "./pi-agent-embed-host.ts";

Deno.test("builds the current attach message contract", () => {
  const line = makeAttachMessage({
    windowId: "main",
    rectCells: { row: 4, col: 1, rows: 24, cols: 80 },
    aspect: "fit",
    imageIds: [100000, 199999],
    placementIds: [200000, 299999],
    upload: { profile: "direct_apc", highWater: 10 * 1024 * 1024 },
  });

  const message = JSON.parse(line);
  if (message.type !== "attach") throw new Error("expected attach message");
  if (message.window_id !== "main") throw new Error("expected main window");
  if (message.rect_cells.row !== 4) throw new Error("expected row 4");
  if (message.aspect !== "fit") throw new Error("expected fit aspect");
  if (message.id_ranges.image[0][0] !== 100000) {
    throw new Error("expected image id start");
  }
  if (message.id_ranges.placement[0][1] !== 299999) {
    throw new Error("expected placement id end");
  }
  if (message.upload.profile !== "direct_apc") {
    throw new Error("expected direct_apc upload");
  }
});

Deno.test("builds viewport and detach control messages", () => {
  const viewport = JSON.parse(makeViewportMessage({
    windowId: "main",
    rectCells: { row: 6, col: 10, rows: 20, cols: 64 },
    aspect: "cover",
  }));

  if (viewport.type !== "viewport") throw new Error("expected viewport");
  if (viewport.window_id !== "main") throw new Error("expected main window");
  if (viewport.rect_cells.col !== 10) throw new Error("expected col 10");
  if (viewport.aspect !== "cover") throw new Error("expected cover aspect");

  const detach = JSON.parse(makeDetachMessage());
  if (detach.type !== "detach") throw new Error("expected detach");
  if (detach.window_id !== "main") throw new Error("expected main window");

  const shutdown = JSON.parse(makeShutdownMessage());
  if (shutdown.type !== "shutdown") throw new Error("expected shutdown");
  if ("window_id" in shutdown) {
    throw new Error("shutdown should be session scoped");
  }
});

Deno.test("parses frame batches and preserves presentation order", async () => {
  const fixture = await Deno.readTextFile(
    "examples/pi-agent-frame-batch-fixture.jsonl",
  );
  const batch = parseFrameBatchLine(fixture.trim());
  if (batch === null) throw new Error("expected frame batch");
  if (batch.seq !== 2) throw new Error("expected seq 2");

  const chunks = orderedTerminalChunks(batch);
  if (
    chunks.join("") !==
      "\x1b_Ga=d;\x1b\\\x1b_Ga=t;\x1b\\\x1b[4;1H\x1b_Ga=p;\x1b\\\x1b[0m"
  ) {
    throw new Error("unexpected terminal chunk ordering");
  }
});

Deno.test("ignores non-frame JSONL messages", () => {
  const message = parseFrameBatchLine(
    '{"type":"hello","protocol":"katzensteg.embed_jsonl","version":1}',
  );
  if (message !== null) {
    throw new Error("hello should be ignored by the minimal host");
  }
});

Deno.test("parses detached lifecycle messages", () => {
  const detached = parseDetachedLine('{"type":"detached","window_id":"main"}');
  if (detached === null) throw new Error("expected detached");
  if (detached.window_id !== "main") throw new Error("expected main window");
  if (parseDetachedLine('{"type":"shutdown"}') !== null) {
    throw new Error("shutdown should not parse as detached");
  }
});
