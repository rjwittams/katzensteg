const builtin = @import("builtin");

const use_linux_real = builtin.os.tag == .linux and !builtin.is_test;

extern fn ks_real_gl_available() c_int;
extern fn ks_real_glReadBuffer(mode: c_uint) void;
extern fn ks_real_glPixelStorei(pname: c_uint, param: c_int) void;
extern fn ks_real_glGetIntegerv(pname: c_uint, data: *c_int) void;
extern fn ks_real_glReadPixels(x: c_int, y: c_int, width: c_int, height: c_int, format: c_uint, typ: c_uint, pixels: ?*anyopaque) void;
extern fn ks_real_glGetError() c_uint;
extern fn ks_real_glGenBuffers(n: c_int, buffers: *c_uint) void;
extern fn ks_real_glDeleteBuffers(n: c_int, buffers: *const c_uint) void;
extern fn ks_real_glBindBuffer(target: c_uint, buffer: c_uint) void;
extern fn ks_real_glBufferData(target: c_uint, size: isize, data: ?*const anyopaque, usage: c_uint) void;
extern fn ks_real_glMapBuffer(target: c_uint, access: c_uint) ?*anyopaque;
extern fn ks_real_glUnmapBuffer(target: c_uint) u8;
extern fn ks_real_glGenFramebuffers(n: c_int, framebuffers: *c_uint) void;
extern fn ks_real_glDeleteFramebuffers(n: c_int, framebuffers: *const c_uint) void;
extern fn ks_real_glBindFramebuffer(target: c_uint, framebuffer: c_uint) void;
extern fn ks_real_glCheckFramebufferStatus(target: c_uint) c_uint;
extern fn ks_real_glFramebufferTexture2D(target: c_uint, attachment: c_uint, textarget: c_uint, texture: c_uint, level: c_int) void;
extern fn ks_real_glGenTextures(n: c_int, textures: *c_uint) void;
extern fn ks_real_glDeleteTextures(n: c_int, textures: *const c_uint) void;
extern fn ks_real_glBindTexture(target: c_uint, texture: c_uint) void;
extern fn ks_real_glTexParameteri(target: c_uint, pname: c_uint, param: c_int) void;
extern fn ks_real_glTexImage2D(target: c_uint, level: c_int, internalformat: c_int, width: c_int, height: c_int, border: c_int, format: c_uint, typ: c_uint, pixels: ?*const anyopaque) void;
extern fn ks_real_glBlitFramebuffer(srcX0: c_int, srcY0: c_int, srcX1: c_int, srcY1: c_int, dstX0: c_int, dstY0: c_int, dstX1: c_int, dstY1: c_int, mask: c_uint, filter: c_uint) void;

extern fn glReadBuffer(mode: c_uint) void;
extern fn glPixelStorei(pname: c_uint, param: c_int) void;
extern fn glGetIntegerv(pname: c_uint, data: *c_int) void;
extern fn glReadPixels(x: c_int, y: c_int, width: c_int, height: c_int, format: c_uint, typ: c_uint, pixels: ?*anyopaque) void;
extern fn glGetError() c_uint;
extern fn glGenBuffers(n: c_int, buffers: *c_uint) void;
extern fn glDeleteBuffers(n: c_int, buffers: *const c_uint) void;
extern fn glBindBuffer(target: c_uint, buffer: c_uint) void;
extern fn glBufferData(target: c_uint, size: isize, data: ?*const anyopaque, usage: c_uint) void;
extern fn glMapBuffer(target: c_uint, access: c_uint) ?*anyopaque;
extern fn glUnmapBuffer(target: c_uint) u8;
extern fn glGenFramebuffers(n: c_int, framebuffers: *c_uint) void;
extern fn glDeleteFramebuffers(n: c_int, framebuffers: *const c_uint) void;
extern fn glBindFramebuffer(target: c_uint, framebuffer: c_uint) void;
extern fn glCheckFramebufferStatus(target: c_uint) c_uint;
extern fn glFramebufferTexture2D(target: c_uint, attachment: c_uint, textarget: c_uint, texture: c_uint, level: c_int) void;
extern fn glGenTextures(n: c_int, textures: *c_uint) void;
extern fn glDeleteTextures(n: c_int, textures: *const c_uint) void;
extern fn glBindTexture(target: c_uint, texture: c_uint) void;
extern fn glTexParameteri(target: c_uint, pname: c_uint, param: c_int) void;
extern fn glTexImage2D(target: c_uint, level: c_int, internalformat: c_int, width: c_int, height: c_int, border: c_int, format: c_uint, typ: c_uint, pixels: ?*const anyopaque) void;
extern fn glBlitFramebuffer(srcX0: c_int, srcY0: c_int, srcX1: c_int, srcY1: c_int, dstX0: c_int, dstY0: c_int, dstX1: c_int, dstY1: c_int, mask: c_uint, filter: c_uint) void;

pub fn available() bool {
    if (use_linux_real) return ks_real_gl_available() != 0;
    return true;
}

pub const ReadBuffer = if (use_linux_real) ks_real_glReadBuffer else glReadBuffer;
pub const PixelStorei = if (use_linux_real) ks_real_glPixelStorei else glPixelStorei;
pub const GetIntegerv = if (use_linux_real) ks_real_glGetIntegerv else glGetIntegerv;
pub const ReadPixels = if (use_linux_real) ks_real_glReadPixels else glReadPixels;
pub const GetError = if (use_linux_real) ks_real_glGetError else glGetError;
pub const GenBuffers = if (use_linux_real) ks_real_glGenBuffers else glGenBuffers;
pub const DeleteBuffers = if (use_linux_real) ks_real_glDeleteBuffers else glDeleteBuffers;
pub const BindBuffer = if (use_linux_real) ks_real_glBindBuffer else glBindBuffer;
pub const BufferData = if (use_linux_real) ks_real_glBufferData else glBufferData;
pub const MapBuffer = if (use_linux_real) ks_real_glMapBuffer else glMapBuffer;
pub const UnmapBuffer = if (use_linux_real) ks_real_glUnmapBuffer else glUnmapBuffer;
pub const GenFramebuffers = if (use_linux_real) ks_real_glGenFramebuffers else glGenFramebuffers;
pub const DeleteFramebuffers = if (use_linux_real) ks_real_glDeleteFramebuffers else glDeleteFramebuffers;
pub const BindFramebuffer = if (use_linux_real) ks_real_glBindFramebuffer else glBindFramebuffer;
pub const CheckFramebufferStatus = if (use_linux_real) ks_real_glCheckFramebufferStatus else glCheckFramebufferStatus;
pub const FramebufferTexture2D = if (use_linux_real) ks_real_glFramebufferTexture2D else glFramebufferTexture2D;
pub const GenTextures = if (use_linux_real) ks_real_glGenTextures else glGenTextures;
pub const DeleteTextures = if (use_linux_real) ks_real_glDeleteTextures else glDeleteTextures;
pub const BindTexture = if (use_linux_real) ks_real_glBindTexture else glBindTexture;
pub const TexParameteri = if (use_linux_real) ks_real_glTexParameteri else glTexParameteri;
pub const TexImage2D = if (use_linux_real) ks_real_glTexImage2D else glTexImage2D;
pub const BlitFramebuffer = if (use_linux_real) ks_real_glBlitFramebuffer else glBlitFramebuffer;
