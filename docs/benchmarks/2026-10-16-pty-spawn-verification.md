# BMUX-109: macOS PTY launch through a fresh C entry

Two paced ASAN runs with the BMUX-107 attachment fix reached 100/100 live
attachments and then failed resource sampling on dead owned PTY fixture PIDs.
The preserved [failure and crash evidence](2026-10-16-attachment-admission-verification.md)
identifies ASAN StackStore/calloc from `_notify_fork_child`, with an unfair-lock
corruption abort before exec. This is independent of snapshot request deadlines.

The parent already prepared allocations, environment and executable paths before
forkpty, but could not control system/runtime fork callbacks. A direct native
ASAN probe of openpty + posix_spawn with SETSID and slave stdio established the
session/process group but **did not acquire a controlling terminal**:
`tcgetpgrp(0) == -1`. Replacing forkpty with that direct sequence would break
terminal job control. Apple documents forkpty as combining openpty, fork and
login_tty, including acquisition of the controlling terminal.
[Apple openpty(3)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/openpty.3.html)
The [direct-spawn probe](profiles/2026-10-16-pty-direct-spawn-probe.c) is retained;
compile it with Apple Clang and `-fsanitize=address,undefined` and run it without
arguments. It reports the session/group and missing tty group, then exits 1.

## Launch boundary

On macOS, the native PTY transport now uses kernel posix_spawn to exec the same
executable in an internal `--boggart-pty-exec` mode. The earliest CLI, Studio and
native-test C entry points call `bpty_reexec` before application initialization.
This fresh process acquires TIOCSCTTY, changes directory and execve's the actual
program. It never forks, initializes Lua/SDL or opens the user's Boggart store.
There is no new executable to install. All other Unix platforms retain forkpty.

Spawn attributes create the session/process group and reset the same ten
signals and empty signal mask as the previous child. File actions use
CLOEXEC_DEFAULT and explicitly inherit only PTY stdio, the optional agent
control capability and an exec-status pipe. The helper marks the latter
close-on-exec, then writes the original errno on setup/exec failure. The parent
waits for that final exec boundary before returning a transport. The command's
argv (including arbitrary argv[0]), prepared environment and working directory
are retained. The same child PID survives both execs, preserving signaling,
reaping and sampling ownership. Parent-side failures retire initialized handles,
fd/action/attribute state and argv storage through existing teardown.

LLVM's current upstream ASAN implementation excludes Apple from its atfork
handler installation. The host's Apple Clang 21 runtime contains those handlers;
the observed shipped-runtime stack, rather than upstream main alone, grounds
this diagnosis. No sanitizer flags or diagnostics were disabled.
[LLVM asan_posix.cpp](https://github.com/llvm/llvm-project/blob/main/compiler-rt/lib/asan/asan_posix.cpp)

## Verification scope

The native test installs an atfork child callback that immediately exits 101 on
macOS. All PTY cases must survive without invoking it. The same test checks tty,
session and foreground-group identity; non-CLOEXEC fd isolation; large queued
input; resize; exit/EOF; shutdown and deferred cleanup; uv_spawn coexistence;
allocation failures; invalid command/directory and failed exec. A context case
verifies custom argv[0], environment values containing spaces, changed working
directory, restored SIGINT default and an unblocked SIGTERM after the parent
ignored/blocked them. Existing agent channel/environment tests exercise the
optional inherited control descriptor through the actual CLI/Studio boundary.

This adds one fresh exec per macOS PTY launch. It removes inherited fork runtime
state, and does not claim lower launch latency or CPU/RSS. Linux/BSD/Windows
behavior has not been executed on this macOS host. Future executables embedding
bpty must invoke `bpty_reexec` as their first C entry action on macOS.

## Results

- Focused normal native/control/Studio/Fleet suite: **18/18, 52.72s**,
  including the paced 100-pane workflow
  ([log](profiles/2026-10-16-pty-spawn-normal.txt)).
- Focused ASAN/UBSan native/control/Studio/Fleet suite: **17/17, 51.15s**,
  excluding the separately repeated paced workflow
  ([log](profiles/2026-10-16-pty-spawn-asan.txt)).
- The [normal paced coordinator report](2026-10-16-pty-spawn-normal.json)
  records 100 attached panes and samples all 100 PTYs, one server and one Studio.
  This run includes the explicit 60ms capture delay and is a correctness check,
  not a product timing measurement.
- Three consecutive ASAN paced 100-pane workflows passed: **35.14s, 34.93s,
  34.74s**. The deterministic no-fork native test passed three consecutive runs
  in the same invocation; combined elapsed time **113.07s**
  ([repeat log](profiles/2026-10-16-pty-spawn-asan-repeated.txt)).
- The final [ASAN coordinator report](2026-10-16-pty-spawn-asan.json),
  [client trace](2026-10-16-pty-spawn-client-asan.json) and
  [server trace](2026-10-16-pty-spawn-server-asan.json) preserve the last repeat.
  The normal [client](2026-10-16-pty-spawn-client-normal.json) and
  [server](2026-10-16-pty-spawn-server-normal.json) traces are retained too.
- Independent [audit](profiles/2026-10-16-pty-spawn-audit.txt), with its
  [Lua script](profiles/2026-10-16-pty-spawn-audit.lua), verifies both reports:
  102 owned live PIDs sampled before/after (100 PTYs, server, Studio), 100
  successful snapshots/first stream events, peak handshake concurrency four,
  valid terminal frame, and current captured source/binary/asset identities.
- After strengthening invalid-command/cwd/exec checks to require exact errno,
  the final native test passed again normally (**3.57s**,
  [log](profiles/2026-10-16-pty-spawn-native-final-normal.txt)) and under ASAN
  (**4.62s**, [log](profiles/2026-10-16-pty-spawn-native-final-asan.txt)). Product
  sources/binaries remained unchanged during this final test-only adjustment.

The [second pre-fix crash excerpt](2026-10-16-pty-spawn-before-recheck-crash.json)
also confirms the same ASAN fork-child stack, matching a dead PID from the
retained recheck. Both pre-fix failures remain in the BMUX-107 evidence; later
passing runs do not erase them. The provisional startup/RTT budgets and
competitive cmux/Ghostty comparison remain separate work.
