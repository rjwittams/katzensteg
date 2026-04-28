# Katzensteg Logging Plan

Katzensteg should use Zig's `std.log` as the Zig-side logging frontend, but keep a Katzensteg-owned file-only sink behind it.

The immediate problem is duplicated formatting policy. Many call sites currently include string prefixes such as `katzensteg:` and `katzensteg-trace:`. That spreads presentation choices through runtime, SDL, GL, frame-builder, and config code. `std.log` already provides the useful frontend pieces: scoped loggers, level filtering, and a root-provided `logFn`.

## Direction

- Define `std_options.logFn` in Katzensteg Zig roots that need logging.
- Route that `logFn` to the existing preload-safe file sink in `src/katzensteg/log.zig`.
- Use scoped loggers at call sites, for example `std.log.scoped(.sdl)` or `std.log.scoped(.runtime)`.
- Keep output file-only for preload/runtime code. Do not use the default `std.log` stderr behavior there.
- Keep high-volume tracing behind runtime/env gates such as `KATZENSTEG_TRACE_SDL`; `std.log` compile-time levels are useful but do not replace runtime trace toggles.
- Keep `writeOnce`-style suppression as Katzensteg-owned behavior; `std.log` does not provide this.

## Shared Library Boundary

`std.log` configuration is tied to the Zig compilation root, not the whole process. The Katzensteg preload library is built as its own Zig root, so its `std_options.logFn` affects Katzensteg's Zig code inside that shared object. If Katzensteg is preloaded into another Zig program, the host program's own `std.log` calls still use the host's separately compiled root options.

The `logFn` should not be exported as an ABI symbol, should not call `std.log` recursively, and should not call APIs that Katzensteg interposes. File open/write plus a mutex is the right shape.

## Non-Zig Code

C-only pieces such as the Vulkan layer and Linux symbol resolvers cannot call `std.log` directly. They can either keep small local logging helpers or later call exported Katzensteg C logging shims if the duplication becomes painful. Do not force this through the Zig `std.log` migration unless there is a clear benefit.

## Migration Shape

Do this incrementally:

1. Add the central `std.log` sink while preserving the current `Logger` API.
2. Move one module at a time from `logger.writeFmt("katzensteg: ...")` to scoped `std.log` calls or thin wrappers.
3. Leave very hot trace paths explicitly gated before formatting.
4. Only consider JSON/logfmt output after the plain file format is centralized and stable.
