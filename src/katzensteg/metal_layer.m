#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <dlfcn.h>
#include <limits.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <fcntl.h>
#include <unistd.h>

#if defined(__APPLE__)

#define KS_MAX_HOOKS 512
#define KS_EXTERNAL_FRAMEBUFFER_BGRA8 1

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

typedef void (*ks_present_external_framebuffer_fn)(int32_t width, int32_t height, int32_t format, const uint8_t *pixels, size_t len);
typedef void (*ks_log_c_fn)(const char *scope, const char *message);

typedef struct HookRecord {
    Class cls;
    SEL sel;
    IMP original;
} HookRecord;

static pthread_mutex_t g_hook_lock = PTHREAD_MUTEX_INITIALIZER;
static HookRecord g_hooks[KS_MAX_HOOKS];
static bool g_installing_hooks;

static bool g_capture_enabled;
static bool g_trace_enabled;
static bool g_logged_no_present_fn;
static bool g_logged_unsupported_format;
static bool g_logged_framebuffer_only;
static bool g_logged_first_capture;
static bool g_logged_copy_failure;
static bool g_logged_constructor;

static void *g_core_handle;
static ks_present_external_framebuffer_fn g_present_external_framebuffer;
static ks_log_c_fn g_log_c;

extern void ks_scrub_preload_env_for_loaded_symbol(const void *symbol);

static id ks_nextDrawable(id self, SEL _cmd);
static id ks_commandBuffer(id self, SEL _cmd);
static id ks_commandBufferWithUnretainedReferences(id self, SEL _cmd);
static id ks_commandBufferWithDescriptor(id self, SEL _cmd, id descriptor);
static void ks_presentDrawable(id self, SEL _cmd, id drawable);
static void ks_presentDrawableAtTime(id self, SEL _cmd, id drawable, CFTimeInterval presentation_time);
static void ks_presentDrawableAfterMinimumDuration(id self, SEL _cmd, id drawable, CFTimeInterval duration);

static bool env_enabled(const char *name)
{
    const char *value = getenv(name);
    if (!value || !*value) return false;
    return strcmp(value, "0") != 0 && strcasecmp(value, "false") != 0 && strcasecmp(value, "no") != 0 && strcasecmp(value, "off") != 0;
}

static bool capture_enabled(void)
{
    return g_capture_enabled;
}

static bool trace_enabled(void)
{
    return g_trace_enabled;
}

static ks_log_c_fn log_fn(void)
{
    if (g_log_c) return g_log_c;
    g_log_c = (ks_log_c_fn)dlsym(RTLD_DEFAULT, "ks_katzensteg_log_c");
    return g_log_c;
}

static void write_trace_file(const char *message)
{
    if (!trace_enabled() || !message) return;

    char path[128];
    int written = snprintf(path, sizeof(path), "/tmp/katzensteg-metal-%d.log", getpid());
    if (written <= 0 || (size_t)written >= sizeof(path)) return;

    int fd = open(path, O_CREAT | O_WRONLY | O_APPEND, 0644);
    if (fd < 0) return;
    (void)write(fd, message, strlen(message));
    (void)write(fd, "\n", 1);
    close(fd);
}

