#include "CMPV.h"

#include <dlfcn.h>
#include <string.h>

static void *lib_handle = NULL;
static char loaded_path[1024];
static void *gl_handle = NULL;

// One function pointer per libmpv entry point we use. Each public mpv_* symbol
// below forwards to its pointer, returning a neutral error value when libmpv
// is not loaded.
#define MPV_FUNCS(X) \
    X(unsigned long, mpv_client_api_version, (void)) \
    X(const char *, mpv_error_string, (int)) \
    X(void, mpv_free, (void *)) \
    X(mpv_handle *, mpv_create, (void)) \
    X(int, mpv_initialize, (mpv_handle *)) \
    X(void, mpv_terminate_destroy, (mpv_handle *)) \
    X(int, mpv_set_option, (mpv_handle *, const char *, mpv_format, void *)) \
    X(int, mpv_set_option_string, (mpv_handle *, const char *, const char *)) \
    X(int, mpv_command, (mpv_handle *, const char **)) \
    X(int, mpv_command_async, (mpv_handle *, uint64_t, const char **)) \
    X(int, mpv_command_string, (mpv_handle *, const char *)) \
    X(int, mpv_set_property, (mpv_handle *, const char *, mpv_format, void *)) \
    X(int, mpv_set_property_string, (mpv_handle *, const char *, const char *)) \
    X(int, mpv_get_property, (mpv_handle *, const char *, mpv_format, void *)) \
    X(char *, mpv_get_property_string, (mpv_handle *, const char *)) \
    X(int, mpv_observe_property, (mpv_handle *, uint64_t, const char *, mpv_format)) \
    X(int, mpv_request_log_messages, (mpv_handle *, const char *)) \
    X(mpv_event *, mpv_wait_event, (mpv_handle *, double)) \
    X(void, mpv_wakeup, (mpv_handle *)) \
    X(void, mpv_set_wakeup_callback, (mpv_handle *, void (*)(void *), void *)) \
    X(const char *, mpv_event_name, (mpv_event_id)) \
    X(void, mpv_free_node_contents, (mpv_node *)) \
    X(int, mpv_render_context_create, (mpv_render_context **, mpv_handle *, mpv_render_param *)) \
    X(void, mpv_render_context_set_update_callback, (mpv_render_context *, mpv_render_update_fn, void *)) \
    X(uint64_t, mpv_render_context_update, (mpv_render_context *)) \
    X(int, mpv_render_context_render, (mpv_render_context *, mpv_render_param *)) \
    X(void, mpv_render_context_report_swap, (mpv_render_context *)) \
    X(void, mpv_render_context_free, (mpv_render_context *))

#define DECLARE_PTR(ret, name, args) static ret (*p_##name) args = NULL;
MPV_FUNCS(DECLARE_PTR)

static int resolve_all(void *h) {
#define RESOLVE(ret, name, args) \
    p_##name = (ret (*) args)dlsym(h, #name); \
    if (!p_##name) return 0;
    MPV_FUNCS(RESOLVE)
    return 1;
}

static void clear_all(void) {
#define CLEAR(ret, name, args) p_##name = NULL;
    MPV_FUNCS(CLEAR)
}

int cmpv_load(const char *const *paths, int count) {
    if (lib_handle) return 1;
    for (int i = 0; i < count; i++) {
        void *h = dlopen(paths[i], RTLD_NOW | RTLD_LOCAL);
        if (!h) continue;
        if (resolve_all(h) && (p_mpv_client_api_version() >> 16) == 2) {
            lib_handle = h;
            strncpy(loaded_path, paths[i], sizeof(loaded_path) - 1);
            return 1;
        }
        clear_all();
        dlclose(h);
    }
    return 0;
}

int cmpv_is_loaded(void) { return lib_handle != NULL; }

const char *cmpv_loaded_path(void) { return lib_handle ? loaded_path : NULL; }

void *cmpv_gl_get_proc_address(void *ctx, const char *name) {
    (void)ctx;
    if (!gl_handle) {
        gl_handle = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY | RTLD_LOCAL);
        if (!gl_handle) return NULL;
    }
    return dlsym(gl_handle, name);
}

// MARK: - Forwarding definitions

unsigned long mpv_client_api_version(void) { return p_mpv_client_api_version ? p_mpv_client_api_version() : 0; }
const char *mpv_error_string(int error) { return p_mpv_error_string ? p_mpv_error_string(error) : "libmpv not loaded"; }
void mpv_free(void *data) { if (p_mpv_free) p_mpv_free(data); }
mpv_handle *mpv_create(void) { return p_mpv_create ? p_mpv_create() : NULL; }
int mpv_initialize(mpv_handle *ctx) { return p_mpv_initialize ? p_mpv_initialize(ctx) : MPV_ERROR_UNINITIALIZED; }
void mpv_terminate_destroy(mpv_handle *ctx) { if (p_mpv_terminate_destroy) p_mpv_terminate_destroy(ctx); }

