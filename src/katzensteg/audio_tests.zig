//! Unit-test root for the SDL-independent audio pipeline.

test {
    _ = @import("audio_model.zig");
    _ = @import("audio_local_device_sink.zig");
    _ = @import("audio_byte_queue.zig");
    _ = @import("audio_process.zig");
}
