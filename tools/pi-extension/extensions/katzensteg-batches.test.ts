import assert from "node:assert/strict";
import test from "node:test";
import type { SurfaceRenderContext } from "@earendil-works/pi-tui";
import { type FrameBatch, PendingBatches } from "./katzensteg-batches.js";

const upload = "\x1b_Gq=2,a=t,t=f,i=10;L3RtcC90ZXN0\x1b\\";
const placement = "\x1b[4;2H\x1b_Ga=p,i=10,p=20;\x1b\\";
const deleted = "\x1b_Ga=d,d=I,i=10;\x1b\\";
function batch(
	seq: number,
	generation: number,
	groups: Partial<FrameBatch["groups"]> = {},
): FrameBatch {
	return {
		type: "frame_batch",
		window_id: "main",
		seq,
		presentation_generation: generation,
		groups: { deletes: [], uploads: [], placements: [], after: [], ...groups },
	};
}
function frame(writes: string[], disposed = false): SurfaceRenderContext {
	return {
		geometry: undefined,
		revision: 0,
		graphicsInvalidation: "none",
		disposed,
		write: (data) => {
			writes.push(data);
			return true;
		},
	};
}
test("writes only on flush and preserves group order", () => {
	const queue = new PendingBatches();
	const writes: string[] = [];
	queue.enqueue(
		batch(1, 0, {
			deletes: ["before"],
			uploads: [upload],
			placements: [placement],
			after: ["after"],
		}),
	);
	assert.deepEqual(writes, []);
	queue.flush(frame(writes), true);
	assert.equal(writes.join(""), `before${upload}${placement}after`);
	writes.length = 0;
	queue.flush({ ...frame(writes), graphicsInvalidation: "images" }, true);
	assert.deepEqual(writes, []); // No cached file replay on recovery.
});
test("stale placements are filtered while uploads and cleanup remain ordered", () => {
	const queue = new PendingBatches();
	const writes: string[] = [];
	queue.setGeneration(2);
	queue.enqueue(batch(1, 1, { uploads: [upload], placements: ["stale"] }));
	queue.enqueue(batch(2, 2, { placements: [placement], after: [deleted] }));
	queue.flush(frame(writes), true);
	assert.equal(writes.join(""), upload + placement + deleted);
	assert.equal(queue.dispose(), "");
});
test("movement removes old placements and final cleanup frees owned images synchronously", () => {
	const queue = new PendingBatches();
	const writes: string[] = [];
	queue.enqueue(batch(1, 0, { uploads: [upload], placements: [placement] }));
	queue.flush(frame(writes), true);
	writes.length = 0;
	queue.setGeneration(1);
	queue.flush(frame(writes), false);
	assert.match(writes.join(""), /a=d,d=i,i=10/);
	writes.length = 0;
	queue.enqueue(batch(2, 1, { uploads: [upload], placements: [placement] }));
	queue.flush(frame(writes, true), false);
	assert.match(writes.join(""), /a=d,d=I,i=10/);
	assert.ok(!writes.join("").includes("a=t"));
	queue.enqueue(batch(3, 1, { uploads: [upload] }));
	queue.flush(frame(writes), true);
	assert.equal(writes.length, 1);
});
test("out-of-order batches fail instead of corrupting resource state", () => {
	const queue = new PendingBatches();
	queue.enqueue(batch(2, 0));
	assert.throws(() => queue.enqueue(batch(1, 0)), /Out-of-order/);
});

test("visible movement keeps old placements until the replacement generation arrives", () => {
	const queue = new PendingBatches();
	const writes: string[] = [];
	queue.enqueue(batch(1, 0, { uploads: [upload], placements: [placement] }));
	queue.flush(frame(writes), true);
	writes.length = 0;
	queue.setGeneration(1);
	queue.flush(frame(writes), true);
	assert.deepEqual(writes, []);
	queue.setGeneration(2);
	queue.enqueue(batch(2, 1, { placements: ["stale"] }));
	queue.flush(frame(writes), true);
	assert.deepEqual(writes, []);
	queue.enqueue(batch(3, 2, { placements: ["replacement"] }));
	queue.flush(frame(writes), true);
	assert.equal(writes.length, 1);
	assert.match(writes[0], /a=d,d=i,i=10/);
	assert.ok(writes[0].endsWith("replacement"));
});

