#include <stddef.h>
#include <stdint.h>

typedef uint8_t GDExtensionBool;
typedef const void *GDExtensionInterfaceGetProcAddress;
typedef void *GDExtensionClassLibraryPtr;

typedef struct {
    int32_t minimum_initialization_level;
    void *userdata;
    void (*initialize)(void *userdata, int32_t level);
    void (*deinitialize)(void *userdata, int32_t level);
} GDExtensionInitialization;

#define STS2_BRIDGE_EXPORT __attribute__((visibility("default")))

/*
 * Godot loads Sentry GDExtension automatically from res://addons/sentry/sentry.gdextension.
 * Returning 0 cleanly disables native Sentry crashpad on macOS bridge runs while keeping
 * Godot's extension loader happy (C# SentryService.Initialize is also bypassed via Harmony).
 */
STS2_BRIDGE_EXPORT GDExtensionBool sentry_gdextension_init(
    GDExtensionInterfaceGetProcAddress get_proc_address,
    GDExtensionClassLibraryPtr library,
    GDExtensionInitialization *initialization
) {
    (void)get_proc_address;
    (void)library;

    if (initialization != NULL) {
        initialization->minimum_initialization_level = 0;
        initialization->userdata = NULL;
        initialization->initialize = NULL;
        initialization->deinitialize = NULL;
    }

    return 0;
}