static void tracef(const char *fmt, ...)
{
    if (!trace_enabled()) return;
    char message[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(message, sizeof(message), fmt, args);
    va_end(args);

    ks_log_c_fn fn = log_fn();
    if (fn) fn("metal", message);
    write_trace_file(message);
}

static void log_once(bool *flag, const char *message)
{
    if (*flag) return;
    *flag = true;
    ks_log_c_fn fn = log_fn();
    if (fn) fn("metal", message);
    write_trace_file(message);
}

static void *open_core_library_from_layer_dir(void)
{
    Dl_info info;
    if (dladdr((const void *)&open_core_library_from_layer_dir, &info) == 0 || !info.dli_fname) return NULL;

    const char *slash = strrchr(info.dli_fname, '/');
    if (!slash) return dlopen("libkatzensteg-core.dylib", RTLD_NOW | RTLD_LOCAL);

    char path[PATH_MAX];
    const size_t dir_len = (size_t)(slash - info.dli_fname);
    const int written = snprintf(path, sizeof(path), "%.*s/%s", (int)dir_len, info.dli_fname, "libkatzensteg-core.dylib");
    if (written <= 0 || (size_t)written >= sizeof(path)) return NULL;
    return dlopen(path, RTLD_NOW | RTLD_LOCAL);
}

static ks_present_external_framebuffer_fn present_fn(void)
{
    if (g_present_external_framebuffer) return g_present_external_framebuffer;

    g_present_external_framebuffer = (ks_present_external_framebuffer_fn)dlsym(RTLD_DEFAULT, "ks_katzensteg_present_external_framebuffer");
    if (g_present_external_framebuffer) return g_present_external_framebuffer;

    if (!g_core_handle) g_core_handle = open_core_library_from_layer_dir();
    if (g_core_handle)
        g_present_external_framebuffer = (ks_present_external_framebuffer_fn)dlsym(g_core_handle, "ks_katzensteg_present_external_framebuffer");
    return g_present_external_framebuffer;
}

static IMP original_imp_for_locked(Class cls, SEL sel)
{
    for (size_t i = 0; i < KS_MAX_HOOKS; i++) {
        if (g_hooks[i].cls == cls && g_hooks[i].sel == sel) return g_hooks[i].original;
    }
    for (Class parent = class_getSuperclass(cls); parent; parent = class_getSuperclass(parent)) {
        for (size_t i = 0; i < KS_MAX_HOOKS; i++) {
            if (g_hooks[i].cls == parent && g_hooks[i].sel == sel) return g_hooks[i].original;
        }
    }
    return NULL;
}

static IMP original_imp_for(id self, SEL sel)
{
    pthread_mutex_lock(&g_hook_lock);
    IMP imp = original_imp_for_locked(object_getClass(self), sel);
    pthread_mutex_unlock(&g_hook_lock);
    return imp;
}

static bool has_hook_locked(Class cls, SEL sel)
{
    for (size_t i = 0; i < KS_MAX_HOOKS; i++)
        if (g_hooks[i].cls == cls && g_hooks[i].sel == sel) return true;
    return false;
}

static void remember_hook_locked(Class cls, SEL sel, IMP original)
{
    for (size_t i = 0; i < KS_MAX_HOOKS; i++) {
        if (!g_hooks[i].cls) {
            g_hooks[i].cls = cls;
            g_hooks[i].sel = sel;
            g_hooks[i].original = original;
            return;
        }
    }
}

static void install_hook_locked(Class cls, SEL sel, IMP replacement)
{
    if (!cls || !sel || !replacement || has_hook_locked(cls, sel)) return;

    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;

    IMP original = method_getImplementation(method);
    if (original == replacement) return;

    const char *types = method_getTypeEncoding(method);
    if (class_addMethod(cls, sel, replacement, types)) {
        remember_hook_locked(cls, sel, original);
    } else {
        remember_hook_locked(cls, sel, original);
        method_setImplementation(method, replacement);
    }
    tracef("installed hook class=%s selector=%s", class_getName(cls), sel_getName(sel));
}

static bool class_name_is_ours(const char *name)
{
    return name && (strstr(name, "Katzensteg") || strstr(name, "ks_"));
}

static bool class_name_looks_metal(const char *name)
{
    if (!name) return false;
    return strncmp(name, "_MTL", 4) == 0 ||
           strncmp(name, "MTL", 3) == 0 ||
           strstr(name, "AGX") ||
           strstr(name, "IOGPU");
}

static bool class_is_subclass_of(Class cls, Class parent)
{
    for (Class cursor = cls; cursor; cursor = class_getSuperclass(cursor))
        if (cursor == parent) return true;
    return false;
}

static bool class_conforms_to_protocol(Class cls, Protocol *protocol)
{
    for (Class cursor = cls; cursor; cursor = class_getSuperclass(cursor))
        if (class_conformsToProtocol(cursor, protocol)) return true;
    return false;
}

static void install_hooks_for_class_locked(Class cls)
{
    const char *name = class_getName(cls);
    if (class_name_is_ours(name)) return;
    const bool looks_metal = class_name_looks_metal(name);

    if (class_is_subclass_of(cls, [CAMetalLayer class])) {
        install_hook_locked(cls, @selector(nextDrawable), (IMP)ks_nextDrawable);
    }

    if (class_conforms_to_protocol(cls, @protocol(MTLCommandQueue)) || looks_metal) {
        install_hook_locked(cls, @selector(commandBuffer), (IMP)ks_commandBuffer);
        install_hook_locked(cls, @selector(commandBufferWithUnretainedReferences), (IMP)ks_commandBufferWithUnretainedReferences);
        install_hook_locked(cls, @selector(commandBufferWithDescriptor:), (IMP)ks_commandBufferWithDescriptor);
    }

    if (class_conforms_to_protocol(cls, @protocol(MTLCommandBuffer)) || looks_metal) {
        install_hook_locked(cls, @selector(presentDrawable:), (IMP)ks_presentDrawable);
        install_hook_locked(cls, @selector(presentDrawable:atTime:), (IMP)ks_presentDrawableAtTime);
        install_hook_locked(cls, @selector(presentDrawable:afterMinimumDuration:), (IMP)ks_presentDrawableAfterMinimumDuration);
    }
}

static void install_known_hooks(void)
{
    if (!capture_enabled()) return;

    pthread_mutex_lock(&g_hook_lock);
    if (g_installing_hooks) {
        pthread_mutex_unlock(&g_hook_lock);
        return;
    }
    g_installing_hooks = true;

    int count = objc_getClassList(NULL, 0);
    if (count > 0) {
        Class *classes = (Class *)malloc((size_t)count * sizeof(Class));
        if (classes) {
            int written = objc_getClassList(classes, count);
            for (int i = 0; i < written; i++) install_hooks_for_class_locked(classes[i]);
            free(classes);
        }
    }

    g_installing_hooks = false;
    pthread_mutex_unlock(&g_hook_lock);
}

static size_t aligned_row_bytes(NSUInteger width)
{
    const size_t tight = (size_t)width * 4u;
    return (tight + 255u) & ~(size_t)255u;
}

static bool supported_pixel_format(MTLPixelFormat format)
{
    return format == MTLPixelFormatBGRA8Unorm || format == MTLPixelFormatBGRA8Unorm_sRGB;
}

static void publish_completed_buffer(id<MTLBuffer> buffer, NSUInteger width, NSUInteger height, size_t row_bytes)
{
    if ([buffer contents] == NULL || width == 0 || height == 0) return;

    ks_present_external_framebuffer_fn fn = present_fn();
    if (!fn) {
        log_once(&g_logged_no_present_fn, "core framebuffer callback not found; skipping Metal capture");
        return;
    }

    const size_t tight_row = (size_t)width * 4u;
    const size_t tight_len = tight_row * (size_t)height;
    uint8_t *compact = malloc(tight_len);
    if (!compact) return;

    const uint8_t *src = (const uint8_t *)[buffer contents];
    for (NSUInteger y = 0; y < height; y++) {
        memcpy(compact + (size_t)y * tight_row, src + (size_t)y * row_bytes, tight_row);
    }

    fn((int32_t)width, (int32_t)height, KS_EXTERNAL_FRAMEBUFFER_BGRA8, compact, tight_len);
    free(compact);
}

static void capture_drawable_on_command_buffer(id command_buffer, id drawable)
{
    if (!capture_enabled() || !command_buffer || !drawable) return;
    if (![drawable conformsToProtocol:@protocol(CAMetalDrawable)]) return;

    id<CAMetalDrawable> metal_drawable = (id<CAMetalDrawable>)drawable;
    id<MTLTexture> texture = metal_drawable.texture;
    if (!texture) return;

    if (![texture conformsToProtocol:@protocol(MTLTexture)] || !supported_pixel_format(texture.pixelFormat)) {
        log_once(&g_logged_unsupported_format, "unsupported Metal drawable format; skipping capture");
        return;
    }
    if (texture.framebufferOnly) {
        log_once(&g_logged_framebuffer_only, "Metal drawable is framebufferOnly; skipping capture");
        return;
    }

    const NSUInteger width = texture.width;
    const NSUInteger height = texture.height;
    if (width == 0 || height == 0 || width > INT32_MAX || height > INT32_MAX) return;

    id<MTLDevice> device = texture.device;
    if (!device) return;

    const size_t row_bytes = aligned_row_bytes(width);
    const size_t byte_len = row_bytes * (size_t)height;
    id<MTLBuffer> buffer = [device newBufferWithLength:byte_len options:MTLResourceStorageModeShared];
    if (!buffer) return;

    id<MTLBlitCommandEncoder> blit = [command_buffer blitCommandEncoder];
    if (!blit) {
        log_once(&g_logged_copy_failure, "failed to create Metal blit encoder for capture");
        return;
    }

    [blit copyFromTexture:texture
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(width, height, 1)
                 toBuffer:buffer
        destinationOffset:0
   destinationBytesPerRow:row_bytes
 destinationBytesPerImage:row_bytes * height];
    [blit endEncoding];

    [command_buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        if (completed.status != MTLCommandBufferStatusCompleted) return;
        publish_completed_buffer(buffer, width, height, row_bytes);
    }];

    if (!g_logged_first_capture) {
        g_logged_first_capture = true;
        tracef("queued first Metal capture %zux%zu row_bytes=%zu", (size_t)width, (size_t)height, row_bytes);
    }
}

