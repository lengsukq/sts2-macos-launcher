#define _DARWIN_C_SOURCE 1

#include <dlfcn.h>
#include <limits.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define STS2_BRIDGE_EXPORT __attribute__((visibility("default")))

/* Official .NET hostfxr error codes */
static const int32_t HOSTFXR_ERR_LIB_LOAD_FAILED = (int32_t)0x80008082;
static const int32_t HOSTFXR_ERR_SYMBOL_MISSING = (int32_t)0x80008083;

/* Official hostfxr_delegate_type enum values from hostfxr.h */
enum hostfxr_delegate_type {
    HDT_COM_ACTIVATION = 0,
    HDT_LOAD_IN_MEMORY_ASSEMBLY = 1,
    HDT_WINRT_ACTIVATION = 2,
    HDT_COM_REGISTER = 3,
    HDT_COM_UNREGISTER = 4,
    HDT_LOAD_ASSEMBLY_AND_GET_FUNCTION_POINTER = 5,
    HDT_GET_FUNCTION_POINTER = 6,
    HDT_LOAD_ASSEMBLY = 7,
    HDT_LOAD_ASSEMBLY_BYTES = 8
};

#define UNMANAGEDCALLERSONLY_METHOD ((const char *)(intptr_t)-1)

typedef void *hostfxr_handle;
typedef void (*hostfxr_error_writer_fn)(const char *message);

struct hostfxr_initialize_parameters {
    size_t size;
    const char *host_path;
    const char *dotnet_root;
};

typedef int32_t (*hostfxr_initialize_for_dotnet_command_line_fn)(
    int argc,
    const char **argv,
    const struct hostfxr_initialize_parameters *parameters,
    hostfxr_handle *host_context_handle
);
typedef int32_t (*hostfxr_initialize_for_runtime_config_fn)(
    const char *runtime_config_path,
    const struct hostfxr_initialize_parameters *parameters,
    hostfxr_handle *host_context_handle
);
typedef int32_t (*hostfxr_get_runtime_delegate_fn)(
    const hostfxr_handle host_context_handle,
    int32_t type,
    void **delegate
);
typedef int32_t (*hostfxr_close_fn)(const hostfxr_handle host_context_handle);
typedef hostfxr_error_writer_fn (*hostfxr_set_error_writer_fn)(hostfxr_error_writer_fn error_writer);
typedef int32_t (*hostfxr_get_runtime_property_value_fn)(
    const hostfxr_handle host_context_handle,
    const char *name,
    const char **value
);
typedef int32_t (*hostfxr_set_runtime_property_value_fn)(
    const hostfxr_handle host_context_handle,
    const char *name,
    const char *value
);
typedef int32_t (*hostfxr_get_runtime_properties_fn)(
    const hostfxr_handle host_context_handle,
    size_t *count,
    const char **keys,
    const char **values
);
typedef int32_t (*hostfxr_run_app_fn)(const hostfxr_handle host_context_handle);

typedef int (*load_assembly_and_get_function_pointer_fn)(
    const char *assembly_path,
    const char *type_name,
    const char *method_name,
    const char *delegate_type_name,
    void *reserved,
    void **delegate
);
typedef int (*load_assembly_fn)(
    const char *assembly_path,
    void *load_context,
    void *reserved
);
typedef int (*get_function_pointer_fn)(
    const char *type_name,
    const char *method_name,
    const char *delegate_type_name,
    void *load_context,
    void *reserved,
    void **delegate
);
typedef int (*bridge_startup_entry_fn)(void);

static pthread_mutex_t g_bridge_mutex = PTHREAD_MUTEX_INITIALIZER;
static void *g_real_hostfxr_handle = NULL;
static int g_startup_hooks_invoked = 0;

