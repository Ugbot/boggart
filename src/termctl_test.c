/*
 * termctl_test.c -- standalone smoke test for the termctl layer.
 *
 * Builds with NO cmake, NO SDL, NO rest-of-app:
 *     cc -std=c11 -O2 -Isrc/vendor/libuv/include -o /tmp/tctest \
 *       src/termctl.c src/bunicode.c src/btunicode.c src/termctl_test.c \
 *       build/libuv/libuv.a -lpthread
 * Run (feed /dev/null so input polls hit EOF and it exits cleanly):
 *     timeout 5 /tmp/tctest < /dev/null
 *
 * It draws a bordered box with a title and a fake status line, flushes one
 * frame, then -- following the scheduler-owned model -- runs the caller's own
 * loop calling tc_poll once per iteration for up to ~1.5s OR until a keypress,
 * then shuts down and prints "termctl ok".
 */
#include "termctl.h"
#include "lgrapheme.h"

/* Regression checks remain active in RelWithDebInfo/Release test binaries. */
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* Box-drawing glyphs (U+250x). */
#define TL 0x250C /* down+right  */
#define TR 0x2510 /* down+left   */
#define BL 0x2514 /* up+right    */
#define BR 0x2518 /* up+left     */
#define HZ 0x2500 /* horizontal  */
#define VT 0x2502 /* vertical    */

static void draw_box(int x, int y, int w, int h, int fg, int bg) {
    if (w < 2 || h < 2) return;
    for (int i = 1; i < w - 1; i++) {
        tc_set(x + i, y, HZ, fg, bg, 0);
        tc_set(x + i, y + h - 1, HZ, fg, bg, 0);
    }
    for (int j = 1; j < h - 1; j++) {
        tc_set(x, y + j, VT, fg, bg, 0);
        tc_set(x + w - 1, y + j, VT, fg, bg, 0);
    }
    tc_set(x, y, TL, fg, bg, 0);
    tc_set(x + w - 1, y, TR, fg, bg, 0);
    tc_set(x, y + h - 1, BL, fg, bg, 0);
    tc_set(x + w - 1, y + h - 1, BR, fg, bg, 0);
}

static void paint(void) {
    int W, H;
    tc_size(&W, &H);

    tc_clear();

    /* Outer border */
    draw_box(0, 0, W, H - 1, 244, -1);

    /* Title, centred on the top border, in reverse+bold */
    const char *title = " termctl smoke test ";
    int tw = (int)strlen(title);
    int tx = (W - tw) / 2;
    if (tx < 1) tx = 1;
    tc_puts(tx, 0, title, 15, 4, TC_BOLD | TC_REVERSE);

    /* Body text */
    tc_puts(3, 2, "Hand-rolled full-screen terminal control (B0).", 250, -1, 0);
    tc_puts(3, 3, "Double-buffered cell grid, diff-based flush.", 250, -1, 0);
    tc_puts(3, 4, "Wide glyphs:  CJK ",  245, -1, 0);
    tc_puts(21, 4, "\xE6\x97\xA5\xE6\x9C\xAC", 220, -1, TC_BOLD); /* 日本 */
    tc_puts(3, 6, "Press any key to exit, or wait ~1.5s...", 39, -1, TC_DIM);

    /* Fake status line on the last row: a solid bar across the full width. */
    char status[256];
    snprintf(status, sizeof(status),
             " model: claude-opus-4  | local | ctx 12%%  | 3 agents ");
    for (int x = 0; x < W; x++)
        tc_set(x, H - 1, ' ', 15, 236, 0); /* paint the bar background */
    tc_puts(0, H - 1, status, 15, 236, TC_BOLD);

    tc_flush();
}

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6;
}

static void assert_prefix(const char *text) {
    size_t size = tc_snapshot_size();
    char *snapshot = malloc(size + 1);
    assert(snapshot);
    assert(tc_snapshot(snapshot, size + 1) == size);
    assert(!memcmp(snapshot, text, strlen(text)));
    free(snapshot);
}

