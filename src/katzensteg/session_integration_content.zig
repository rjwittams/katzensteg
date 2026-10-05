//! Session content export for the private cleat integration fixture.
//! Rooted beside the input adapter so session content can import its collaborators.
pub const Content = @import("wm/session.zig").Content;

// Compile and run session collaborators through their public content seam.
test {
    @import("std").testing.refAllDecls(Content);
}
