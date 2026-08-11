#ifndef BOGGART_STUDIO_ASSETS_H
#define BOGGART_STUDIO_ASSETS_H

#include <stddef.h>

/* studio/data, baked into the binary by tools/bake_assets.cmake.
 *
 * Keyed by path relative to studio/data, extension included:
 * "core/init.lua", "core/doc/init.lua", "fonts/font.ttf". The returned bytes
 * are NUL-terminated for convenience but *len is the true length, which is
 * what the fonts need. */
const void *studio_asset_get(const char *name, size_t *len);
size_t studio_asset_count(void);
const char *studio_asset_name(size_t i);

/* The marker DATADIR takes when there is no data/ directory on disk, so
 * renderer.font.load can tell "read this file" from "read this baked asset"
 * without guessing at path shapes. */
#define STUDIO_ASSET_PREFIX "@assets"

struct lua_State;
/* Install the searcher that resolves require("core.doc") out of the table
 * above. Call before the bootstrap runs. */
void studio_assets_open(struct lua_State *L);

#endif
