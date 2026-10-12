/* bogcrash.c -- what boggart says when it dies (BOG-9).
 *
 * Until now a crash left one artefact: macOS's .ips report, which has the C
 * frames but nothing about the Lua that was running, and nothing at all on
 * Linux. This handler, installed first thing in main() of both the CLI and
 * the studio, writes a short report to stderr AND to
 * <data dir>/crashes/crash-<time>-<pid>.txt:
 *
 *   * the signal, and for a bad memory access the address and whether it was
 *     near NULL (a missing check) or wild (corruption / use-after-free);
 *   * the C stack (backtrace_symbols_fd);
 *   * the Lua stack of the main interpreter -- source:line per frame, read
 *     with lua_getstack/lua_getinfo, which do not allocate;
 *
 * then runs the registered emergency hooks (the TUI's terminal restore) and
 * re-raises with the default action, so the exit status and the OS crash
 * report are unchanged.
 *
 * Signal safety: everything after the fault uses write(2) and pre-computed
 * paths. Reading the Lua stack is best-effort: if the crash happened INSIDE
 * Lua and left it inconsistent, a second fault in the handler is caught (the
 * handler is not re-entered; the default action runs) and an alarm(2) bounds
 * any hang to two seconds. The C frames are written before the Lua ones so
 * the reliable part is always on disk first.
 *
 * Windows: an unhandled-exception filter after Venus's venus_crash.c writes
 * the exception code, the faulting address and module+offset frames (no
 * symbols needed, ASLR-proof). Compiled there; not exercised by this repo's CI
 * yet. */
#include "bogcrash.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "lua.h"
#include "lauxlib.h"
#include "bogpaths.h"

#define MAX_HOOKS 8
static void (*g_hooks[MAX_HOOKS])(void);
static int g_nhooks = 0;
static lua_State *g_L = NULL;
static char g_dir[1024];
static volatile int g_in_crash = 0;
static int g_installed = 0;

void bog_crash_on_fatal(void (*fn)(void)) {
  if (fn && g_nhooks < MAX_HOOKS) g_hooks[g_nhooks++] = fn;
}
void bog_crash_set_lua(lua_State *L) { g_L = L; }
int bog_crash_installed(void) { return g_installed; }
const char *bog_crash_dir(void) { return g_dir; }

#ifndef _WIN32
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>
#include <time.h>
#include <sys/stat.h>
#include <execinfo.h>

static int g_fd = -1;

/* ---- async-signal-safe output ---------------------------------------------------- */
static void out2(int fd, const char *s) { if (fd >= 0 && s) { size_t n = strlen(s); while (n) { ssize_t w = write(fd, s, n); if (w <= 0) break; s += w; n -= (size_t)w; } } }
static void out(const char *s) { out2(2, s); out2(g_fd, s); }
static void out_u(unsigned long long v, int base) {
  char b[32]; int i = 31; b[i] = '\0';
  if (v == 0) b[--i] = '0';
  while (v && i > 0) { int d = (int)(v % (unsigned)base); b[--i] = (char)(d < 10 ? '0' + d : 'a' + d - 10); v /= (unsigned)base; }
  if (base == 16) { b[--i] = 'x'; b[--i] = '0'; }
  out(b + i);
}

static const char *signame(int sig) {
  switch (sig) {
    case SIGSEGV: return "SIGSEGV (bad memory access)";
    case SIGBUS:  return "SIGBUS (bad memory access)";
    case SIGILL:  return "SIGILL (illegal instruction)";
    case SIGFPE:  return "SIGFPE (arithmetic fault)";
    case SIGABRT: return "SIGABRT (abort)";
    case SIGTRAP: return "SIGTRAP (assertion trap)";
    default:      return "fatal signal";
  }
}

static void on_alarm(int sig) { (void)sig; out("\n(crash report: Lua stack read timed out)\n"); signal(SIGABRT, SIG_DFL); abort(); }

static void lua_frames(void) {
  if (!g_L) { out("Lua stack: (no interpreter registered)\n"); return; }
  out("Lua stack (innermost first):\n");
  lua_Debug ar;
  for (int level = 0; level < 48 && lua_getstack(g_L, level, &ar); level++) {
    if (!lua_getinfo(g_L, "Sl", &ar)) break;
    out("  ");
    out(ar.short_src);
    if (ar.currentline > 0) { out(":"); out_u((unsigned long long)ar.currentline, 10); }
    if (ar.what && strcmp(ar.what, "C") == 0) out("  [C]");
    out("\n");
  }
}

static void on_crash(int sig, siginfo_t *info, void *uctx) {
  (void)uctx;
  if (g_in_crash) {           /* faulted inside the handler: give up cleanly */
    signal(sig, SIG_DFL);
    raise(sig);
    return;
  }
  g_in_crash = 1;

  /* the report file: crash-<epoch>-<pid>.txt, built without stdio */
  if (g_dir[0]) {
    char path[1200];
    char num[32];
    size_t n = strlen(g_dir);
    memcpy(path, g_dir, n);
    const char *pre = "/crash-";
    memcpy(path + n, pre, 7); n += 7;
    unsigned long long parts[2] = { (unsigned long long)time(NULL), (unsigned long long)getpid() };
    for (int k = 0; k < 2; k++) {
      int i = 31; num[i] = '\0';
      unsigned long long v = parts[k];
      if (v == 0) num[--i] = '0';
      while (v && i > 0) { num[--i] = (char)('0' + v % 10); v /= 10; }
      size_t m = strlen(num + i);
      memcpy(path + n, num + i, m); n += m;
      path[n++] = k == 0 ? '-' : '.';
    }
    memcpy(path + n, "txt", 4);
    g_fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  }

  out("\n==== boggart crashed: ");
  out(signame(sig));
  out(" ====\n");
  if ((sig == SIGSEGV || sig == SIGBUS) && info) {
    unsigned long long a = (unsigned long long)(uintptr_t)info->si_addr;
    out("fault address ");
    out_u(a, 16);
    out(a < 4096 ? "  (near NULL: a missing check)\n" : "  (wild: corruption or use-after-free)\n");
  }
  out("C stack:\n");
  void *frames[64];
  int nf = backtrace(frames, 64);
  backtrace_symbols_fd(frames, nf, 2);
  if (g_fd >= 0) backtrace_symbols_fd(frames, nf, g_fd);

  signal(SIGALRM, on_alarm);
  alarm(2);
  lua_frames();
  alarm(0);

  if (g_dir[0]) { out("report: "); out(g_dir); out("/\n"); }
  if (g_fd >= 0) { close(g_fd); g_fd = -1; }

  for (int i = 0; i < g_nhooks; i++) g_hooks[i]();   /* e.g. the TUI's terminal restore */

  signal(sig, SIG_DFL);
  raise(sig);
}

