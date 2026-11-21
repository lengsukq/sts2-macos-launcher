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
 * Fallback silent stub for FMOD GDExtension when upstream fmod-gdextension archives do
 * not bundle proprietary libfmod.dylib / libfmodstudio.dylib binaries.
 */
STS2_BRIDGE_EXPORT GDExtensionBool fmod_library_init(
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
