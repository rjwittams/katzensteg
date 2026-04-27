#if defined(__linux__)

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static void *ks_gl_symbol(const char *name) {
    dlerror();
    return dlsym(RTLD_NEXT, name);
}

static void *ks_required_gl_symbol(const char *name) {
    void *symbol = ks_gl_symbol(name);
    if (!symbol) {
        const char *err = dlerror();
        fprintf(stderr, "katzensteg: failed to resolve real %s: %s\n", name, err ? err : "unknown error");
        abort();
    }
    return symbol;
}

#define KS_GL_DECL(name, rettype, args) static rettype (*real_##name) args

KS_GL_DECL(glReadBuffer, void, (unsigned int mode));
KS_GL_DECL(glPixelStorei, void, (unsigned int pname, int param));
KS_GL_DECL(glGetIntegerv, void, (unsigned int pname, int *data));
KS_GL_DECL(glReadPixels, void, (int x, int y, int width, int height, unsigned int format, unsigned int type, void *pixels));
KS_GL_DECL(glGetError, unsigned int, (void));
KS_GL_DECL(glGenBuffers, void, (int n, unsigned int *buffers));
KS_GL_DECL(glDeleteBuffers, void, (int n, const unsigned int *buffers));
KS_GL_DECL(glBindBuffer, void, (unsigned int target, unsigned int buffer));
KS_GL_DECL(glBufferData, void, (unsigned int target, intptr_t size, const void *data, unsigned int usage));
KS_GL_DECL(glMapBuffer, void *, (unsigned int target, unsigned int access));
KS_GL_DECL(glUnmapBuffer, unsigned char, (unsigned int target));
KS_GL_DECL(glGenFramebuffers, void, (int n, unsigned int *framebuffers));
KS_GL_DECL(glDeleteFramebuffers, void, (int n, const unsigned int *framebuffers));
KS_GL_DECL(glBindFramebuffer, void, (unsigned int target, unsigned int framebuffer));
KS_GL_DECL(glCheckFramebufferStatus, unsigned int, (unsigned int target));
KS_GL_DECL(glFramebufferTexture2D, void, (unsigned int target, unsigned int attachment, unsigned int textarget, unsigned int texture, int level));
KS_GL_DECL(glGenTextures, void, (int n, unsigned int *textures));
KS_GL_DECL(glDeleteTextures, void, (int n, const unsigned int *textures));
KS_GL_DECL(glBindTexture, void, (unsigned int target, unsigned int texture));
KS_GL_DECL(glTexParameteri, void, (unsigned int target, unsigned int pname, int param));
KS_GL_DECL(glTexImage2D, void, (unsigned int target, int level, int internalformat, int width, int height, int border, unsigned int format, unsigned int type, const void *pixels));
KS_GL_DECL(glBlitFramebuffer, void, (int srcX0, int srcY0, int srcX1, int srcY1, int dstX0, int dstY0, int dstX1, int dstY1, unsigned int mask, unsigned int filter));