static void *load_real_hostfxr_locked(void) {
    if (g_real_hostfxr_handle != NULL) {
        return g_real_hostfxr_handle;
    }

    Dl_info info;
    if (dladdr((const void *)&load_real_hostfxr_locked, &info) == 0 || info.dli_fname == NULL) {
        fprintf(stderr, "[hostfxr_bridge] dladdr failed to resolve bridge library path.\n");
        fflush(stderr);
        return NULL;
    }

    const char *last_slash = strrchr(info.dli_fname, '/');
    char real_path[PATH_MAX];
    if (last_slash != NULL) {
        size_t dir_len = (size_t)(last_slash - info.dli_fname);
        int written = snprintf(real_path, sizeof(real_path), "%.*s/libhostfxr_real.dylib", (int)dir_len, info.dli_fname);
        if (written <= 0 || (size_t)written >= sizeof(real_path)) {
            fprintf(stderr, "[hostfxr_bridge] Path overflow constructing libhostfxr_real.dylib path.\n");
            fflush(stderr);
            return NULL;
        }
    } else {
        snprintf(real_path, sizeof(real_path), "libhostfxr_real.dylib");
    }

    /* RTLD_LOCAL prevents symbol collisions between this shim and libhostfxr_real.dylib. */
    g_real_hostfxr_handle = dlopen(real_path, RTLD_NOW | RTLD_LOCAL);
    if (g_real_hostfxr_handle == NULL) {
        fprintf(stderr, "[hostfxr_bridge] dlopen failed for '%s': %s\n", real_path, dlerror());
        fflush(stderr);
        return NULL;
    }

    fprintf(stdout, "[hostfxr_bridge] Loaded real hostfxr: %s\n", real_path);
    fflush(stdout);
    return g_real_hostfxr_handle;
}

static void *resolve_real_symbol(const char *symbol_name) {
    pthread_mutex_lock(&g_bridge_mutex);
    void *handle = load_real_hostfxr_locked();
    pthread_mutex_unlock(&g_bridge_mutex);

    if (handle == NULL) {
        return NULL;
    }

    void *sym = dlsym(handle, symbol_name);
    if (sym == NULL) {
        fprintf(stderr, "[hostfxr_bridge] Missing symbol '%s' in libhostfxr_real.dylib.\n", symbol_name);
        fflush(stderr);
    }
    return sym;
}

static void extract_assembly_name(const char *dll_path, char *out_name, size_t out_size) {
    const char *slash = strrchr(dll_path, '/');
    const char *base = (slash != NULL) ? (slash + 1) : dll_path;
    size_t len = strlen(base);
    if (len > 4 && strcmp(base + len - 4, ".dll") == 0) {
        len -= 4;
    }
    if (len >= out_size) {
        len = out_size - 1;
    }
    memcpy(out_name, base, len);
    out_name[len] = '\0';
}

