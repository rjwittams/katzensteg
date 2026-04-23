# Katzensteg File Transport Cache Notes

This note captures a more ambitious direction beyond the immediate safe file-transport fixes.

## Why this is interesting

A regular-file kitty transport does not have to be treated only as a transient upload scratch buffer.

A more powerful model is to treat the file as a **persistent image cache** that the terminal can read from repeatedly.

Instead of thinking only in terms of:

- write whole frame
- point terminal at frame bytes
- overwrite / wrap later

we can think in terms of:

- maintain a cache of reusable image regions inside a long-lived file
- upload only missing content into cache slots
- compose frames from cached regions via placements / source rects

That shifts the file from being a dumb transport buffer into a file-backed texture cache.

## Near-term file modes still needed

Before any smarter cache work, we still want correctness-first file modes:

- `file_whole`
  - likely implemented with a small rotating file set
  - avoids truncating a file while the terminal may still be reading it
- `file_offset_ring`
  - large stable file
  - no truncation in steady state
  - append / wrap only when safe enough

These are still the immediate path to making file transport reliable.

## Exciting next-gen idea: file-backed slab / tile cache

### High-level idea

Represent recent frame content as reusable cached chunks inside one or more long-lived files.

Potential approach:

- divide frames into tiles or regions
- hash them
- reuse cached regions if a tile already exists
- allocate new slots only for misses
- evict old / cold entries with an LRU-ish policy
- compose the current frame from placements pointing at cached source rects

This is conceptually closer to:

- a texture atlas cache
- a video block cache
- an MPEG-like temporal reuse system

than a simple circular upload buffer.

## Why it may work well for emulator / frontend workloads

These workloads often have strong temporal locality:

- static background areas
- repeated UI chrome
- repeated glyphs / icons
- small moving objects over stable regions
- only a minority of blocks changing per frame

A cache could reduce transport cost if many tiles can be reused across frames.

## Possible cache granularities

### 1. Whole-frame cache

Simplest possible idea:

- hash entire frame
- if identical, skip re-upload

Useful, but limited.

### 2. Fixed tile cache

Split a frame into fixed tiles, e.g.:

- 8x8
- 16x16
- 32x32

Then:

- tile hash -> cache slot
- slot contains pixel bytes in the backing file
- source rect selects the slot contents
- frame is composed from tile placements

This is likely the first serious prototype worth trying.

### 3. Hierarchical / adaptive decomposition

A more exciting but more speculative idea:

- recursively split regions only where change exists
- preserve larger blocks when they remain stable
- descend to smaller blocks only in changed areas

This suggests quadtree-like or trie-like indexing ideas, where:

- large stable regions are represented coarsely
- smaller detailed regions are used only where necessary

That could potentially be friendlier to both:

- cache hit rates
- placement counts

This is still only a design instinct, not a proven plan.

## Index structure ideas to explore later

This is intentionally vague / speculative, but worth preserving:

- slab allocator for backing file regions
- tile hash -> slot map
- LRU / clock / generational eviction
- hierarchical region identity
- trie / heap / quadtree-like region breakdown for changed areas
- coalescing adjacent cached regions into larger placements where possible

A good direction may be:

- keep the stored bytes in a slab-like backing file
- keep the lookup structure separate and memory-resident
- optimize for fast hit checks and cheap eviction bookkeeping

## Major tradeoffs / risks

This could fail or underperform if:

- placement count explodes
- the terminal is slow with many tiny placements
- hashing / diffing cost outweighs transport savings
- real workloads have less reusable locality than expected
- cache management becomes too complex for the benefit

So any exploration should be measurement-driven.

## A likely staged exploration plan

1. **Make file transport correct first**
   - safe `file_whole`
   - safe `file_offset_ring`
2. **Add instrumentation**
   - cache hit rate
   - bytes written
   - placements emitted
   - frame time impact
3. **Prototype fixed-tile cache**
   - probably 16x16 or 32x32 first
4. **Evaluate whether placement explosion is acceptable**
5. **Only then explore hierarchical decomposition**

## Suggested future output profiles

If this direction becomes real, it may want separate output profiles beyond today's simple transport distinction:

- `direct_apc`
- `file_whole`
- `file_offset_ring`
- `file_tile_cache`
- `file_tile_cache_hierarchical`

Those should still be chosen from a combination of:

- runtime probing
- known compatibility data
- workload / debug preferences

## Short conclusion

The simple ring-buffer file transport is the immediate practical step.

But the more exciting long-term direction is:

> treat the backing file as a persistent cached image store and compose frames from reused cached regions instead of re-uploading every frame wholesale.

That idea feels promising enough to preserve explicitly, even though the exact cache/index shape is not yet proved out.
