/*
 * termctl.c -- see termctl.h for the API and the ownership model.
 *
 * A single-instance, hand-rolled terminal-control layer:
 *   - termios raw mode + alternate screen + hidden cursor, restored on
 *     shutdown, atexit, and via signal handlers (crash-safe tty).
 *   - a double-buffered cell grid; tc_flush diffs and emits only deltas.
 *   - one-poll-per-call non-blocking input with ANSI escape decoding.
 *
 * C11 + POSIX. No dependencies.
 */
#define _GNU_SOURCE
#include "termctl.h"

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

/* ------------------------------------------------------------------ cell -- */
/* Fields are compared explicitly (never memcmp) so struct padding cannot
 * produce phantom diffs. fg/bg are int16_t to carry the -1 "default" sentinel.
 * A cell with ch == 0 is a "wide continuation": the right half of a 2-wide
 * glyph owned by the cell to its left; the flush skips drawing it. */
typedef struct {
    uint32_t ch;    /* Unicode scalar; ' ' when blank; 0 = wide continuation */
    int16_t  fg;    /* 0..255 palette index, or -1 = default                 */
    int16_t  bg;
    uint8_t  attr;  /* TC_* bitflags                                         */
} tc_cell;

static int cell_eq(const tc_cell *a, const tc_cell *b) {
    return a->ch == b->ch && a->fg == b->fg && a->bg == b->bg &&
           a->attr == b->attr;
}

/* ----------------------------------------------------------------- state -- */
static struct {
    int              inited;
    int              infd, outfd;
    int              tty_in, tty_out;    /* isatty() results                 */
    int              raw_active;         /* termios was switched to raw      */
    struct termios   orig;               /* saved cooked-mode settings       */

    int              w, h;
    tc_cell         *front, *back;       /* w*h cells each                    */

    /* output assembly buffer (one write() per flush) */
    char            *ob;
    size_t           oblen, obcap;

    /* input buffer: bytes read but not yet parsed into events */
    unsigned char    inbuf[128];
    int              inlen;
    int              eof;                /* stdin reached EOF                */

    volatile sig_atomic_t resized;       /* SIGWINCH flag                    */
} T;

/* =====================================================================
 * Low-level tty writes (used from normal code AND signal handlers, so
 * they must stay write(2)-only and allocation-free).
 * ===================================================================== */
static void raw_write(const char *s, size_t n) {
    while (n) {
        ssize_t k = write(T.outfd, s, n);
        if (k < 0) {
            if (errno == EINTR) continue;
            break;
        }
        s += k;
        n -= (size_t)k;
    }
}
static void raw_str(const char *s) { raw_write(s, strlen(s)); }

/* Sequences */
#define SEQ_ALT_ON   "\x1b[?1049h"
#define SEQ_ALT_OFF  "\x1b[?1049l"
#define SEQ_CUR_HIDE "\x1b[?25l"
#define SEQ_CUR_SHOW "\x1b[?25h"
#define SEQ_CLEAR    "\x1b[2J\x1b[H"
#define SEQ_SGR_RST  "\x1b[0m"
#define SEQ_MOUSE_ON  "\x1b[?1000h\x1b[?1006h"
#define SEQ_MOUSE_OFF "\x1b[?1006l\x1b[?1000l"

/* Async-signal-safe terminal restore. Safe to call more than once. */
static void restore_tty(void) {
    if (T.tty_out) {
        raw_str(SEQ_SGR_RST);
        raw_str(SEQ_MOUSE_OFF);
        raw_str(SEQ_CUR_SHOW);
        raw_str(SEQ_ALT_OFF);
    }
    if (T.raw_active) {
        tcsetattr(T.infd, TCSANOW, &T.orig);
        T.raw_active = 0;
    }
}

/* ============================================================= signals == */
static void on_signal(int sig) {
    if (sig == SIGWINCH) {
        T.resized = 1;
        return;
    }
    /* Termination / crash: put the tty back, then die with the default
     * disposition so the exit status reflects the signal. */
    restore_tty();
    signal(sig, SIG_DFL);
    raise(sig);
}