test("stale retirement cannot erase the visible frame while movement waits for placements", () => {
	const queue = new PendingBatches();
	const writes: string[] = [];
	queue.enqueue(batch(1, 0, { uploads: [upload], placements: [placement] }));
	queue.flush(frame(writes), true);
	writes.length = 0;
	queue.setGeneration(1);
	const nextUpload = upload.replace("i=10", "i=11");
	const nextPlacement = placement.replace("i=10", "i=11");
	queue.enqueue(
		batch(2, 0, {
			uploads: [nextUpload],
			placements: [nextPlacement],
			after: [deleted],
		}),
	);
	queue.flush(frame(writes), true);
	assert.equal(
		writes.join(""),
		nextUpload,
		"consume uploads promptly but keep the visible image",
	);
	writes.length = 0;
	queue.enqueue(batch(3, 1, { uploads: [nextUpload] }));
	queue.flush(frame(writes), true);
	assert.equal(
		writes.join(""),
		nextUpload,
		"uploads alone cannot replace the visible frame",
	);
	writes.length = 0;
	queue.enqueue(batch(4, 1, { placements: [nextPlacement] }));
	queue.flush(frame(writes), true);
	assert.equal(writes.length, 1);
	assert.ok(writes[0].includes(deleted));
	assert.ok(writes[0].endsWith(nextPlacement));
	assert.ok(!queue.dispose().includes("i=10,"));
});

for (const finish of ["hide", "dispose"] as const) {
	test(`deferred retirement is released on ${finish}, including across repeated moves`, () => {
		const queue = new PendingBatches();
		const writes: string[] = [];
		queue.enqueue(batch(1, 0, { uploads: [upload], placements: [placement] }));
		queue.flush(frame(writes), true);
		writes.length = 0;
		queue.setGeneration(1);
		const exactDelete = "\x1b_Ga=d,d=i,i=10,p=20,q=2\x1b\\";
		queue.enqueue(batch(2, 0, { deletes: [exactDelete], after: [deleted] }));
		queue.flush(frame(writes), true);
		assert.deepEqual(writes, []);
		queue.setGeneration(2);
		const unseenUpload = upload.replace("i=10", "i=12");
		const unseenDelete = deleted.replace("i=10", "i=12");
		queue.enqueue(
			batch(3, 1, { uploads: [unseenUpload], after: [unseenDelete] }),
		);
		queue.flush(frame(writes), true);
		assert.equal(
			writes.join(""),
			unseenUpload + unseenDelete,
			"unseen images retire immediately",
		);
		writes.length = 0;
		queue.flush(frame(writes, finish === "dispose"), false);
		assert.match(writes.join(""), /a=d,d=I,i=10/);
		assert.ok(!writes.join("").includes("i=12"));
		assert.equal(queue.dispose(), "");
	});
}

test("current-generation retirement clears covered artwork even when panel padding remains visible", () => {
	const queue = new PendingBatches();
	const writes: string[] = [];
	queue.enqueue(batch(1, 0, { uploads: [upload], placements: [placement] }));
	queue.flush(frame(writes), true);
	writes.length = 0;
	queue.setGeneration(1);
	// The host still sees uncovered panel cells, but the producer's aspect-fit
	// image is entirely behind the new overlay. Reprojection only emits deletes.
	const removePlacement = "\x1b_Ga=d,d=i,i=10,p=20,q=2\x1b\\";
	queue.enqueue(batch(2, 1, { deletes: [removePlacement] }));
	queue.flush(frame(writes), true);
	assert.ok(
		writes.join("").includes(removePlacement),
		"do not retain artwork over the upper panel's border",
	);
	writes.length = 0;
	queue.enqueue(batch(3, 1, { after: [deleted] }));
	queue.flush(frame(writes), true);
	assert.equal(writes.join(""), deleted);
	assert.equal(queue.dispose(), "");
});