static void invoke_single_startup_hook(
    const hostfxr_handle host_context_handle,
    hostfxr_get_runtime_delegate_fn real_get_delegate,
    load_assembly_and_get_function_pointer_fn loader_and_get_fn,
    const char *hook_path
) {
    if (hook_path == NULL || hook_path[0] == '\0') {
        return;
    }

    char asm_name[256];
    extract_assembly_name(hook_path, asm_name, sizeof(asm_name));
    if (asm_name[0] == '\0') {
        return;
    }

    char type_name[320];
    snprintf(type_name, sizeof(type_name), "StartupHook, %s", asm_name);

    void *fn_ptr = NULL;
    int rc = -1;

    /*
     * Prefer hdt_load_assembly + hdt_get_function_pointer so STS2MacBridge loads directly
     * into AssemblyLoadContext.Default (matching native DOTNET_STARTUP_HOOKS semantics).
     * Fall back to hdt_load_assembly_and_get_function_pointer when hostfxr was initialized
     * via hostfxr_initialize_for_dotnet_command_line (where hdt_load_assembly is unsupported).
     */
    void *load_asm_raw = NULL;
    void *get_fp_raw = NULL;
    if (real_get_delegate(host_context_handle, HDT_LOAD_ASSEMBLY, &load_asm_raw) == 0 &&
        load_asm_raw != NULL &&
        real_get_delegate(host_context_handle, HDT_GET_FUNCTION_POINTER, &get_fp_raw) == 0 &&
        get_fp_raw != NULL) {
        load_assembly_fn load_asm = (load_assembly_fn)load_asm_raw;
        get_function_pointer_fn get_fp = (get_function_pointer_fn)get_fp_raw;
        rc = load_asm(hook_path, NULL, NULL);
        if (rc == 0) {
            rc = get_fp(type_name, "InitializeUnmanaged", UNMANAGEDCALLERSONLY_METHOD, NULL, NULL, &fn_ptr);
        }
    }

    if ((rc != 0 || fn_ptr == NULL) && loader_and_get_fn != NULL) {
        fn_ptr = NULL;
        rc = loader_and_get_fn(
            hook_path,
            type_name,
            "InitializeUnmanaged",
            UNMANAGEDCALLERSONLY_METHOD,
            NULL,
            &fn_ptr
        );
    }

    if (rc != 0 || fn_ptr == NULL) {
        fprintf(
            stderr,
            "[hostfxr_bridge] Failed to resolve %s::InitializeUnmanaged from '%s' (rc=0x%x).\n",
            type_name,
            hook_path,
            (unsigned int)rc
        );
        fflush(stderr);
        return;
    }

    fprintf(stdout, "[hostfxr_bridge] Invoking %s::InitializeUnmanaged from '%s'...\n", type_name, hook_path);
    fflush(stdout);

    bridge_startup_entry_fn entry = (bridge_startup_entry_fn)fn_ptr;
    int hook_rc = entry();

    fprintf(stdout, "[hostfxr_bridge] Startup hook '%s' finished (rc=%d).\n", asm_name, hook_rc);
    fflush(stdout);
}

static void invoke_startup_hooks_once(
    const hostfxr_handle host_context_handle,
    hostfxr_get_runtime_delegate_fn real_get_delegate,
    load_assembly_and_get_function_pointer_fn loader_and_get_fn
) {
    pthread_mutex_lock(&g_bridge_mutex);
    if (g_startup_hooks_invoked != 0) {
        pthread_mutex_unlock(&g_bridge_mutex);
        return;
    }
    g_startup_hooks_invoked = 1;
    pthread_mutex_unlock(&g_bridge_mutex);

    const char *hooks_env = getenv("DOTNET_STARTUP_HOOKS");
    if (hooks_env == NULL || hooks_env[0] == '\0') {
        return;
    }

    if (loader_and_get_fn == NULL) {
        void *raw_loader = NULL;
        if (real_get_delegate(
                host_context_handle,
                HDT_LOAD_ASSEMBLY_AND_GET_FUNCTION_POINTER,
                &raw_loader) == 0) {
            loader_and_get_fn = (load_assembly_and_get_function_pointer_fn)raw_loader;
        }
    }

    char *copy = strdup(hooks_env);
    if (copy == NULL) {
        return;
    }

    char *cursor = copy;
    char *token = NULL;
    while ((token = strsep(&cursor, ":")) != NULL) {
        if (token[0] != '\0') {
            invoke_single_startup_hook(host_context_handle, real_get_delegate, loader_and_get_fn, token);
        }
    }

    free(copy);
}

STS2_BRIDGE_EXPORT int32_t hostfxr_initialize_for_dotnet_command_line(
    int argc,
    const char **argv,
    const struct hostfxr_initialize_parameters *parameters,
    hostfxr_handle *host_context_handle
) {
    hostfxr_initialize_for_dotnet_command_line_fn fn =
        (hostfxr_initialize_for_dotnet_command_line_fn)resolve_real_symbol("hostfxr_initialize_for_dotnet_command_line");
    if (fn == NULL) {
        return HOSTFXR_ERR_SYMBOL_MISSING;
    }
    return fn(argc, argv, parameters, host_context_handle);
}

