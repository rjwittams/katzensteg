#ifndef KATZENSTEG_DARWIN_REBINDER_H
#define KATZENSTEG_DARWIN_REBINDER_H

#if defined(__APPLE__)

struct ks_darwin_rebinding {
    const char *name;
    void *replacement;
    void **original;
};

void ks_darwin_register_rebindings(const struct ks_darwin_rebinding *items, unsigned int count);
void ks_darwin_apply_rebindings_to_current_images(void);
void ks_darwin_enable_rebinding_for_future_images(void);

#endif

#endif
