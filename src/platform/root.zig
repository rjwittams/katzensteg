//! OS adapters shared by the terminal engine and its hosts. File/directory
//! capabilities retain an explicitly supplied Io; raw descriptor operations
//! preserve nonblocking readiness and never enter an I/O scheduler.
pub const posix = @import("posix.zig");
pub const time = @import("time.zig");
pub const Mutex = @import("sync.zig").Mutex;
pub const Condition = @import("sync.zig").Condition;
pub const fs = @import("fs.zig");
pub const process = @import("process.zig");
pub const net = @import("net.zig");
pub const terminal = @import("terminal.zig");
pub const shm = @import("shm.zig");
