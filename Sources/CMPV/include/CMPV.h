#ifndef CMPV_H
#define CMPV_H

// Vendored libmpv client API headers (ISC licensed, see mpv/client.h).
// libmpv itself is NOT linked: cmpv.c resolves the symbols at runtime with
// dlopen(), so the app builds and launches without mpv installed and simply
// falls back to the AVFoundation engine.
#include "mpv/client.h"
#include "mpv/render.h"
#include "mpv/render_gl.h"

/// Attempts to load libmpv from the given candidate paths (first match wins).
/// Returns 1 when a compatible libmpv (client API major version 2) was loaded.
int cmpv_load(const char *const *paths, int count);

/// 1 if libmpv has been loaded successfully.
int cmpv_is_loaded(void);

/// Path of the loaded library, or NULL.
const char *cmpv_loaded_path(void);

/// Resolves an OpenGL function for mpv's render API (uses the system OpenGL framework).
void *cmpv_gl_get_proc_address(void *ctx, const char *name);

#endif
