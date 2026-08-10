#ifndef BOGGART_EMBEDDED_H
#define BOGGART_EMBEDDED_H
#include <stddef.h>

/* Look up a baked-in Lua module by name ("boot", "api", "tools/wc", ...).
 * Returns a pointer to the (non-NUL-terminated) source and its length via
 * *len, or NULL if there is no such module. */
const char *boggart_embedded_get(const char *name, size_t *len);

/* Enumerate the embedded modules (for `boggart init`). */
size_t boggart_embedded_count(void);
const char *boggart_embedded_name(size_t i);

#endif
