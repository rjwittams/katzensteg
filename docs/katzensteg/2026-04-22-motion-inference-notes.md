# Katzensteg Motion Inference / Scene Explanation Notes

This note captures a more ambitious direction beyond basic file transport and tile caching.

## Core idea

Instead of treating each frame only as a raw pixel upload problem, try to explain a new frame in terms of:

- reused cached content
- translated prior content
- moved placements
- newly exposed regions
- genuinely new pixel uploads

This pushes Katzensteg toward a scene-reconstruction / frame-explanation system rather than just a framebuffer mirror.

## Why this seems promising

Many emulator and 2D game workloads have strong structure:

- scrolling tilemaps
- static HUD layers
- small moving sprites over stable backgrounds
- parallax layers
- repeated UI chrome and glyphs

If we can detect these patterns, we may be able to replace a large amount of raw upload work with:

- placement reuse
- placement movement
- tile cache reuse
- narrow patch uploads only where needed

## Especially interesting target: scrolling / translation

A very common 2D pattern is that a frame is mostly:

- the previous frame translated by `(dx, dy)`
- plus some residual updates at the newly exposed edge(s) and moving entities

That suggests a potentially high-value optimization path:

1. detect dominant translation(s)
2. preserve / move cached placements accordingly
3. upload only the residual changes

This feels especially attractive for:

- side-scrollers
- top-down camera pans
- RPG maps
- parallax backgrounds
- tilemap-heavy consoles and handhelds

## Non-ML first approach

The preferred direction is to push deterministic / classical methods as far as possible before involving ML.

That means exploring:

- block matching
- tile-hash shifts
- phase-correlation-like ideas
- dominant-motion estimation
- region segmentation into static / translated / changed parts
- cost-based optimization over candidate explanations

A good reference area when the time comes may be:

- **ffmpeg / video codec motion estimation ideas**

not because the problem is identical, but because it is likely to contain useful efficient and SIMD-friendly ideas for:

- motion search
- block matching
- hierarchical search
- cost heuristics

## Relationship to tile/slab caching

Motion inference combines naturally with a tile/slab cache.

For example:

- cached background tiles remain valid
- a layer translation can be represented as moving placements / changing source-region interpretation
- only new edge bands or genuinely changed blocks need new cache insertions

So this is not a separate system from caching so much as a smarter policy sitting on top of it.

## A plausible staged roadmap

### Stage 1: simple deterministic translation detection

Try to infer one dominant frame translation.

Output model:

- move prior placements if possible
- patch exposed strips / residual changed tiles

This alone may be highly valuable.

### Stage 2: multiple-region / layer-aware motion

Try to detect that different large regions have different behavior, for example:

- static HUD
- translated playfield
- independently moving sprite bands

This begins to look like a crude inferred scene graph.

### Stage 3: cost-based frame explanation

Given candidate explanations of a frame, choose the cheapest one under a renderer-aware cost model.

Possible primitives in the explanation set:

- reuse cached tile
- translate prior region
- merge adjacent reused regions
- split region into smaller changed pieces
- upload fresh content

## DP / solver intuition

This feels like a dynamic-programming / search problem.

The task is effectively:

> find a low-cost explanation of the current frame from reusable old content and a minimum amount of fresh content.

The cost model might include:

- uploaded bytes
- number of placements
- placement churn
- estimated terminal overhead
- cache pressure / eviction cost
- latency of the chosen strategy

The exact solver is unknown, but interesting options might include:

- dynamic programming
- beam search
- greedy heuristics with local repair
- region-tree optimization

This is deliberately vague, but the "frame explanation" framing feels important.

## Hierarchical decomposition

There is also a speculative idea that a hierarchical region structure may be a better fit than only fixed tiles.

For example:

- large stable regions should stay large
- changed subregions should be recursively split
- stable coarse blocks should avoid exploding placement count

This suggests quadtree-like or trie-like decomposition ideas.

Potential benefit:

- preserve large reusable structures when possible
- descend to smaller pieces only where change requires it

This is not yet a proved design, just an intuition worth preserving.

## ML later, not first

There is a possible later "did they really do that?" direction where:

- recorded traces are analyzed offline
- a slower DP / search solver finds near-optimal explanations
- those explanations become training data
- a relatively small model learns to propose good scene decompositions quickly

But the current preferred philosophy is:

1. get as far as possible with deterministic / classical methods
2. use ML only if it clearly unlocks something beyond that

## Why an offline oracle is appealing

A slower solver could still be extremely useful even if it is not live-capable.

It could:

- validate whether better explanations exist
- generate training data for heuristics or ML
- help tune cost models
- provide a benchmark for how far the online system is from optimal

So an offline "optimal slowly" pipeline may be valuable regardless of whether ML ever ships.

## Potential future output profiles impacted

If this line of work becomes real, future output profiles may not just differ by transport medium but also by explanation strategy:

- `file_whole`
- `file_offset_ring`
- `file_tile_cache`
- `file_tile_cache_motion`
- `file_tile_cache_motion_hierarchical`

## Short conclusion

The particularly exciting next-gen idea here is:

> detect translations / scrolling and explain new frames as moved old content plus minimal residual uploads.

This seems common enough in real 2D workloads that it could become a major efficiency win.

The recommended direction is to start with classical motion estimation / decomposition ideas — potentially borrowing inspiration from ffmpeg and video-codec motion search — and only consider ML later if a deterministic system plateaus.
