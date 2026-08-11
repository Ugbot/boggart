/* bogpaths.h -- where boggart keeps its data, decided in one place.
 *
 * The rule this codebase runs on is that C owns capabilities with their policy
 * attached and Lua asks rather than infers (see sys.caps() in lsys.c). A path
 * layout is exactly that kind of policy: it is per-platform, it has a legacy
 * case that must not be got wrong, and every component that touches it -- the
 * harness (bog.userdir), the credential file (lauth.c), the installer -- has to
 * agree. So it is decided here, once, and everyone else asks.
 *
 * The implementation lives in lsys.c rather than a file of its own so that no
 * target in CMakeLists.txt has to learn a new source name; both boggart and
 * boggart-studio already compile lsys.c and lauth.c.
 */
#ifndef BOGGART_PATHS_H
#define BOGGART_PATHS_H

#include <stddef.h>

/* Fill `out` with boggart's data directory and, if `source` is non-NULL, point
 * it at a short static string naming the rule that chose it (for `doctor`).
 * Returns 0, or -1 when there is no home directory at all -- no $HOME and no
 * password-file entry -- in which case `out` is untouched and the caller must
 * report that rather than guess. */
int boggart_data_dir(char *out, size_t n, const char **source);

/* The legacy location, ~/.boggart, whether or not it exists. Returns 0, or -1
 * when there is no home directory. */
int boggart_legacy_dir(char *out, size_t n);

/* mkdir -p. 0 on success, a libuv error code (< 0) otherwise. */
int boggart_mkdir_p(const char *path);

#endif
