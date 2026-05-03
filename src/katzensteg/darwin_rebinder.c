#if defined(__APPLE__)

#include "darwin_rebinder.h"

#include <dlfcn.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__LP64__)
typedef struct mach_header_64 ks_mach_header_t;
typedef struct segment_command_64 ks_segment_command_t;
typedef struct section_64 ks_section_t;
typedef struct nlist_64 ks_nlist_t;
#define KS_LC_SEGMENT LC_SEGMENT_64
#else
typedef struct mach_header ks_mach_header_t;
typedef struct segment_command ks_segment_command_t;
typedef struct section ks_section_t;
typedef struct nlist ks_nlist_t;
#define KS_LC_SEGMENT LC_SEGMENT
#endif

#ifndef SEG_DATA_CONST
#define SEG_DATA_CONST "__DATA_CONST"
#endif

extern void ks_katzensteg_log_c(const char *, const char *);

struct ks_rebinding_table {
    const struct ks_darwin_rebinding *items;
    unsigned int count;
};

// This rebinder currently has one SDL2 table; 16 leaves room for future small
// families without adding allocation to dyld image-load callbacks.
static struct ks_rebinding_table g_tables[16];
static unsigned int g_table_count;
static int g_future_callback_registered;

static int ks_trace_enabled(void) {
    const char *value = getenv("KATZENSTEG_TRACE_SDL");
    return value && value[0];
}

static void ks_log(const char *message) {
    ks_katzensteg_log_c("darwin_rebinder", message);
}

void ks_darwin_register_rebindings(const struct ks_darwin_rebinding *items, unsigned int count) {
    if (!items || count == 0) return;
    if (g_table_count >= (sizeof(g_tables) / sizeof(g_tables[0]))) {
        ks_log("too many Darwin rebinding tables registered");
        return;
    }
    g_tables[g_table_count].items = items;
    g_tables[g_table_count].count = count;
    g_table_count++;
}

static const struct ks_darwin_rebinding *ks_find_rebinding(const char *macho_symbol_name) {
    if (!macho_symbol_name || macho_symbol_name[0] != '_' || !macho_symbol_name[1]) return NULL;
    const char *name = macho_symbol_name + 1;
    for (unsigned int table_index = 0; table_index < g_table_count; table_index++) {
        const struct ks_rebinding_table *table = &g_tables[table_index];
        for (unsigned int item_index = 0; item_index < table->count; item_index++) {
            if (strcmp(name, table->items[item_index].name) == 0) {
                return &table->items[item_index];
            }
        }
    }
    return NULL;
}

