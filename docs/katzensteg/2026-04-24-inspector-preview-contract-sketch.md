# Katzensteg inspector preview contract sketch

Date: 2026-04-24
Status: draft / implementation sketch

## Goal

Add real image previews to the inspector without committing the server side to any browser-specific image transcoding stack.

Principles:
- authoritative storage stays format-aware
- browser decodes preview blobs client-side
- proxy/library/server only need to serve metadata + raw bytes
- preview API should work for embedded inspector now and future proxy/store later

## First slice

Preview first-class artifacts in this order:
1. SDL texture resource preview
2. kitty image resource preview
3. optional later: placement preview / placement overlay preview
4. optional later: strategy/intermediate artifacts (composite framebuffer, tile strips, etc.)

## Non-goals for first slice

- no server-side PNG generation as the primary path
- no attempt to expose every historical intermediate image yet
- no full persisted blob store design yet
- no generalized media pipeline beyond raw raster preview blobs

## API shape

Use two layers:

1. metadata endpoint describing how to decode a preview blob
2. raw blob endpoint returning bytes

### Metadata endpoint

Option A (resource-oriented explicit endpoint):
- `GET /resource/<kind>/<id>/preview?frame=<id>`

Where:
- `<kind>` initially: `texture | image`
- `<id>` is:
  - texture key for `texture`
  - image id for `image`
- `frame` is required for historical as-of-frame correctness

Response shape:

```json
{
  "kind": "texture",
  "id": "0xb28d2d040",
  "frame_id": 1842,
  "blob_id": "seg-7-frame-1842-texture-b28d2d040",
  "pixel_format": "rgba8",
  "width": 256,
  "height": 224,
  "stride": 1024,
  "byte_length": 229376,
  "origin": "captured_texture",
  "premultiplied_alpha": false
}
```

Field notes:
- `blob_id`: opaque stable identifier for follow-up blob fetch
- `pixel_format`: browser decoder contract, not necessarily original SDL format
- `origin`: provenance hint for UI/debugging (`captured_texture`, `kitty_image`, later `placement_crop`, `composite_intermediate`)
- `premultiplied_alpha`: explicit, avoid guessing later

### Raw blob endpoint

- `GET /blob/<blob_id>`

Response:
- `Content-Type: application/octet-stream`
- body = raw pixel bytes exactly as described by preview metadata

## First supported preview pixel formats

The preview API should expose a small browser-decoder-friendly set first.

Preferred first preview format set:
- `rgba8`
- `bgra8`

Acceptable second wave if needed:
- `rgb565`
- `rgba4444`

Recommendation for first slice:
- normalize previews to `rgba8` where practical before recording/serving preview blobs
- allow `bgra8` only if it naturally falls out of current resource capture and simplifies implementation

This keeps the browser decoder very small.

## Canonical vs preview representation

Important distinction:
- canonical historical resource record may still say original format was `RGB565`, `RGBA4444`, etc.
- preview blob may be stored as normalized `rgba8`

That is acceptable as long as:
- the inspector resource metadata keeps the real original format
- preview metadata clearly describes the preview blob format actually being served

In other words:
- resource truth != preview encoding

## Where preview blobs come from in first slice

### Texture previews

Source of truth:
- current `ResourceVersionRecord` / resource snapshot state at selected frame

Implementation sketch:
- when inspector records resource snapshots, extend live resource version state with optional preview blob reference for previewable resources
- for textures, capture normalized preview bytes from the already-converted texture pixels Katzensteg has available in frame-builder paths

Target invariant:
- `/resource/texture/<key>?frame=<id>` tells you the resource exists
- `/resource/texture/<key>/preview?frame=<id>` gives you something the browser can actually draw

### Kitty image previews

Source of truth:
- image data that Katzensteg uploaded or last associated with that kitty image id

Implementation sketch:
- when image upload happens, retain a preview blob reference for that image id in inspector-facing live state
- later resource snapshots for image resources point at that retained image preview

Target invariant:
- preview shows the actual kitty-side image content, not a synthetic placeholder

## Placement previews later

Do not block first slice on this.

Two likely future endpoints:
- `GET /resource/placement/<id>/preview?frame=<id>` → cropped raster of what that placement displays
- `GET /resource/placement/<id>/overlay?frame=<id>` → metadata/overlay for destination cells + source rect

But first slice can keep placement preview schematic.

## Browser decode contract

Client-side decoder should assume metadata is authoritative.

For first slice the browser needs only:
- `width`
- `height`
- `stride`
- `pixel_format`
- raw bytes from `/blob/<blob_id>`

Decode path:
1. fetch preview metadata
2. fetch blob bytes
3. decode into RGBA `Uint8ClampedArray`
4. create `ImageData`
5. draw onto canvas

## Suggested front-end module split

- `preview-types.ts`
  - metadata types
- `preview-codecs.ts`
  - `decodeRgba8`
  - `decodeBgra8`
  - later `decodeRgb565`, `decodeRgba4444`
- `preview-cache.ts`
  - blob + decoded-image memoization
- `preview-canvas.tsx`
  - UI component for loading / rendering / error state

## Inspector UI wiring order

1. Resource inspector right-side preview pane uses real preview endpoint
2. Bridge view texture and image thumbnails use real preview endpoint
3. Frame detail touched-texture mini previews use real preview endpoint
4. Later: mapping/placement views use real placement/image overlays

## Back-end implementation sketch against current inspector API

Minimal additive endpoints:
- `GET /resource/texture/<id>/preview?frame=<id>`
- `GET /resource/image/<id>/preview?frame=<id>`
- `GET /blob/<blob_id>`

Existing endpoints remain unchanged:
- `/frame/<id>`
- `/resources?frame=<id>`
- `/resource/<kind>/<id>?frame=<id>`

First response behavior if preview unavailable:
- metadata endpoint returns `404 {"error":"preview_unavailable"}``

## Storage/lifetime for embedded live mode

For the current bounded embedded inspector:
- preview blobs can be bounded in-memory alongside live frame/resource history
- blob ids only need to remain valid while the referenced frame/resource remains retained

For future proxy/store mode:
- same endpoint shape can map to persisted blobs

## First implementation choice recommendation

Recommended first implementation:
- store preview blobs as normalized `rgba8`
- add preview refs for texture and image resources only
- leave placement previews schematic for now
- do browser decode via canvas
- keep original resource format in normal resource metadata

This gives the inspector real images quickly without overcommitting the storage model.
