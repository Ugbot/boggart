#ifndef BOGGART_BPTY_H
#define BOGGART_BPTY_H
#include "bterm.h"
#include "uv.h"

/* Loop-thread-only PTY transport. The caller owns the borrowed terminal.
 * No callback enters Lua. Windows is supplied by the BMUX-22 backend. */
typedef struct bpty bpty;
typedef struct {
  const char *command, *cwd;
  char *const *argv; /* argv[0] included; NULL terminated */
  int control_fd; /* >2: sole inherited control capability; caller closes parent copy */
  char *const *env; /* NULL-terminated KEY=value overrides; borrowed during open */
} bpty_options;
typedef struct {
  int64_t pid;
  int exit_status, term_signal, error;
  bool exited, eof;
  uint64_t revision, bytes_read, read_callbacks;
  size_t queued_bytes;
} bpty_status;

/* Failure returns NULL and a libuv error. Initialized handles/children from
 * a failed start are retired by the same loop. The core remains caller-owned. */
bpty *bpty_open(uv_loop_t *loop, bterm *core, bpty_options options, int *error);
/* Detach core immediately. Caller must not access this object afterward.
 * Memory is freed after handles close and the owned child has been reaped. */
void bpty_destroy(bpty *term);
/* Application/Lua-state teardown: detach cores, kill/reap owned children and
 * retire raw uv handles before luv destroys its loop. Objects still owned by
 * callers remain valid until destroy. Call on the owning thread outside uv_run. */
void bpty_shutdown(uv_loop_t *loop);
/* All bytes accepted into a bounded queue, or no bytes accepted on failure.
 * Writable readiness drains it. A failed I/O is visible in status.error. */
int bpty_write(bpty *term, const uint8_t *bytes, size_t length);
/* Prepare parsed-grid geometry, apply TIOCSWINSZ, then commit without
 * allocation. Kernel failure aborts the prepared grid. */
int bpty_resize(bpty *term, unsigned columns, unsigned rows);
/* Status reads cached state and does no read/waitpid syscall. */
bpty_status bpty_state(const bpty *term);
/* Explicit ioctl query; result is the foreground process group, not an
 * individual foreground process. Exited/closed transports return UV_EPIPE. */
int bpty_foreground_group(const bpty *term, int64_t *group);
#endif