static void clusters(void) {
    const char accent[] = "e\xcc\x81";
    const char joined[] = "\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x92\xbb";
    const char flag[] = "\xf0\x9f\x87\xac\xf0\x9f\x87\xa7";
    int w, h;
    tc_size(&w, &h);
    assert(w >= 10 && h > 0);
    /* Capture the actual emitter, not only the front-buffer snapshot. */
    FILE *capture = tmpfile();
    assert(capture);
    int saved = dup(STDOUT_FILENO);
    assert(saved >= 0 && dup2(fileno(capture), STDOUT_FILENO) >= 0);
    tc_clear();
    assert(tc_put_cluster(0, 0, accent, sizeof accent - 1, 1, 7, -1, 0));
    assert(tc_put_cluster(1, 0, joined, sizeof joined - 1, 2, 7, -1, 0));
    assert(tc_put_cluster(3, 0, flag, sizeof flag - 1, 2, 7, -1, 0));
    tc_flush();
    assert_prefix("e\xcc\x81\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x92\xbb\xf0\x9f\x87\xac\xf0\x9f\x87\xa7");
    off_t emitted = lseek(fileno(capture), 0, SEEK_CUR);
    assert(emitted > 0);
    rewind(capture);
    char *ansi = calloc((size_t)emitted + 1, 1);
    assert(ansi && fread(ansi, 1, (size_t)emitted, capture) == (size_t)emitted);
    assert(strstr(ansi, accent) && strstr(ansi, joined) && strstr(ansi, flag));
    free(ansi);
    fseek(capture, 0, SEEK_END);
    tc_flush();
    assert(lseek(fileno(capture), 0, SEEK_CUR) == emitted); /* no delta */

    /* Changing only a suffix must repaint despite identical leading scalar. */
    assert(tc_put_cluster(0, 0, "e\xcc\x80", 3, 1, 7, -1, 0));
    tc_flush();
    assert(lseek(fileno(capture), 0, SEEK_CUR) > emitted);
    assert_prefix("e\xcc\x80");
    /* Replacing either half removes the entire old owner. A wide write can
     * consume another wide owner on its right, including that owner's tail. */
    tc_set(2, 0, 'x', 7, -1, 0);
    tc_flush();
    assert_prefix("e\xcc\x80 x");
    assert(tc_put_cluster(0, 0, joined, sizeof joined - 1, 2, 7, -1, 0));
    assert(tc_put_cluster(2, 0, flag, sizeof flag - 1, 2, 7, -1, 0));
    assert(tc_put_cluster(1, 0, joined, sizeof joined - 1, 2, 7, -1, 0));
    tc_flush();
    assert_prefix(" \xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x92\xbb ");
    tc_clear();
    tc_set(w - 1, 0, 'x', 7, -1, 0);
    assert(!tc_put_cluster(w - 1, 0, joined, sizeof joined - 1, 2, 7, -1, 0));
    tc_flush();
    char row[512];
    assert(w < (int)sizeof row - 2);
    memset(row, ' ', (size_t)w); row[w] = '\n'; row[w + 1] = 0;
    assert_prefix(row); /* clipped wide cluster leaves no orphan */

    tc_set(0, 0, 'Q', 7, -1, 0);
    const char *invalid[] = {"\x1b[2J", "\xc0\xaf", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xc2\x9b", "ab"};
    for (size_t i = 0; i < sizeof invalid / sizeof *invalid; i++)
        assert(!tc_put_cluster(0, 0, invalid[i], strlen(invalid[i]), 1, 7, -1, 0));
    assert(!tc_put_cluster(0, 0, "a\0b", 3, 1, 7, -1, 0));
    assert(!tc_put_cluster(0, 0, accent, sizeof accent - 1, 0, 7, -1, 0));
    tc_flush(); assert_prefix("Q");

    char long_cluster[LG_LIMIT * 2 + 1];
    long_cluster[0] = 'a';
    for (size_t i = 0; i < LG_LIMIT; i++) {
        long_cluster[1 + i * 2] = (char)0xcc;
        long_cluster[2 + i * 2] = (char)0x81;
    }
    assert(tc_put_cluster(0, 0, long_cluster, sizeof long_cluster - 2, 1, 7, -1, 0));
    assert(!tc_put_cluster(0, 0, long_cluster, sizeof long_cluster, 1, 7, -1, 0));
    tc_flush();
    long_cluster[sizeof long_cluster - 2] = 0;
    assert_prefix(long_cluster); /* full native cap, no small-inline truncation */
    char tiny[3] = {'!', '!', '!'};
    assert(tc_snapshot(tiny, sizeof tiny) == 0 && tiny[0] == 0);
    tc_request_resize();
    tc_event resize = tc_poll(0);
    assert(resize.type == TCEV_RESIZE && resize.mx == w && resize.my == h);
    assert_prefix(long_cluster); /* geometry refresh preserves unchanged grid */
    tc_clear();
    assert(tc_puts(0, 0, "e\xcc\x81\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x92\xbb\xf0\x9f\x87\xac\xf0\x9f\x87\xa7", 7, -1, 0) == 5);
    tc_flush();
    assert_prefix("e\xcc\x81\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x92\xbb\xf0\x9f\x87\xac\xf0\x9f\x87\xa7");
    tc_clear();
    assert(tc_puts(0, 0, "a\x1b\xc2\x9b\xff" "b", 7, -1, 0) == 3);
    tc_flush(); assert_prefix("a\xef\xbf\xbd" "b");
    tc_clear(); tc_flush(); assert_prefix("     ");
    /* The terminal SDK deliberately groups these sequences differently from
     * UAX #29. A relay must preserve the source cluster and its explicit width. */
    const char *profiles[] = {"\u05c6\u0301\u05c8\u05c9", "\u1cf5\u0995"};
    for (size_t i = 0; i < sizeof profiles / sizeof *profiles; i++) {
        assert(tc_put_cluster(0, 0, profiles[i], strlen(profiles[i]), 2, 7, -1, 0));
        tc_flush(); assert_prefix(profiles[i]); tc_clear();
    }
    /* Caller-supplied source widths are authoritative, including clusters
     * narrowed by the native terminal's right-edge variation-selector rules. */
    assert(tc_put_cluster(0, 0, "\xe2\x9d\xa4", 3, 1, 7, -1, 0));
    tc_set(1, 0, 'X', 7, -1, 0);
    tc_flush(); assert_prefix("\xe2\x9d\xa4X");
    assert(dup2(saved, STDOUT_FILENO) >= 0);
    close(saved); fclose(capture);
}

int main(void) {
    /* Width regressions from the old partial termctl table, independent of
     * tty availability: Hebrew/Kawi marks, a flag component and an unassigned
     * character in a formerly blanket-wide emoji range. */
    const struct { uint32_t cp; int width; } widths[] = {
        {0x059f, 0}, {0x11f00, 0}, {0x1f1e6, 2}, {0x1f02c, 1}, {0x00ad, 1}
    };
    for (size_t i = 0; i < sizeof widths / sizeof *widths; i++) {
        if (tc_wcwidth(widths[i].cp) != widths[i].width) {
            fprintf(stderr, "width mismatch at U+%04X\n", (unsigned)widths[i].cp);
            return 1;
        }
    }
    if (tc_init() != 0) {
        fprintf(stderr, "tc_init failed\n");
        return 1;
    }

    clusters();
    paint();

    /* The caller owns the loop: one poll + (re)paint per iteration. */
    double deadline = now_ms() + 1500.0;
    int got_key = 0;
    for (;;) {
        tc_event ev = tc_poll(100);
        if (ev.type == TCEV_KEY) {
            got_key = 1;
            break;
        }
        if (ev.type == TCEV_RESIZE) {
            paint();
        }
        if (now_ms() >= deadline) break;
    }

    tc_shutdown();

    /* Proof of clean teardown for the harness. */
    printf("termctl ok (%s)\n", got_key ? "keypress" : "timeout");
    fflush(stdout);
    return 0;
}
