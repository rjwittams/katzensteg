#if defined(__APPLE__)

extern void ks_katzensteg_shutdown(void);
extern void ks_scrub_preload_env_for_loaded_symbol(const void *);
extern void ks_macos_register_sdl2_rebindings(void);
extern void ks_darwin_enable_rebinding_for_future_images(void);

__attribute__((constructor))
static void katzensteg_rebind_module_constructor(void) {
    ks_scrub_preload_env_for_loaded_symbol((const void *)&katzensteg_rebind_module_constructor);
    ks_macos_register_sdl2_rebindings();
    // Registering the future-image callback also applies it to already-loaded images.
    ks_darwin_enable_rebinding_for_future_images();
}

static void katzensteg_rebind_module_destructor(void) {
    ks_katzensteg_shutdown();
}

__attribute__((used, section("__DATA,__mod_term_func")))
static void (*katzensteg_rebind_module_destructor_ptr)(void) = katzensteg_rebind_module_destructor;

#endif
