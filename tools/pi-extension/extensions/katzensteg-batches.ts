import type { SurfaceRenderContext } from "@earendil-works/pi-tui";

export interface FrameBatch {
	type: "frame_batch";
	window_id: string;
	seq: number;
	presentation_generation: number;
	groups: {
		deletes: string[];
		uploads: string[];
		placements: string[];
		after: string[];
	};
}

/** Pending output, not a replay cache. Full-frame producers restore lost images. */
export class PendingBatches {
	private pending: FrameBatch[] = [];
	private bytes = 0;
	private lastSeq = -1;
	private generation = 0;
	private clearPlacements = false;
	private closed = false;
	private readonly images = new Set<number>();
	private readonly retainedImages = new Set<number>();
	private readonly deferredDeletes = new Set<string>();
	private deferredBytes = 0;

	setGeneration(generation: number): void {
		if (generation === this.generation) return;
		if (!this.clearPlacements)
			for (const id of this.images) this.retainedImages.add(id);
		this.generation = generation;
		this.clearPlacements = true;
	}

	enqueue(batch: FrameBatch): void {
		if (this.closed) return;
		if (batch.seq <= this.lastSeq)
			throw new Error("Out-of-order Katzensteg batch");
		const bytes = Object.values(batch.groups)
			.flat()
			.reduce((n, chunk) => n + chunk.length, 0);
		// A stalled host must stop its producer rather than grow an unbounded queue
		// or discard uploads still referenced by later batches.
		if (this.bytes + this.deferredBytes + bytes > 64 * 1024 * 1024)
			throw new Error("Katzensteg output exceeded the pending-write limit");
		this.lastSeq = batch.seq;
		this.bytes += bytes;
		this.pending.push(batch);
	}

	flush(frame: SurfaceRenderContext, visible: boolean): void {
		if (this.closed) return;
		if (frame.disposed) {
			frame.write(this.dispose());
			return;
		}
		const chunks: string[] = [];
		const replacementReady = this.pending.some(
			(batch) =>
				batch.presentation_generation === this.generation &&
				(batch.groups.placements.length > 0 ||
					[...batch.groups.deletes, ...batch.groups.after].some((chunk) =>
						this.retiresRetainedImage(chunk),
					)),
		);
		// Keep the last visible frame until replacement placements can be sent
		// in the same write, or the current generation explicitly retires it.
		// Fully occluded artwork produces deletes without placements, even when
		// aspect-fit padding leaves some of the panel body uncovered.
		// Hidden surfaces still need immediate cleanup.
		if (this.clearPlacements && (!visible || replacementReady)) {
			for (const id of this.images)
				chunks.push(`\x1b_Ga=d,d=i,i=${id},q=2\x1b\\`);
			for (const chunk of this.deferredDeletes) {
				this.trackImages(chunk);
				chunks.push(chunk);
			}
			this.deferredDeletes.clear();
			this.deferredBytes = 0;
			this.retainedImages.clear();
			this.clearPlacements = false;
		}
		for (const batch of this.pending) {
			const { deletes, uploads, placements, after } = batch.groups;
			// Consume file-backed uploads promptly. While waiting for a replacement,
			// hold retirement of pre-move images: stale frames cannot replace them.
			for (const chunk of [
				...deletes,
				...uploads,
				...(visible && batch.presentation_generation === this.generation
					? placements
					: []),
				...after,
			]) {
				if (
					this.clearPlacements &&
					visible &&
					this.retiresRetainedImage(chunk)
				) {
					if (!this.deferredDeletes.has(chunk)) {
						this.deferredDeletes.add(chunk);
						this.deferredBytes += chunk.length;
					}
					continue;
				}
				this.trackImages(chunk);
				chunks.push(chunk);
			}
		}
		this.pending = [];
		this.bytes = 0;
		if (chunks.length > 0) frame.write(chunks.join(""));
	}

	/** Called in the final surface callback, while terminal writes remain legal. */
	dispose(): string {
		this.closed = true;
		this.pending = [];
		this.bytes = 0;
		const output = [...this.images]
			.map((id) => `\x1b_Ga=d,d=I,i=${id},q=2\x1b\\`)
			.join("");
		this.images.clear();
		this.retainedImages.clear();
		this.deferredDeletes.clear();
		this.deferredBytes = 0;
		return output;
	}

	private retiresRetainedImage(chunk: string): boolean {
		return [...chunk.matchAll(/\x1b_G([^;\x1b]*)(?:;[^\x1b]*)?\x1b\\/g)].some(
			(match) => {
				const params = new Map(
					match[1].split(",").map((pair) => {
						const [key = "", value = ""] = pair.split("=");
						return [key, value] as const;
					}),
				);
				return (
					params.get("a") === "d" &&
					this.retainedImages.has(Number(params.get("i")))
				);
			},
		);
	}

	private trackImages(chunk: string): void {
		for (const command of chunk.split("\x1b_G").slice(1)) {
			const params = new Map(
				(command.split(";")[0]?.split("\x1b")[0] ?? "")
					.split(",")
					.map((pair) => {
						const [key = "", value = ""] = pair.split("=");
						return [key, value] as const;
					}),
			);
			const id = Number(params.get("i"));
			if (!Number.isInteger(id) || id <= 0) continue;
			if (params.get("a") === "d" && params.get("d") === "I")
				this.images.delete(id);
			else if (params.get("a") === "t" || params.get("a") === "p")
				this.images.add(id);
		}
	}
}