static unsigned int ks_rebind_section(ks_section_t *section, intptr_t slide, ks_nlist_t *symtab, char *strtab, uint32_t *indirect_symtab) {
    uint32_t *indices = indirect_symtab + section->reserved1;
    void **bindings = (void **)((uintptr_t)slide + section->addr);
    unsigned int patched = 0;
    bool writable = false;
    bool protect_failed = false;

    for (uint64_t i = 0; i < section->size / sizeof(void *); i++) {
        uint32_t symtab_index = indices[i];
        if (symtab_index == INDIRECT_SYMBOL_ABS ||
            symtab_index == INDIRECT_SYMBOL_LOCAL ||
            symtab_index == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) {
            continue;
        }

        const char *symbol_name = strtab + symtab[symtab_index].n_un.n_strx;
        const struct ks_darwin_rebinding *rebinding = ks_find_rebinding(symbol_name);
        if (!rebinding) continue;

        void *current = bindings[i];
        if (rebinding->original && current != rebinding->replacement && *rebinding->original == NULL) {
            *rebinding->original = current;
        }
        if (!rebinding->replacement || current == rebinding->replacement) continue;

        if (!writable && !protect_failed) {
            // Keep the private CoW mapping writable after patching. Restoring
            // permissions here can fight lazy binding for unpatched entries in
            // the same symbol-pointer section.
            kern_return_t err = vm_protect(
                mach_task_self(),
                (vm_address_t)bindings,
                (vm_size_t)section->size,
                0,
                VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
            if (err == KERN_SUCCESS) {
                writable = true;
            } else {
                protect_failed = true;
                ks_log("failed to make Mach-O symbol pointer section writable");
            }
        }
        if (!writable) continue;

        bindings[i] = rebinding->replacement;
        patched++;
    }

    return patched;
}

static unsigned int ks_rebind_image(const struct mach_header *raw_header, intptr_t slide) {
    if (!raw_header || g_table_count == 0) return 0;

    const ks_mach_header_t *header = (const ks_mach_header_t *)raw_header;
    ks_segment_command_t *linkedit_segment = NULL;
    struct symtab_command *symtab_cmd = NULL;
    struct dysymtab_command *dysymtab_cmd = NULL;

    uintptr_t cursor = (uintptr_t)header + sizeof(ks_mach_header_t);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        ks_segment_command_t *cmd = (ks_segment_command_t *)cursor;
        if (cmd->cmd == KS_LC_SEGMENT) {
            if (strcmp(cmd->segname, SEG_LINKEDIT) == 0) {
                linkedit_segment = cmd;
            }
        } else if (cmd->cmd == LC_SYMTAB) {
            symtab_cmd = (struct symtab_command *)cmd;
        } else if (cmd->cmd == LC_DYSYMTAB) {
            dysymtab_cmd = (struct dysymtab_command *)cmd;
        }
        cursor += cmd->cmdsize;
    }

    if (!linkedit_segment || !symtab_cmd || !dysymtab_cmd || dysymtab_cmd->nindirectsyms == 0) return 0;

    uintptr_t linkedit_base = (uintptr_t)slide + linkedit_segment->vmaddr - linkedit_segment->fileoff;
    ks_nlist_t *symtab = (ks_nlist_t *)(linkedit_base + symtab_cmd->symoff);
    char *strtab = (char *)(linkedit_base + symtab_cmd->stroff);
    uint32_t *indirect_symtab = (uint32_t *)(linkedit_base + dysymtab_cmd->indirectsymoff);

    unsigned int patched = 0;
    cursor = (uintptr_t)header + sizeof(ks_mach_header_t);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        ks_segment_command_t *cmd = (ks_segment_command_t *)cursor;
        if (cmd->cmd == KS_LC_SEGMENT &&
            (strcmp(cmd->segname, SEG_DATA) == 0 || strcmp(cmd->segname, SEG_DATA_CONST) == 0)) {
            ks_section_t *section = (ks_section_t *)(cursor + sizeof(ks_segment_command_t));
            for (uint32_t j = 0; j < cmd->nsects; j++) {
                uint32_t section_type = section[j].flags & SECTION_TYPE;
                if (section_type == S_LAZY_SYMBOL_POINTERS || section_type == S_NON_LAZY_SYMBOL_POINTERS) {
                    patched += ks_rebind_section(&section[j], slide, symtab, strtab, indirect_symtab);
                }
            }
        }
        cursor += cmd->cmdsize;
    }

    if (patched > 0 && ks_trace_enabled()) {
        Dl_info info;
        if (dladdr(header, &info) != 0 && info.dli_fname) {
            char message[1024];
            snprintf(message, sizeof(message), "patched %u symbol pointers in %s", patched, info.dli_fname);
            ks_log(message);
        }
    }
    return patched;
}

static void ks_rebind_added_image(const struct mach_header *header, intptr_t slide) {
    (void)ks_rebind_image(header, slide);
}

void ks_darwin_apply_rebindings_to_current_images(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        (void)ks_rebind_image(_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i));
    }
}

void ks_darwin_enable_rebinding_for_future_images(void) {
    if (g_future_callback_registered) return;
    g_future_callback_registered = 1;
    _dyld_register_func_for_add_image(ks_rebind_added_image);
}

#endif