static id ks_nextDrawable(id self, SEL _cmd)
{
    typedef id (*Fn)(id, SEL);
    Fn original = (Fn)original_imp_for(self, _cmd);
    if (capture_enabled() && [self isKindOfClass:[CAMetalLayer class]]) {
        CAMetalLayer *layer = (CAMetalLayer *)self;
        if (layer.framebufferOnly) {
            layer.framebufferOnly = NO;
            tracef("forced CAMetalLayer framebufferOnly=NO");
        }
    }
    id drawable = original ? original(self, _cmd) : nil;
    install_known_hooks();
    return drawable;
}

static id ks_commandBuffer(id self, SEL _cmd)
{
    typedef id (*Fn)(id, SEL);
    Fn original = (Fn)original_imp_for(self, _cmd);
    id command_buffer = original ? original(self, _cmd) : nil;
    install_known_hooks();
    return command_buffer;
}

static id ks_commandBufferWithUnretainedReferences(id self, SEL _cmd)
{
    typedef id (*Fn)(id, SEL);
    Fn original = (Fn)original_imp_for(self, _cmd);
    id command_buffer = original ? original(self, _cmd) : nil;
    install_known_hooks();
    return command_buffer;
}

static id ks_commandBufferWithDescriptor(id self, SEL _cmd, id descriptor)
{
    typedef id (*Fn)(id, SEL, id);
    Fn original = (Fn)original_imp_for(self, _cmd);
    id command_buffer = original ? original(self, _cmd, descriptor) : nil;
    install_known_hooks();
    return command_buffer;
}

