import { spawn } from "node:child_process";
import process from "node:process";

export type Aspect = "fit" | "stretch" | "cover";
export type UploadProfile = "direct_apc" | "file_whole" | "file_offset_ring";
export type IdRange = [number, number];

export interface RectCells {
  row: number;
  col: number;
  rows: number;
  cols: number;
}

export interface AttachOptions {
  windowId: "main";
  rectCells: RectCells;
  aspect: Aspect;
  imageIds: IdRange;
  placementIds: IdRange;
  upload: {
    profile: UploadProfile;
    path?: string;
    highWater: number;
  };
}

export interface ViewportOptions {
  windowId: "main";
  rectCells: RectCells;
  aspect: Aspect;
}

export interface FrameBatch {
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

export interface Detached {
  type: "detached";
  window_id: string;
}

export function makeAttachMessage(options: AttachOptions): string {
  return JSON.stringify({
    type: "attach",
    window_id: options.windowId,
    rect_cells: options.rectCells,
    aspect: options.aspect,
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
  }) + "\n";
}

export function makeViewportMessage(options: ViewportOptions): string {
  return JSON.stringify({
    type: "viewport",
    window_id: options.windowId,
    rect_cells: options.rectCells,
    aspect: options.aspect,
  }) + "\n";
}

export function makeDetachMessage(windowId: "main" = "main"): string {
  return JSON.stringify({
    type: "detach",
    window_id: windowId,
  }) + "\n";
}

export function makeShutdownMessage(): string {
  return JSON.stringify({
    type: "shutdown",
  }) + "\n";
}

export function parseFrameBatchLine(line: string): FrameBatch | null {
  let message: unknown;
  try {
    message = JSON.parse(line);
  } catch {
    return null;
  }
  if (!isRecord(message)) return null;
  if (message.type !== "frame_batch") return null;
  if (typeof message.window_id !== "string") return null;
  if (typeof message.seq !== "number") return null;
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
    groups: {
      deletes: groups.deletes,
      uploads: groups.uploads,
      placements: groups.placements,
      after: groups.after,
    },
  };
}

export function parseDetachedLine(line: string): Detached | null {
  let message: unknown;
  try {
    message = JSON.parse(line);
  } catch {
    return null;
  }
  if (!isRecord(message)) return null;
  if (message.type !== "detached") return null;
  if (typeof message.window_id !== "string") return null;
  return {
    type: "detached",
    window_id: message.window_id,
  };
}

export function orderedTerminalChunks(batch: FrameBatch): string[] {
  return [
    ...batch.groups.deletes,
    ...batch.groups.uploads,
    ...batch.groups.placements,
    ...batch.groups.after,
  ];
}

export async function runEmbedHost(
  argv: string[],
  options: AttachOptions,
): Promise<number> {
  if (argv.length === 0) throw new Error("missing producer argv");

  const child = spawn(argv[0], argv.slice(1), {
    stdio: ["pipe", "pipe", "inherit"],
  });

  child.stdin.write(makeAttachMessage(options));
  child.stdin.end();

  let carry = "";
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk: string) => {
    carry += chunk;
    for (;;) {
      const newline = carry.indexOf("\n");
      if (newline < 0) break;
      const line = carry.slice(0, newline);
      carry = carry.slice(newline + 1);
      writeFrameBatchLine(line);
    }
  });

  return await new Promise<number>((resolve, reject) => {
    child.on("error", reject);
    child.on("close", (code, signal) => {
      if (carry.length > 0) writeFrameBatchLine(carry);
      resolve(signal === null ? code ?? 1 : 1);
    });
  });
}

function writeFrameBatchLine(line: string): void {
  const batch = parseFrameBatchLine(line);
  if (batch === null) return;
  for (const chunk of orderedTerminalChunks(batch)) {
    process.stdout.write(chunk);
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) &&
    value.every((item) => typeof item === "string");
}

if (import.meta.main) {
  const separator = process.argv.indexOf("--");
  const producerArgv = separator >= 0
    ? process.argv.slice(separator + 1)
    : ["./zig-out/bin/katzensteg", "--embed-jsonl", "probe.embed.basic_sdl"];

  const exitCode = await runEmbedHost(producerArgv, {
    windowId: "main",
    rectCells: { row: 1, col: 1, rows: 24, cols: 80 },
    aspect: "fit",
    imageIds: [100000, 199999],
    placementIds: [200000, 299999],
    upload: { profile: "direct_apc", highWater: 10 * 1024 * 1024 },
  });
  process.exitCode = exitCode;
}
