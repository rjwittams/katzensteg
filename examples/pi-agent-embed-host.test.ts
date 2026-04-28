import {
  makeAttachMessage,
  orderedTerminalChunks,
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
