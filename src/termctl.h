/*
 * termctl.h -- boggart's dependency-free full-screen terminal-control layer.
 *
 * This is "B0" from docs/cli-plan.md: a small, hand-rolled termctl providing
 * termios raw mode, the alternate screen buffer, a double-buffered cell grid,
 * and non-blocking input decoding. Zero dependencies beyond C11 + POSIX.
 * Builds and runs on macOS and Linux.
 *
 * ----------------------------------------------------------------------------
 * OWNERSHIP MODEL (read this before using the API)
 * ----------------------------------------------------------------------------
 * termctl does NOT own a loop. It never blocks waiting for a frame and never
 * spins its own event loop. The *caller* (in boggart, the Lua scheduler in
 * sched.lua) owns the outer loop and drives termctl one frame at a time:
 *
 *     tc_init();
 *     for (;;) {                       // the SCHEDULER owns this loop
 *         // 1. INPUT: exactly one non-blocking poll per iteration.
 *         tc_event ev = tc_poll(timeout_ms);
 *         if (ev.type == TCEV_KEY && ev.key == TCK_CTRL &&
 *             ev.codepoint == 'q') break;
 *         if (ev.type == TCEV_RESIZE) { ...geometry changed... }
 *
 *         // 2. PAINT: mutate the back buffer, then one flush.
 *         tc_clear();
 *         tc_puts(0, 0, "hi", 7, -1, 0);
 *         tc_flush();                  // diffs back vs front, emits deltas
 *
 *         // ...the scheduler also services agents / HTTP here...
 *     }
 *     tc_shutdown();
 *
 * poll and paint are deliberately separate calls. tc_poll performs exactly
 * one poll() syscall (or consumes one already-buffered event) and returns
 * immediately -- there is no internal read loop, so an in-flight agent HTTP
 * request never stalls behind terminal input. One frame per scheduler
 * iteration, never the other way round.
 *
 * ----------------------------------------------------------------------------
 * CORRECTNESS: the terminal is always restored
 * ----------------------------------------------------------------------------
 * Raw mode, the alternate screen, cursor visibility and mouse tracking are all
 * restored on tc_shutdown(), on a normal exit (atexit hook), AND from signal
 * handlers for SIGINT, SIGTERM, SIGHUP, SIGQUIT and the fatal crash signals
 * (SIGSEGV/SIGBUS/SIGABRT/SIGFPE) -- for those the tty is restored and the
 * signal is re-raised with the default disposition. A crash therefore never
 * leaves a wedged tty. SIGWINCH is caught to flag a resize, surfaced as a
 * TCEV_RESIZE event from the next tc_poll (never handled inside the signal).
 *
 * If stdin/stdout is not a tty (piped, or fed from /dev/null) termctl degrades
 * gracefully: no termios/alt-screen changes are made, tc_poll reports EOF as
 * timed-out NONE events, and the cell-grid API still works.
 */
#ifndef BOGGART_TERMCTL_H
#define BOGGART_TERMCTL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- attributes (bitflags for the `attr` argument) ---------------------- */
#define TC_BOLD       0x01
#define TC_DIM        0x02
#define TC_UNDERLINE  0x04
#define TC_REVERSE    0x08

/* ---- colours ------------------------------------------------------------
 * Colours are 256-colour palette indices (0..255), emitted as portable
 * 38;5;n / 48;5;n SGR. Pass -1 (TC_DEFAULT) for the terminal's default
 * foreground/background (SGR 39 / 49). */
#define TC_DEFAULT (-1)

/* ---- event model -------------------------------------------------------- */
enum tc_evtype {
    TCEV_NONE = 0,   /* poll timed out; nothing happened                     */
    TCEV_KEY,        /* a key was pressed; inspect .key / .codepoint         */
    TCEV_RESIZE,     /* terminal was resized; new size in .mx (w), .my (h)   */
    TCEV_MOUSE       /* a mouse event; .mx/.my (0-based cell), .mbutton      */
};

/* Logical keys. For TCK_CHAR the Unicode scalar is in .codepoint. For
 * TCK_CTRL the control letter is in .codepoint ('a'..'z', or the symbol for
 * ctrl-\, ], ^, _ , and space for ctrl-@). */