#define KS_GL_TRY(name) \
    do { \
        if (!real_##name) real_##name = (__typeof__(real_##name))ks_gl_symbol(#name); \
        if (!real_##name) return 0; \
    } while (0)

int ks_real_gl_available(void) {
    KS_GL_TRY(glReadBuffer);
    KS_GL_TRY(glPixelStorei);
    KS_GL_TRY(glGetIntegerv);
    KS_GL_TRY(glReadPixels);
    KS_GL_TRY(glGetError);
    KS_GL_TRY(glGenBuffers);
    KS_GL_TRY(glDeleteBuffers);
    KS_GL_TRY(glBindBuffer);
    KS_GL_TRY(glBufferData);
    KS_GL_TRY(glMapBuffer);
    KS_GL_TRY(glUnmapBuffer);
    KS_GL_TRY(glGenFramebuffers);
    KS_GL_TRY(glDeleteFramebuffers);
    KS_GL_TRY(glBindFramebuffer);
    KS_GL_TRY(glCheckFramebufferStatus);
    KS_GL_TRY(glFramebufferTexture2D);
    KS_GL_TRY(glGenTextures);
    KS_GL_TRY(glDeleteTextures);
    KS_GL_TRY(glBindTexture);
    KS_GL_TRY(glTexParameteri);
    KS_GL_TRY(glTexImage2D);
    KS_GL_TRY(glBlitFramebuffer);
    return 1;
}

#define KS_GL_REAL(name) \
    do { \
        if (!real_##name) real_##name = (__typeof__(real_##name))ks_required_gl_symbol(#name); \
    } while (0)

void ks_real_glReadBuffer(unsigned int mode) { KS_GL_REAL(glReadBuffer); real_glReadBuffer(mode); }
void ks_real_glPixelStorei(unsigned int pname, int param) { KS_GL_REAL(glPixelStorei); real_glPixelStorei(pname, param); }
void ks_real_glGetIntegerv(unsigned int pname, int *data) { KS_GL_REAL(glGetIntegerv); real_glGetIntegerv(pname, data); }
void ks_real_glReadPixels(int x, int y, int width, int height, unsigned int format, unsigned int type, void *pixels) { KS_GL_REAL(glReadPixels); real_glReadPixels(x, y, width, height, format, type, pixels); }
unsigned int ks_real_glGetError(void) { KS_GL_REAL(glGetError); return real_glGetError(); }
void ks_real_glGenBuffers(int n, unsigned int *buffers) { KS_GL_REAL(glGenBuffers); real_glGenBuffers(n, buffers); }
void ks_real_glDeleteBuffers(int n, const unsigned int *buffers) { KS_GL_REAL(glDeleteBuffers); real_glDeleteBuffers(n, buffers); }
void ks_real_glBindBuffer(unsigned int target, unsigned int buffer) { KS_GL_REAL(glBindBuffer); real_glBindBuffer(target, buffer); }
void ks_real_glBufferData(unsigned int target, intptr_t size, const void *data, unsigned int usage) { KS_GL_REAL(glBufferData); real_glBufferData(target, size, data, usage); }
void *ks_real_glMapBuffer(unsigned int target, unsigned int access) { KS_GL_REAL(glMapBuffer); return real_glMapBuffer(target, access); }
unsigned char ks_real_glUnmapBuffer(unsigned int target) { KS_GL_REAL(glUnmapBuffer); return real_glUnmapBuffer(target); }
void ks_real_glGenFramebuffers(int n, unsigned int *framebuffers) { KS_GL_REAL(glGenFramebuffers); real_glGenFramebuffers(n, framebuffers); }
void ks_real_glDeleteFramebuffers(int n, const unsigned int *framebuffers) { KS_GL_REAL(glDeleteFramebuffers); real_glDeleteFramebuffers(n, framebuffers); }
void ks_real_glBindFramebuffer(unsigned int target, unsigned int framebuffer) { KS_GL_REAL(glBindFramebuffer); real_glBindFramebuffer(target, framebuffer); }
unsigned int ks_real_glCheckFramebufferStatus(unsigned int target) { KS_GL_REAL(glCheckFramebufferStatus); return real_glCheckFramebufferStatus(target); }
void ks_real_glFramebufferTexture2D(unsigned int target, unsigned int attachment, unsigned int textarget, unsigned int texture, int level) { KS_GL_REAL(glFramebufferTexture2D); real_glFramebufferTexture2D(target, attachment, textarget, texture, level); }
void ks_real_glGenTextures(int n, unsigned int *textures) { KS_GL_REAL(glGenTextures); real_glGenTextures(n, textures); }
void ks_real_glDeleteTextures(int n, const unsigned int *textures) { KS_GL_REAL(glDeleteTextures); real_glDeleteTextures(n, textures); }
void ks_real_glBindTexture(unsigned int target, unsigned int texture) { KS_GL_REAL(glBindTexture); real_glBindTexture(target, texture); }
void ks_real_glTexParameteri(unsigned int target, unsigned int pname, int param) { KS_GL_REAL(glTexParameteri); real_glTexParameteri(target, pname, param); }
void ks_real_glTexImage2D(unsigned int target, int level, int internalformat, int width, int height, int border, unsigned int format, unsigned int type, const void *pixels) { KS_GL_REAL(glTexImage2D); real_glTexImage2D(target, level, internalformat, width, height, border, format, type, pixels); }
void ks_real_glBlitFramebuffer(int srcX0, int srcY0, int srcX1, int srcY1, int dstX0, int dstY0, int dstX1, int dstY1, unsigned int mask, unsigned int filter) { KS_GL_REAL(glBlitFramebuffer); real_glBlitFramebuffer(srcX0, srcY0, srcX1, srcY1, dstX0, dstY0, dstX1, dstY1, mask, filter); }

#endif