void bog_crash_install(void) {
  if (g_installed) return;
  g_installed = 1;
  char dir[1024];
  if (boggart_data_dir(dir, sizeof(dir), NULL) == 0) {
    snprintf(g_dir, sizeof(g_dir), "%s/crashes", dir);
    boggart_mkdir_p(g_dir);
  }
  /* backtrace() loads its unwinder lazily (malloc); do it now, not mid-crash */
  void *warm[2];
  (void)backtrace(warm, 2);

  /* an alternate stack, so a stack overflow can still be reported */
  static char altstack[64 * 1024];
  stack_t ss;
  memset(&ss, 0, sizeof(ss));
  ss.ss_sp = altstack;
  ss.ss_size = sizeof(altstack);
  sigaltstack(&ss, NULL);

  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_sigaction = on_crash;
  sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
  sigemptyset(&sa.sa_mask);
  int sigs[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP };
  for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) sigaction(sigs[i], &sa, NULL);
}

void bog_crash_set_dir(const char *dir) {
  snprintf(g_dir, sizeof(g_dir), "%s", dir ? dir : "");
  if (g_dir[0]) boggart_mkdir_p(g_dir);
}

#else /* _WIN32 ------------------------------------------------------------------------ */
#include <windows.h>

static LONG WINAPI on_exception(EXCEPTION_POINTERS *ep) {
  if (g_in_crash) return EXCEPTION_CONTINUE_SEARCH;
  g_in_crash = 1;
  char path[1200];
  snprintf(path, sizeof(path), "%s\\crash-%lu-%lu.txt", g_dir, (unsigned long)GetTickCount(), (unsigned long)GetCurrentProcessId());
  FILE *f = g_dir[0] ? fopen(path, "w") : NULL;
  DWORD code = ep->ExceptionRecord->ExceptionCode;
  void *addr = ep->ExceptionRecord->ExceptionAddress;
  fprintf(stderr, "\n==== boggart crashed: exception 0x%08lx at %p ====\n", (unsigned long)code, addr);
  if (f) fprintf(f, "boggart crashed: exception 0x%08lx at %p\n", (unsigned long)code, addr);
  if (code == EXCEPTION_ACCESS_VIOLATION && ep->ExceptionRecord->NumberParameters >= 2) {
    ULONG_PTR bad = ep->ExceptionRecord->ExceptionInformation[1];
    const char *kind = bad < 4096 ? "near NULL: a missing check" : "wild: corruption or use-after-free";
    fprintf(stderr, "fault address 0x%llx (%s)\n", (unsigned long long)bad, kind);
    if (f) fprintf(f, "fault address 0x%llx (%s)\n", (unsigned long long)bad, kind);
  }
  void *frames[32];
  USHORT nf = CaptureStackBackTrace(0, 32, frames, NULL);
  for (USHORT i = 0; i < nf; i++) {
    HMODULE mod = NULL;
    char name[MAX_PATH] = "?";
    if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           (LPCSTR)frames[i], &mod) && mod) GetModuleFileNameA(mod, name, sizeof(name));
    unsigned long long off = mod ? (unsigned long long)((char *)frames[i] - (char *)mod) : 0;
    const char *base = strrchr(name, '\\'); base = base ? base + 1 : name;
    fprintf(stderr, "  %s+0x%llx\n", base, off);
    if (f) fprintf(f, "  %s+0x%llx\n", base, off);
  }
  if (g_L) {
    lua_Debug ar;
    for (int level = 0; level < 48 && lua_getstack(g_L, level, &ar); level++) {
      if (!lua_getinfo(g_L, "Sl", &ar)) break;
      fprintf(stderr, "  lua %s:%d\n", ar.short_src, ar.currentline);
      if (f) fprintf(f, "  lua %s:%d\n", ar.short_src, ar.currentline);
    }
  }
  if (f) fclose(f);
  for (int i = 0; i < g_nhooks; i++) g_hooks[i]();
  return EXCEPTION_CONTINUE_SEARCH;
}

void bog_crash_install(void) {
  if (g_installed) return;
  g_installed = 1;
  char dir[1024];
  if (boggart_data_dir(dir, sizeof(dir), NULL) == 0) {
    snprintf(g_dir, sizeof(g_dir), "%s\\crashes", dir);
    boggart_mkdir_p(g_dir);
  }
  SetUnhandledExceptionFilter(on_exception);
}

void bog_crash_set_dir(const char *dir) {
  snprintf(g_dir, sizeof(g_dir), "%s", dir ? dir : "");
  if (g_dir[0]) boggart_mkdir_p(g_dir);
}
#endif