static void ks_presentDrawable(id self, SEL _cmd, id drawable)
{
    typedef void (*Fn)(id, SEL, id);
    Fn original = (Fn)original_imp_for(self, _cmd);
    capture_drawable_on_command_buffer(self, drawable);
    if (original) original(self, _cmd, drawable);
}

static void ks_presentDrawableAtTime(id self, SEL _cmd, id drawable, CFTimeInterval presentation_time)
{
    typedef void (*Fn)(id, SEL, id, CFTimeInterval);
    Fn original = (Fn)original_imp_for(self, _cmd);
    capture_drawable_on_command_buffer(self, drawable);
    if (original) original(self, _cmd, drawable, presentation_time);
}

static void ks_presentDrawableAfterMinimumDuration(id self, SEL _cmd, id drawable, CFTimeInterval duration)
{
    typedef void (*Fn)(id, SEL, id, CFTimeInterval);
    Fn original = (Fn)original_imp_for(self, _cmd);
    capture_drawable_on_command_buffer(self, drawable);
    if (original) original(self, _cmd, drawable, duration);
}

__attribute__((constructor))
static void katzensteg_metal_layer_constructor(void)
{
    g_capture_enabled = env_enabled("KATZENSTEG_METAL_CAPTURE");
    g_trace_enabled = env_enabled("KATZENSTEG_TRACE_METAL");
    if (!g_logged_constructor) {
        g_logged_constructor = true;
        tracef("constructor capture_enabled=%s", g_capture_enabled ? "true" : "false");
    }
    ks_scrub_preload_env_for_loaded_symbol((const void *)&katzensteg_metal_layer_constructor);
    unsetenv("KATZENSTEG_METAL_CAPTURE");
    unsetenv("KATZENSTEG_TRACE_METAL");
    install_known_hooks();
}

#endif
