# Katzensteg std.log Sink Design

## Goal

Katzensteg should use Zig's `std.log` as the Zig-side logging frontend while keeping the preload/runtime output path file-only and owned by Katzensteg.

This migration adds the central `std.log` sink, preserves the existing `Logger` API, and moves Zig-side preload/runtime logging away from repeated call-site prefixes.

## Architecture

`src/katzensteg/log.zig` remains the owner of preload-safe file logging. It keeps `Logger.write`, `Logger.writeFmt`, and `Logger.writeOnce` for compatibility, adds scoped `Logger` wrappers for modules that still receive a `Logger`, and adds a `std.log`-compatible root log function that formats a centralized line prefix and writes to the same file sink.

`src/katzensteg/preload.zig` configures its compilation root with `std_options.logFn = log.stdLogFn`. This affects Katzensteg Zig code inside the preload shared object only; host program logging remains controlled by the host's own root.

Converted modules use scoped loggers such as `std.log.scoped(.config)` or thin scoped `Logger` wrappers such as `logger.writeFmtScoped(.info, .frame_builder, ...)`. Call sites stop embedding `katzensteg:` in message strings. The sink owns the final presentation policy.

## Converted Modules

- `src/katzensteg/config.zig` uses `std.log.scoped(.config)` and no longer takes optional `Logger` parameters.
- `src/katzensteg/runtime.zig` uses `std.log.scoped(.runtime)` for runtime-owned messages.
- `src/katzensteg/whiskers_client.zig` uses `std.log.scoped(.whiskers)` and no longer stores a `Logger`.
- `src/katzensteg/intercept_sink.zig` uses `std.log.scoped(.intercept)` for ordinary messages and `Logger.writeOnceScoped` for suppression.
- `src/katzensteg/preload.zig` uses scoped SDL/GL logging while keeping trace formatting behind `KATZENSTEG_TRACE_SDL`.
- `src/katzensteg/frame_builder.zig` uses scoped `Logger` wrappers to avoid a broad signature refactor.

## Output Policy

The preload/runtime path must never fall back to stdout or stderr. The `std.log` sink must not call `std.log` recursively and must avoid APIs Katzensteg interposes. File open/write plus locking is the right shape.

`writeOnce` remains a Katzensteg-owned behavior through `Logger.writeOnce` and `Logger.writeOnceScoped`. High-volume trace paths remain explicitly gated by runtime/env checks before formatting. The preload root sets `std_options.log_level = .debug` so env-enabled trace messages are not silently compiled out.

## Non-Goals

- Do not convert launcher `std.debug.print` output; launcher output is user-facing process output, not preload runtime logging.
- Do not force C-only Vulkan or symbol resolver logging through Zig `std.log`.
- Do not introduce JSON/logfmt output yet.

## Testing

Add focused `log.zig` tests for central line formatting. Run file-level Zig tests for touched modules where practical and a build check for the preload root.
