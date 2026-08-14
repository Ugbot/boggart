/*
 * termctl_test.c -- standalone smoke test for the termctl layer.
 *
 * Builds with NO cmake, NO SDL, NO rest-of-app:
 *     cc -std=c11 -O2 -o /tmp/tctest src/termctl.c src/termctl_test.c
 * Run (feed /dev/null so input polls hit EOF and it exits cleanly):
 *     timeout 5 /tmp/tctest < /dev/null
 *
 * It draws a bordered box with a title and a fake status line, flushes one
 * frame, then -- following the scheduler-owned model -- runs the caller's own
 * loop calling tc_poll once per iteration for up to ~1.5s OR until a keypress,
 * then shuts down and prints "termctl ok".
 */
#include "termctl.h"

#include <stdio.h>
#include <string.h>
#include <time.h>

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

int main(void) {
    if (tc_init() != 0) {
        fprintf(stderr, "tc_init failed\n");
        return 1;
    }

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