static void install_signals(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigemptyset(&sa.sa_mask);

    /* SIGWINCH must interrupt poll() (no SA_RESTART) so a resize is noticed. */
    sa.sa_flags = 0;
    sigaction(SIGWINCH, &sa, NULL);

    int fatal[] = { SIGINT, SIGTERM, SIGHUP, SIGQUIT,
                    SIGSEGV, SIGBUS, SIGABRT, SIGFPE };
    for (size_t i = 0; i < sizeof(fatal) / sizeof(fatal[0]); i++)
        sigaction(fatal[i], &sa, NULL);

    /* Never die from writing to a closed pipe; we handle short writes. */
    signal(SIGPIPE, SIG_IGN);
}

static void atexit_handler(void) { tc_shutdown(); }

/* ============================================================ geometry == */
static void query_size(int *w, int *h) {
    struct winsize ws;
    if (T.tty_out && ioctl(T.outfd, TIOCGWINSZ, &ws) == 0 &&
        ws.ws_col > 0 && ws.ws_row > 0) {
        *w = ws.ws_col;
        *h = ws.ws_row;
    } else {
        *w = 80;
        *h = 24;
    }
}

static void blank_cell(tc_cell *c) {
    c->ch = ' ';
    c->fg = -1;
    c->bg = -1;
    c->attr = 0;
}

/* (Re)allocate the grid to w*h. front is filled with an impossible sentinel so
 * the next flush repaints every cell; back is filled with blanks. */
static int alloc_grid(int w, int h) {
    if (w < 1) w = 1;
    if (h < 1) h = 1;
    size_t n = (size_t)w * (size_t)h;
    tc_cell *nf = (tc_cell *)malloc(n * sizeof(tc_cell));
    tc_cell *nb = (tc_cell *)malloc(n * sizeof(tc_cell));
    if (!nf || !nb) {
        free(nf);
        free(nb);
        return -1;
    }
    free(T.front);
    free(T.back);
    T.front = nf;
    T.back = nb;
    T.w = w;
    T.h = h;
    for (size_t i = 0; i < n; i++) {
        T.front[i].ch = 0xFFFFFFFFu; /* sentinel: forces full repaint */
        T.front[i].fg = T.front[i].bg = -2;
        T.front[i].attr = 0xFF;
        blank_cell(&T.back[i]);
    }
    return 0;
}

/* Called from tc_poll after a SIGWINCH. Resizes the grid if needed. */
static void update_size(void) {
    int w, h;
    query_size(&w, &h);
    if (w != T.w || h != T.h)
        alloc_grid(w, h); /* on OOM the old grid is kept */
}

/* ============================================================ utf-8 ===== */
/* Number of bytes in the UTF-8 sequence introduced by lead byte c (1..4);
 * 1 for an invalid lead so we can resync on a replacement char. */
static int utf8_len(unsigned char c) {
    if (c < 0x80) return 1;
    if ((c & 0xE0) == 0xC0) return 2;
    if ((c & 0xF0) == 0xE0) return 3;
    if ((c & 0xF8) == 0xF0) return 4;
    return 1;
}

/* Decode exactly `len` bytes (as returned by utf8_len) into a scalar. */
static uint32_t utf8_decode(const unsigned char *b, int len) {
    uint32_t cp;
    switch (len) {
        case 2:
            if ((b[1] & 0xC0) != 0x80) return 0xFFFD;
            cp = ((uint32_t)(b[0] & 0x1F) << 6) | (b[1] & 0x3F);
            return cp < 0x80 ? 0xFFFD : cp;
        case 3:
            if ((b[1] & 0xC0) != 0x80 || (b[2] & 0xC0) != 0x80) return 0xFFFD;
            cp = ((uint32_t)(b[0] & 0x0F) << 12) |
                 ((uint32_t)(b[1] & 0x3F) << 6) | (b[2] & 0x3F);
            return cp < 0x800 ? 0xFFFD : cp;
        case 4:
            if ((b[1] & 0xC0) != 0x80 || (b[2] & 0xC0) != 0x80 ||
                (b[3] & 0xC0) != 0x80)
                return 0xFFFD;
            cp = ((uint32_t)(b[0] & 0x07) << 18) |
                 ((uint32_t)(b[1] & 0x3F) << 12) |
                 ((uint32_t)(b[2] & 0x3F) << 6) | (b[3] & 0x3F);
            return (cp < 0x10000 || cp > 0x10FFFF) ? 0xFFFD : cp;
        default:
            return b[0];
    }
}