enum tc_key {
    TCK_NONE = 0,
    TCK_CHAR,        /* printable character; .codepoint holds the scalar     */
    TCK_ENTER,
    TCK_TAB,
    TCK_BACKSPACE,
    TCK_ESC,
    TCK_UP, TCK_DOWN, TCK_LEFT, TCK_RIGHT,
    TCK_HOME, TCK_END, TCK_PAGEUP, TCK_PAGEDOWN,
    TCK_INSERT, TCK_DELETE,
    TCK_CTRL,        /* ctrl-<letter>; letter in .codepoint                  */
    TCK_F1, TCK_F2, TCK_F3, TCK_F4, TCK_F5, TCK_F6,
    TCK_F7, TCK_F8, TCK_F9, TCK_F10, TCK_F11, TCK_F12
};

typedef struct {
    int      type;       /* enum tc_evtype                                   */
    int      key;        /* enum tc_key (valid when type == TCEV_KEY)        */
    uint32_t codepoint;  /* Unicode scalar (TCK_CHAR) or ctrl letter (TCK_CTRL) */
    int      mods;       /* reserved for modifier flags; currently 0         */
    int      mx, my;     /* mouse col/row (0-based) or, for RESIZE, w/h      */
    int      mbutton;    /* mouse button (0=left,1=middle,2=right,...)       */
} tc_event;

/* ---- lifecycle ---------------------------------------------------------- */

/* Enter raw mode + alternate screen, hide the cursor, install signal
 * handlers, allocate the double-buffered grid. Idempotent (a second call is a
 * no-op). Returns 0 on success, -1 on allocation failure. Safe to call when
 * stdin/stdout is not a tty: it simply skips the termios/screen changes. */
int  tc_init(void);

/* Restore the terminal completely (cursor, alt-screen, raw mode, mouse) and
 * free the grid. Idempotent, and also run automatically at process exit. */
void tc_shutdown(void);

/* ---- geometry ----------------------------------------------------------- */

/* Current grid size in cells. Either pointer may be NULL. Updated whenever a
 * TCEV_RESIZE is returned by tc_poll. */
void tc_size(int *w, int *h);

/* Snapshot the on-screen (front) buffer as UTF-8 rows (NUL-terminated), for
 * tests/verification. Returns bytes written. */
size_t tc_snapshot(char *out, size_t cap);

/* ---- back-buffer painting ----------------------------------------------
 * All drawing mutates the *back* buffer only; nothing reaches the screen
 * until tc_flush(). Out-of-range coordinates are clipped silently. */

/* Reset the entire back buffer to blanks (space, default colours). */
void tc_clear(void);

/* Write a single Unicode codepoint at cell (x,y). A wide (CJK/emoji) codepoint
 * occupies two cells; a zero-width codepoint is treated as width 1. */
void tc_set(int x, int y, uint32_t codepoint, int fg, int bg, int attr);

/* Write a UTF-8 string starting at (x,y), advancing x by each glyph's display
 * width (0 for combining marks, 2 for wide glyphs, else 1). Stops at the right
 * edge. Returns the x column just past the last glyph written. */
int  tc_puts(int x, int y, const char *utf8, int fg, int bg, int attr);

/* Diff the back buffer against the on-screen (front) buffer and emit ONLY the
 * changed cells as ANSI (minimal cursor moves + coalesced SGR). One write() to
 * stdout per frame. After this the front buffer matches the back buffer. */
void tc_flush(void);

/* ---- input -------------------------------------------------------------
 * Non-blocking. Performs exactly ONE poll() (up to timeout_ms; 0 = return
 * immediately, negative = block until input) or returns one already-buffered
 * event, then returns. NEVER loops internally -- the caller owns the loop.
 * Decodes the common ANSI/xterm escape sequences (arrows, home/end, page
 * up/down, insert/delete, F1-F12, SGR + X10 mouse) and ctrl-<letter>. */
tc_event tc_poll(int timeout_ms);

/* ---- utility ------------------------------------------------------------ */

/* Minimal, self-contained display width: 0 for combining/zero-width, 2 for
 * CJK/wide/emoji, 1 otherwise. */
int  tc_wcwidth(uint32_t codepoint);

#ifdef __cplusplus
}
#endif

#endif /* BOGGART_TERMCTL_H */
