#include <stdint.h>

#define STS2_BRIDGE_EXPORT __attribute__((visibility("default")))

/*
 * Minimal placeholder for res://addons/sentry/bin/macos/libSentry.dylib declared in
 * sentry.gdextension [dependencies] so macOS dyld/Godot dependency checks succeed.
 */
STS2_BRIDGE_EXPORT int32_t sts2_bridge_sentry_dep_placeholder(void) {
    return 0;
}