static int utf8_encode(uint32_t cp, char *out) {
    if (cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) cp = 0xFFFD;
    if (cp < 0x80) {
        out[0] = (char)cp;
        return 1;
    } else if (cp < 0x800) {
        out[0] = (char)(0xC0 | (cp >> 6));
        out[1] = (char)(0x80 | (cp & 0x3F));
        return 2;
    } else if (cp < 0x10000) {
        out[0] = (char)(0xE0 | (cp >> 12));
        out[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        out[2] = (char)(0x80 | (cp & 0x3F));
        return 3;
    } else {
        out[0] = (char)(0xF0 | (cp >> 18));
        out[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
        out[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
        out[3] = (char)(0x80 | (cp & 0x3F));
        return 4;
    }
}

/* ============================================================ wcwidth === */
int tc_wcwidth(uint32_t cp) {
    if (cp == 0) return 0;
    /* C0/C1 control */
    if (cp < 0x20 || (cp >= 0x7F && cp < 0xA0)) return 0;

    /* combining / zero-width */
    if ((cp >= 0x0300 && cp <= 0x036F) || (cp >= 0x0483 && cp <= 0x0489) ||
        (cp >= 0x0591 && cp <= 0x05BD) || (cp >= 0x0610 && cp <= 0x061A) ||
        (cp >= 0x064B && cp <= 0x065F) || (cp >= 0x0670 && cp == 0x0670) ||
        (cp >= 0x06D6 && cp <= 0x06DC) || (cp >= 0x0E31 && cp == 0x0E31) ||
        (cp >= 0x1AB0 && cp <= 0x1AFF) || (cp >= 0x1DC0 && cp <= 0x1DFF) ||
        (cp >= 0x20D0 && cp <= 0x20FF) || (cp >= 0xFE20 && cp <= 0xFE2F) ||
        cp == 0x200B || cp == 0x200C || cp == 0x200D || cp == 0xFEFF ||
        (cp >= 0x0300 && cp <= 0x036F) || (cp >= 0x1160 && cp <= 0x11FF))
        return 0;

    /* wide (East Asian Wide / Fullwidth) and emoji */
    if ((cp >= 0x1100 && cp <= 0x115F) || cp == 0x2329 || cp == 0x232A ||
        (cp >= 0x2E80 && cp <= 0x303E) || (cp >= 0x3041 && cp <= 0x33FF) ||
        (cp >= 0x3400 && cp <= 0x4DBF) || (cp >= 0x4E00 && cp <= 0x9FFF) ||
        (cp >= 0xA000 && cp <= 0xA4CF) || (cp >= 0xAC00 && cp <= 0xD7A3) ||
        (cp >= 0xF900 && cp <= 0xFAFF) || (cp >= 0xFE10 && cp <= 0xFE19) ||
        (cp >= 0xFE30 && cp <= 0xFE6F) || (cp >= 0xFF00 && cp <= 0xFF60) ||
        (cp >= 0xFFE0 && cp <= 0xFFE6) || (cp >= 0x1F300 && cp <= 0x1FAFF) ||
        (cp >= 0x1F000 && cp <= 0x1F0FF) || (cp >= 0x20000 && cp <= 0x3FFFD))
        return 2;

    return 1;
}

/* ============================================================ painting == */
void tc_size(int *w, int *h) {
    if (w) *w = T.w;
    if (h) *h = T.h;
}

void tc_clear(void) {
    if (!T.back) return;
    size_t n = (size_t)T.w * (size_t)T.h;
    for (size_t i = 0; i < n; i++) blank_cell(&T.back[i]);
}

void tc_set(int x, int y, uint32_t cp, int fg, int bg, int attr) {
    if (!T.back || x < 0 || y < 0 || x >= T.w || y >= T.h) return;
    if (fg < -1 || fg > 255) fg = -1;
    if (bg < -1 || bg > 255) bg = -1;

    int idx = y * T.w + x;
    int w = tc_wcwidth(cp);
    if (w < 1) w = 1; /* store zero-width as a 1-cell base */

    /* If we are overwriting the right half of an existing wide glyph, blank
     * its orphaned left half so no stale double-width remains. */
    if (T.back[idx].ch == 0 && x > 0) blank_cell(&T.back[idx - 1]);
    /* If the current cell was itself a wide-left, blank its now-orphaned
     * continuation to the right. */
    if (x + 1 < T.w && T.back[idx + 1].ch == 0 && tc_wcwidth(T.back[idx].ch) == 2)
        blank_cell(&T.back[idx + 1]);

    T.back[idx].ch = cp;
    T.back[idx].fg = (int16_t)fg;
    T.back[idx].bg = (int16_t)bg;
    T.back[idx].attr = (uint8_t)attr;

    if (w == 2) {
        if (x + 1 < T.w) {
            T.back[idx + 1].ch = 0; /* continuation marker */
            T.back[idx + 1].fg = (int16_t)fg;
            T.back[idx + 1].bg = (int16_t)bg;
            T.back[idx + 1].attr = (uint8_t)attr;
        } else {
            /* no room for the right half: render a space instead */
            T.back[idx].ch = ' ';
        }
    }
}

int tc_puts(int x, int y, const char *s, int fg, int bg, int attr) {
    if (!s) return x;
    while (*s && x < T.w) {
        unsigned char c = (unsigned char)*s;
        int len = utf8_len(c);
        int avail = 0;
        for (int i = 0; i < len && s[i]; i++) avail++;
        if (avail < len) break; /* truncated trailing bytes */
        uint32_t cp = utf8_decode((const unsigned char *)s, len);
        s += len;
        int w = tc_wcwidth(cp);
        if (w == 0) continue; /* combining mark: skip (minimal handling) */
        tc_set(x, y, cp, fg, bg, attr);
        x += w;
    }
    return x;
}

/* ---- output buffer helpers ---- */
static void ob_reset(void) { T.oblen = 0; }
static void ob_ensure(size_t extra) {
    if (T.oblen + extra <= T.obcap) return;
    size_t cap = T.obcap ? T.obcap : 4096;
    while (cap < T.oblen + extra) cap *= 2;
    char *p = (char *)realloc(T.ob, cap);
    if (!p) return; /* drop output rather than crash */
    T.ob = p;
    T.obcap = cap;
}
static void ob_mem(const char *p, size_t n) {
    ob_ensure(n);
    if (T.oblen + n > T.obcap) return;
    memcpy(T.ob + T.oblen, p, n);
    T.oblen += n;
}
static void ob_str(const char *s) { ob_mem(s, strlen(s)); }
static void ob_uint(unsigned v) {
    char tmp[12];
    int i = 12;
    tmp[--i] = (char)('0' + (v % 10));
    while ((v /= 10)) tmp[--i] = (char)('0' + (v % 10));
    ob_mem(tmp + i, (size_t)(12 - i));
}

/* Emit a full SGR for (fg,bg,attr): reset, then attrs, then colours. */
static void ob_sgr(int fg, int bg, int attr) {
    ob_str("\x1b[0");
    if (attr & TC_BOLD) ob_str(";1");
    if (attr & TC_DIM) ob_str(";2");
    if (attr & TC_UNDERLINE) ob_str(";4");
    if (attr & TC_REVERSE) ob_str(";7");
    if (fg < 0) {
        ob_str(";39");
    } else {
        ob_str(";38;5;");
        ob_uint((unsigned)fg);
    }
    if (bg < 0) {
        ob_str(";49");
    } else {
        ob_str(";48;5;");
        ob_uint((unsigned)bg);
    }
    ob_str("m");
}

/* Cursor Position (1-based rows/cols). */
static void ob_cup(int x, int y) {
    ob_str("\x1b[");
    ob_uint((unsigned)(y + 1));
    ob_str(";");
    ob_uint((unsigned)(x + 1));
    ob_str("H");
}

void tc_flush(void) {
    if (!T.back || !T.front) return;
    ob_reset();

    int have_style = 0;
    int cur_fg = -999, cur_bg = -999, cur_attr = -1;
    int cx = -1, cy = -1; /* unknown cursor position */

    for (int y = 0; y < T.h; y++) {
        for (int x = 0; x < T.w; x++) {
            int idx = y * T.w + x;
            tc_cell *b = &T.back[idx];
            tc_cell *f = &T.front[idx];
            if (cell_eq(b, f)) continue;

            if (b->ch == 0) {
                /* wide continuation: drawn by its left neighbour */
                *f = *b;
                continue;
            }

            if (cx != x || cy != y) {
                ob_cup(x, y);
                cx = x;
                cy = y;
            }
            if (!have_style || b->fg != cur_fg || b->bg != cur_bg ||
                (int)b->attr != cur_attr) {
                ob_sgr(b->fg, b->bg, b->attr);
                cur_fg = b->fg;
                cur_bg = b->bg;
                cur_attr = b->attr;
                have_style = 1;
            }

            char utf[4];
            int n = utf8_encode(b->ch, utf);
            ob_mem(utf, (size_t)n);

            int w = tc_wcwidth(b->ch);
            if (w < 1) w = 1;
            cx += w;
            *f = *b;
        }
    }

    if (T.oblen) {
        /* reset SGR so a subsequent partial frame starts clean */
        ob_str(SEQ_SGR_RST);
        raw_write(T.ob, T.oblen);
    }
}

/* ============================================================ input ===== */
static void inbuf_consume(int n) {
    if (n <= 0) return;
    if (n >= T.inlen) {
        T.inlen = 0;
        return;
    }
    memmove(T.inbuf, T.inbuf + n, (size_t)(T.inlen - n));
    T.inlen -= n;
}

static void set_key(tc_event *ev, int key) {
    ev->type = TCEV_KEY;
    ev->key = key;
}

/* Parse a single event from the front of inbuf. Returns the number of bytes
 * consumed, or 0 if the buffer holds an incomplete sequence and we should wait
 * for more input (unless at EOF, in which case we always make progress). */
static int parse_one(tc_event *ev) {
    unsigned char *b = T.inbuf;
    int n = T.inlen;
    if (n == 0) return 0;
    unsigned char c = b[0];

    if (c == 0x1b) { /* ESC */
        if (n == 1) {
            if (!T.eof) return 0; /* maybe the rest of a sequence is coming */
            set_key(ev, TCK_ESC);
            return 1;
        }
        if (b[1] == '[' || b[1] == 'O') {
            char t = (char)b[1];
            if (n < 3) {
                if (!T.eof) return 0;
                set_key(ev, TCK_ESC);
                return 1;
            }
            unsigned char f = b[2];

            /* CSI/SS3 letter forms: ESC [ A / ESC O A ... */
            switch (f) {
                case 'A': set_key(ev, TCK_UP);    return 3;
                case 'B': set_key(ev, TCK_DOWN);  return 3;
                case 'C': set_key(ev, TCK_RIGHT); return 3;
                case 'D': set_key(ev, TCK_LEFT);  return 3;
                case 'H': set_key(ev, TCK_HOME);  return 3;
                case 'F': set_key(ev, TCK_END);   return 3;
                case 'P': set_key(ev, TCK_F1);    return 3;
                case 'Q': set_key(ev, TCK_F2);    return 3;
                case 'R': set_key(ev, TCK_F3);    return 3;
                case 'S': set_key(ev, TCK_F4);    return 3;
                default: break;
            }

            if (t == '[' && f == 'M') { /* X10 mouse: ESC [ M b x y */
                if (n < 6) {
                    if (!T.eof) return 0;
                    set_key(ev, TCK_ESC);
                    return 1;
                }
                ev->type = TCEV_MOUSE;
                ev->mbutton = (b[3] - 32) & 0x03;
                ev->mx = (int)b[4] - 33;
                ev->my = (int)b[5] - 33;
                if (ev->mx < 0) ev->mx = 0;
                if (ev->my < 0) ev->my = 0;
                return 6;
            }

            if (t == '[' && f == '<') { /* SGR mouse: ESC [ < b ; x ; y (M|m) */
                int i = 3, fin = -1;
                while (i < n) {
                    if (b[i] == 'M' || b[i] == 'm') {
                        fin = i;
                        break;
                    }
                    i++;
                }
                if (fin < 0) {
                    if (!T.eof) return 0;
                    set_key(ev, TCK_ESC);
                    return 1;
                }
                int bt = 0, mx = 0, my = 0, field = 0;
                for (int j = 3; j < fin; j++) {
                    if (b[j] == ';') {
                        field++;
                    } else if (b[j] >= '0' && b[j] <= '9') {
                        int d = b[j] - '0';
                        if (field == 0) bt = bt * 10 + d;
                        else if (field == 1) mx = mx * 10 + d;
                        else my = my * 10 + d;
                    }
                }
                ev->type = TCEV_MOUSE;
                ev->mbutton = bt & 0x03;
                ev->mx = mx > 0 ? mx - 1 : 0;
                ev->my = my > 0 ? my - 1 : 0;
                return fin + 1;
            }

            if (f >= '0' && f <= '9') { /* CSI number (~) forms */
                int i = 2, num = 0;
                while (i < n && b[i] >= '0' && b[i] <= '9') {
                    num = num * 10 + (b[i] - '0');
                    i++;
                }
                if (i >= n) {
                    if (!T.eof) return 0;
                    set_key(ev, TCK_ESC);
                    return 1;
                }
                unsigned char fin = b[i];
                if (fin == ';') { /* modifier present: skip to final byte */
                    int j = i + 1;
                    while (j < n && !((b[j] >= 'A' && b[j] <= 'Z') ||
                                      b[j] == '~'))
                        j++;
                    if (j >= n) {
                        if (!T.eof) return 0;
                        set_key(ev, TCK_ESC);
                        return 1;
                    }
                    fin = b[j];
                    i = j;
                }
                if (fin == '~') {
                    switch (num) {
                        case 1: case 7: set_key(ev, TCK_HOME);     break;
                        case 2:         set_key(ev, TCK_INSERT);   break;
                        case 3:         set_key(ev, TCK_DELETE);   break;
                        case 4: case 8: set_key(ev, TCK_END);      break;
                        case 5:         set_key(ev, TCK_PAGEUP);   break;
                        case 6:         set_key(ev, TCK_PAGEDOWN); break;
                        case 11:        set_key(ev, TCK_F1);       break;
                        case 12:        set_key(ev, TCK_F2);       break;
                        case 13:        set_key(ev, TCK_F3);       break;
                        case 14:        set_key(ev, TCK_F4);       break;
                        case 15:        set_key(ev, TCK_F5);       break;
                        case 17:        set_key(ev, TCK_F6);       break;
                        case 18:        set_key(ev, TCK_F7);       break;
                        case 19:        set_key(ev, TCK_F8);       break;
                        case 20:        set_key(ev, TCK_F9);       break;
                        case 21:        set_key(ev, TCK_F10);      break;
                        case 23:        set_key(ev, TCK_F11);      break;
                        case 24:        set_key(ev, TCK_F12);      break;
                        default:        set_key(ev, TCK_ESC);      break;
                    }
                    return i + 1;
                }
                if (fin >= 'A' && fin <= 'Z') { /* e.g. ESC [ 1 ; 5 A */
                    switch (fin) {
                        case 'A': set_key(ev, TCK_UP);    break;
                        case 'B': set_key(ev, TCK_DOWN);  break;
                        case 'C': set_key(ev, TCK_RIGHT); break;
                        case 'D': set_key(ev, TCK_LEFT);  break;
                        case 'H': set_key(ev, TCK_HOME);  break;
                        case 'F': set_key(ev, TCK_END);   break;
                        default:  set_key(ev, TCK_ESC);   break;
                    }
                    return i + 1;
                }
            }

            /* Unknown CSI/SS3: consume the 3 bytes we understood as ESC. */
            set_key(ev, TCK_ESC);
            return 1;
        }

        /* ESC followed by something else: report ESC, leave the rest. */
        set_key(ev, TCK_ESC);
        return 1;
    }

    /* Named control keys */
    if (c == '\r' || c == '\n') { set_key(ev, TCK_ENTER);     return 1; }
    if (c == '\t')              { set_key(ev, TCK_TAB);       return 1; }
    if (c == 0x7F || c == 0x08) { set_key(ev, TCK_BACKSPACE); return 1; }

    if (c < 0x20) { /* other control byte -> ctrl-<letter> */
        set_key(ev, TCK_CTRL);
        if (c == 0)              ev->codepoint = ' ';          /* ctrl-@   */
        else if (c < 27)         ev->codepoint = 'a' + c - 1;  /* ctrl-a.. */
        else                     ev->codepoint = '@' + c;      /* \ ] ^ _  */
        return 1;
    }

    /* Printable ASCII / UTF-8 */
    {
        int len = utf8_len(c);
        if (len > n) {
            if (!T.eof) return 0; /* wait for the rest of the sequence */
            set_key(ev, TCK_CHAR);
            ev->codepoint = 0xFFFD;
            return 1;
        }
        set_key(ev, TCK_CHAR);
        ev->codepoint = utf8_decode(b, len);
        return len;
    }
}

static void nap_ms(int ms) {
    if (ms <= 0) return;
    struct timespec ts;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
}

tc_event tc_poll(int timeout_ms) {
    tc_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = TCEV_NONE;
    ev.key = TCK_NONE;

    /* A pending resize takes priority and is reported immediately. */
    if (T.resized) {
        T.resized = 0;
        update_size();
        ev.type = TCEV_RESIZE;
        ev.mx = T.w;
        ev.my = T.h;
        return ev;
    }

    /* Drain any already-buffered event without polling. */
    if (T.inlen > 0) {
        int used = parse_one(&ev);
        if (used > 0) {
            inbuf_consume(used);
            return ev;
        }
        /* incomplete: fall through to read more (unless at EOF) */
    }

    if (T.eof) {
        /* stdin is closed: honour the timeout so callers don't busy-spin,
         * then report NONE (or a resize that arrived while sleeping). */
        nap_ms(timeout_ms);
        if (T.resized) {
            T.resized = 0;
            update_size();
            ev.type = TCEV_RESIZE;
            ev.mx = T.w;
            ev.my = T.h;
        }
        return ev;
    }

    /* Exactly one poll() per call. */
    struct pollfd pfd;
    pfd.fd = T.infd;
    pfd.events = POLLIN;
    pfd.revents = 0;
    int r = poll(&pfd, 1, timeout_ms);
    if (r < 0) {
        if (errno == EINTR && T.resized) {
            T.resized = 0;
            update_size();
            ev.type = TCEV_RESIZE;
            ev.mx = T.w;
            ev.my = T.h;
        }
        return ev; /* NONE */
    }
    if (r == 0) return ev; /* timed out -> NONE */

    int space = (int)sizeof(T.inbuf) - T.inlen;
    if (space <= 0) { /* pathological: buffer full of an unparsed blob */
        T.inlen = 0;
        space = (int)sizeof(T.inbuf);
    }
    ssize_t got = read(T.infd, T.inbuf + T.inlen, (size_t)space);
    if (got <= 0) {
        T.eof = 1;
        return ev; /* NONE */
    }
    T.inlen += (int)got;

    int used = parse_one(&ev);
    if (used > 0) inbuf_consume(used);
    return ev; /* event, or NONE if still incomplete */
}

/* ============================================================ lifecycle = */
int tc_init(void) {
    if (T.inited) return 0;

    T.infd = STDIN_FILENO;
    T.outfd = STDOUT_FILENO;
    T.tty_in = isatty(T.infd);
    T.tty_out = isatty(T.outfd);
    T.inlen = 0;
    T.eof = 0;
    T.resized = 0;

    /* Raw mode (only meaningful on a real tty). */
    if (T.tty_in && tcgetattr(T.infd, &T.orig) == 0) {
        struct termios raw = T.orig;
        raw.c_iflag &= ~(unsigned)(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
        raw.c_oflag &= ~(unsigned)(OPOST);
        raw.c_cflag |= (unsigned)(CS8);
        raw.c_lflag &= ~(unsigned)(ECHO | ICANON | IEXTEN | ISIG);
        raw.c_cc[VMIN] = 0;
        raw.c_cc[VTIME] = 0;
        if (tcsetattr(T.infd, TCSAFLUSH, &raw) == 0) T.raw_active = 1;
    }

    query_size(&T.w, &T.h);
    if (alloc_grid(T.w, T.h) != 0) {
        restore_tty();
        return -1;
    }

    install_signals();
    atexit(atexit_handler);

    if (T.tty_out) {
        raw_str(SEQ_ALT_ON);
        raw_str(SEQ_CUR_HIDE);
        raw_str(SEQ_MOUSE_ON);
        raw_str(SEQ_CLEAR);
    }

    T.inited = 1;
    return 0;
}

void tc_shutdown(void) {
    if (!T.inited) return;
    restore_tty();
    free(T.front);
    free(T.back);
    free(T.ob);
    T.front = T.back = NULL;
    T.ob = NULL;
    T.oblen = T.obcap = 0;
    T.w = T.h = 0;
    T.inited = 0;
}