int mpv_set_option(mpv_handle *ctx, const char *name, mpv_format format, void *data) {
    return p_mpv_set_option ? p_mpv_set_option(ctx, name, format, data) : MPV_ERROR_UNINITIALIZED;
}
int mpv_set_option_string(mpv_handle *ctx, const char *name, const char *data) {
    return p_mpv_set_option_string ? p_mpv_set_option_string(ctx, name, data) : MPV_ERROR_UNINITIALIZED;
}
int mpv_command(mpv_handle *ctx, const char **args) {
    return p_mpv_command ? p_mpv_command(ctx, args) : MPV_ERROR_UNINITIALIZED;
}
int mpv_command_async(mpv_handle *ctx, uint64_t reply_userdata, const char **args) {
    return p_mpv_command_async ? p_mpv_command_async(ctx, reply_userdata, args) : MPV_ERROR_UNINITIALIZED;
}
int mpv_command_string(mpv_handle *ctx, const char *args) {
    return p_mpv_command_string ? p_mpv_command_string(ctx, args) : MPV_ERROR_UNINITIALIZED;
}
int mpv_set_property(mpv_handle *ctx, const char *name, mpv_format format, void *data) {
    return p_mpv_set_property ? p_mpv_set_property(ctx, name, format, data) : MPV_ERROR_UNINITIALIZED;
}
int mpv_set_property_string(mpv_handle *ctx, const char *name, const char *data) {
    return p_mpv_set_property_string ? p_mpv_set_property_string(ctx, name, data) : MPV_ERROR_UNINITIALIZED;
}
int mpv_get_property(mpv_handle *ctx, const char *name, mpv_format format, void *data) {
    return p_mpv_get_property ? p_mpv_get_property(ctx, name, format, data) : MPV_ERROR_UNINITIALIZED;
}
char *mpv_get_property_string(mpv_handle *ctx, const char *name) {
    return p_mpv_get_property_string ? p_mpv_get_property_string(ctx, name) : NULL;
}
int mpv_observe_property(mpv_handle *mpv, uint64_t reply_userdata, const char *name, mpv_format format) {
    return p_mpv_observe_property ? p_mpv_observe_property(mpv, reply_userdata, name, format) : MPV_ERROR_UNINITIALIZED;
}
int mpv_request_log_messages(mpv_handle *ctx, const char *min_level) {
    return p_mpv_request_log_messages ? p_mpv_request_log_messages(ctx, min_level) : MPV_ERROR_UNINITIALIZED;
}
mpv_event *mpv_wait_event(mpv_handle *ctx, double timeout) {
    return p_mpv_wait_event ? p_mpv_wait_event(ctx, timeout) : NULL;
}
void mpv_wakeup(mpv_handle *ctx) { if (p_mpv_wakeup) p_mpv_wakeup(ctx); }
void mpv_set_wakeup_callback(mpv_handle *ctx, void (*cb)(void *d), void *d) {
    if (p_mpv_set_wakeup_callback) p_mpv_set_wakeup_callback(ctx, cb, d);
}
const char *mpv_event_name(mpv_event_id event) { return p_mpv_event_name ? p_mpv_event_name(event) : ""; }
void mpv_free_node_contents(mpv_node *node) { if (p_mpv_free_node_contents) p_mpv_free_node_contents(node); }

int mpv_render_context_create(mpv_render_context **res, mpv_handle *mpv, mpv_render_param *params) {
    return p_mpv_render_context_create ? p_mpv_render_context_create(res, mpv, params) : MPV_ERROR_UNINITIALIZED;
}
void mpv_render_context_set_update_callback(mpv_render_context *ctx, mpv_render_update_fn callback, void *callback_ctx) {
    if (p_mpv_render_context_set_update_callback) p_mpv_render_context_set_update_callback(ctx, callback, callback_ctx);
}
uint64_t mpv_render_context_update(mpv_render_context *ctx) {
    return p_mpv_render_context_update ? p_mpv_render_context_update(ctx) : 0;
}
int mpv_render_context_render(mpv_render_context *ctx, mpv_render_param *params) {
    return p_mpv_render_context_render ? p_mpv_render_context_render(ctx, params) : MPV_ERROR_UNINITIALIZED;
}
void mpv_render_context_report_swap(mpv_render_context *ctx) {
    if (p_mpv_render_context_report_swap) p_mpv_render_context_report_swap(ctx);
}
void mpv_render_context_free(mpv_render_context *ctx) {
    if (p_mpv_render_context_free) p_mpv_render_context_free(ctx);
}