STS2_BRIDGE_EXPORT int32_t hostfxr_initialize_for_runtime_config(
    const char *runtime_config_path,
    const struct hostfxr_initialize_parameters *parameters,
    hostfxr_handle *host_context_handle
) {
    hostfxr_initialize_for_runtime_config_fn fn =
        (hostfxr_initialize_for_runtime_config_fn)resolve_real_symbol("hostfxr_initialize_for_runtime_config");
    if (fn == NULL) {
        return HOSTFXR_ERR_SYMBOL_MISSING;
    }
    return fn(runtime_config_path, parameters, host_context_handle);
}

STS2_BRIDGE_EXPORT int32_t hostfxr_get_runtime_delegate(
    const hostfxr_handle host_context_handle,
    int32_t type,
    void **delegate
) {
    hostfxr_get_runtime_delegate_fn fn =
        (hostfxr_get_runtime_delegate_fn)resolve_real_symbol("hostfxr_get_runtime_delegate");
    if (fn == NULL) {
        return HOSTFXR_ERR_SYMBOL_MISSING;
    }

    int32_t rc = fn(host_context_handle, type, delegate);
    if (rc == 0 && delegate != NULL && *delegate != NULL) {
        load_assembly_and_get_function_pointer_fn loader =
            (type == HDT_LOAD_ASSEMBLY_AND_GET_FUNCTION_POINTER)
                ? (load_assembly_and_get_function_pointer_fn)(*delegate)
                : NULL;
        invoke_startup_hooks_once(host_context_handle, fn, loader);
    }

    return rc;
}

STS2_BRIDGE_EXPORT int32_t hostfxr_close(const hostfxr_handle host_context_handle) {
    hostfxr_close_fn fn = (hostfxr_close_fn)resolve_real_symbol("hostfxr_close");
    if (fn == NULL) {
        return HOSTFXR_ERR_LIB_LOAD_FAILED;
    }
    return fn(host_context_handle);
}

STS2_BRIDGE_EXPORT hostfxr_error_writer_fn hostfxr_set_error_writer(hostfxr_error_writer_fn error_writer) {
    hostfxr_set_error_writer_fn fn =
        (hostfxr_set_error_writer_fn)resolve_real_symbol("hostfxr_set_error_writer");
    if (fn == NULL) {
        return NULL;
    }
    return fn(error_writer);
}

STS2_BRIDGE_EXPORT int32_t hostfxr_get_runtime_property_value(
    const hostfxr_handle host_context_handle,
    const char *name,
    const char **value
) {
    hostfxr_get_runtime_property_value_fn fn =
        (hostfxr_get_runtime_property_value_fn)resolve_real_symbol("hostfxr_get_runtime_property_value");
    if (fn == NULL) {
        return HOSTFXR_ERR_SYMBOL_MISSING;
    }
    return fn(host_context_handle, name, value);
}

STS2_BRIDGE_EXPORT int32_t hostfxr_set_runtime_property_value(
    const hostfxr_handle host_context_handle,
    const char *name,
    const char *value
) {
    hostfxr_set_runtime_property_value_fn fn =
        (hostfxr_set_runtime_property_value_fn)resolve_real_symbol("hostfxr_set_runtime_property_value");
    if (fn == NULL) {
        return HOSTFXR_ERR_SYMBOL_MISSING;
    }
    return fn(host_context_handle, name, value);
}

STS2_BRIDGE_EXPORT int32_t hostfxr_get_runtime_properties(
    const hostfxr_handle host_context_handle,
    size_t *count,
    const char **keys,
    const char **values
) {
    hostfxr_get_runtime_properties_fn fn =
        (hostfxr_get_runtime_properties_fn)resolve_real_symbol("hostfxr_get_runtime_properties");
    if (fn == NULL) {
        return HOSTFXR_ERR_SYMBOL_MISSING;
    }
    return fn(host_context_handle, count, keys, values);
}

STS2_BRIDGE_EXPORT int32_t hostfxr_run_app(const hostfxr_handle host_context_handle) {
    hostfxr_run_app_fn fn = (hostfxr_run_app_fn)resolve_real_symbol("hostfxr_run_app");
    if (fn == NULL) {
        return HOSTFXR_ERR_SYMBOL_MISSING;
    }
    return fn(host_context_handle);
}
