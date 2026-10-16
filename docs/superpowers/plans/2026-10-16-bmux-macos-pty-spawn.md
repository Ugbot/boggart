# BMUX-109: macOS PTY launch without inherited fork runtime

The registered paced ASAN test fails after all 100 attachments are ready because
one or more PTY fixture children abort before exec. Retained macOS reports name
ASAN StackStore/calloc in `_notify_fork_child`, with an unfair-lock corruption
abort. The existing child already avoids application allocation after fork;
the failure occurs inside system/runtime fork callbacks before that code runs.

A direct openpty + posix_spawn probe under ASAN creates a session/process-group
leader but tcgetpgrp(0) fails: opening/duplicating the slave in spawn file actions
does not acquire a controlling terminal on this host. Merely decomposing
forkpty into openpty/fork retains the same runtime callbacks. Changing sanitizer
settings would weaken the verification instead of fixing launch ownership.

Use macOS posix_spawn to re-exec the current executable in an internal C-only
PTY launch mode. The earliest CLI/Studio/native-test entry handles this mode
before Lua/SDL/application initialization. Spawn attributes establish the
session and reset the same signals/mask. File actions allow only PTY stdio,
the optional agent control capability and an exec-status pipe. The fresh helper
acquires TIOCSCTTY, changes working directory and execve's the requested program
with the exact prepared argv/environment. It does not fork. The original PID
survives both execs, so process-group signaling/reaping/resource ownership stay
unchanged. Parent marks the status pipe close-on-exec only inside the helper;
EOF then means the final command exec succeeded, while failures retain errno.
No separate executable or runtime language is introduced. Other Unix backends
keep forkpty. All intermediate fd/actions/attribute/argv failures must clean up.

Verify native PTY controlling-terminal/foreground-group checks, fd isolation,
large input, resize, shutdown, concurrent uv_spawn, failed exec/cwd, allocation
failures and agent environment/control channels normally and under ASAN. Repeat
the unchanged registered paced 100-pane workflow with all owned fixture PIDs
included in resource sampling; retain pre-fix failures and new reports. Rebuild
both binaries before source-fingerprint-checked runs, with no builds during tests.

Primary references: Apple openpty(3)/forkpty and macOS SDK spawn.h/sys/spawn.h;
LLVM asan_posix.cpp fork-handler implementation. The host's Apple Clang 21
runtime has atfork symbols even though upstream main currently excludes Apple
from that handler; do not infer exact shipped behavior from upstream main.
