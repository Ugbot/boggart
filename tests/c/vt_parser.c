#include "lvt.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "line %d: %s\n", __LINE__, #x); exit(1); } } while (0)
typedef struct {
  int type;
  uint32_t codepoint, separators;
  unsigned char final, intermediates[4], data[64];
  uint16_t params[24];
  size_t nparams, nintermediates, length;
} saved_event;
typedef struct { saved_event events[64]; size_t count; } log_events;

static void record(void *context, const lvt_event *event) {
  log_events *log = context;
  CHECK(log->count < 64);
  saved_event *saved = &log->events[log->count++];
  memset(saved, 0, sizeof *saved);
  saved->type = event->type;
  saved->codepoint = event->codepoint;
  saved->final = event->final;
  saved->separators = event->separators;
  saved->nparams = event->nparams;
  saved->nintermediates = event->nintermediates;
  saved->length = event->length;
  CHECK(event->length <= sizeof saved->data);
  if (event->length) memcpy(saved->data, event->data, event->length);
  if (event->nparams) memcpy(saved->params, event->params, event->nparams * sizeof(uint16_t));
  if (event->nintermediates) memcpy(saved->intermediates, event->intermediates, event->nintermediates);
}
static void text(lvt_parser *p, log_events *log, const char *s) {
  lvt_feed(p, (const unsigned char *)s, strlen(s), record, log);
}
static void start(lvt_parser *p, log_events *log) {
  lvt_init(p); memset(log, 0, sizeof *log);
}

int main(void) {
  lvt_parser p, other;
  log_events log, full, pieces;
  lvt_event actions[3];
  /* Every state must honour cancellation and restart, including string states
   * whose high-byte rules override the common C1 transitions. */
  for (unsigned state = 0; state < LVT_STATE_COUNT; state++) {
    for (unsigned c = 0; c < 256; c++) {
      lvt_effect effect = lvt_transition((lvt_state)state, (uint8_t)c);
      CHECK(effect.state < LVT_STATE_COUNT && effect.action < LVT_ACTION_COUNT);
    }
    CHECK(lvt_transition((lvt_state)state, 0x18).state == LVT_GROUND);
    CHECK(lvt_transition((lvt_state)state, 0x1a).state == LVT_GROUND);
    CHECK(lvt_transition((lvt_state)state, 0x1b).state == LVT_ESCAPE);
    for (unsigned c = 0x80; c < 256; c++) {
      CHECK(lvt_transition(LVT_DCS_PASSTHROUGH, (uint8_t)c).action == LVT_A_PUT);
      CHECK(lvt_transition(LVT_DCS_IGNORE, (uint8_t)c).state == LVT_DCS_IGNORE);
    }
  }
  CHECK(lvt_transition(LVT_CSI_ENTRY, ':').state == LVT_CSI_IGNORE);
  CHECK(lvt_transition(LVT_CSI_PARAM, ':').action == LVT_A_PARAM);
  CHECK(lvt_transition(LVT_OSC_STRING, 7).state == LVT_GROUND);

  start(&p, &log);
  text(&p, &log, "\033(B\033[1;4H\033[38:2::1:2:3m");
  CHECK(log.count == 3 && log.events[0].type == LVT_ESC);
  CHECK(log.events[0].intermediates[0] == '(' && log.events[0].final == 'B');
  CHECK(log.events[1].type == LVT_CSI && log.events[1].nparams == 2);
  CHECK(log.events[1].params[0] == 1 && log.events[1].params[1] == 4);
  CHECK(log.events[2].nparams == 6 && log.events[2].params[2] == 0);
  CHECK(log.events[2].separators == 31);
  text(&p, &log, "\033[1:2H");
  CHECK(log.count == 3); /* Colons only dispatch on SGR. */
  text(&p, &log, "\033[999999999999999999999999m");
  CHECK(log.events[3].params[0] == 65535);
  start(&p, &log);
  text(&p, &log, "\033[");
  for (int i = 0; i < 25; i++) text(&p, &log, "1;");
  text(&p, &log, "mX");
  CHECK(log.count == 1 && log.events[0].codepoint == 'X');

  start(&p, &log);
  text(&p, &log, "\033P1;2q");
  CHECK(log.count == 1 && log.events[0].type == LVT_DCS_HOOK);
  CHECK(log.events[0].params[1] == 2 && log.events[0].final == 'q');
  const unsigned char payload[] = { 0xc3, 0x9c, 0x18 };
  lvt_feed(&p, payload, sizeof payload, record, &log);
  CHECK(log.count == 5 && log.events[1].type == LVT_DCS_PUT);
  CHECK(log.events[2].codepoint == 0x9c && log.events[3].type == LVT_DCS_UNHOOK);
  CHECK(log.events[4].type == LVT_EXECUTE); /* Exit before transition. */
  start(&p, &log);
  text(&p, &log, "\033_abc\033\\");
  CHECK(log.events[0].type == LVT_APC_START && log.events[4].type == LVT_APC_END);
  CHECK(log.events[5].type == LVT_ESC && log.events[5].final == '\\');
  start(&p, &log);
  text(&p, &log, "\033]2;title\007\033]7;cancel\030X");
  CHECK(log.count == 3 && log.events[0].type == LVT_OSC);
  CHECK(log.events[0].length == 7 && memcmp(log.events[0].data, "2;title", 7) == 0);
  CHECK(log.events[1].type == LVT_EXECUTE && log.events[2].codepoint == 'X');
  start(&p, &log);
  text(&p, &log, "\033]");
  for (unsigned i = 0; i <= LVT_OSC_CAPACITY; i++) text(&p, &log, "a");
  text(&p, &log, "\007X");
  CHECK(log.count == 1 && log.events[0].codepoint == 'X');

  const unsigned char utf[] = { 'A', 0xc3, 0xa9, 0xe6, 0x97, 0xa5, 0xf0, 0x9f, 0x92, 0xbb };
  start(&p, &full);
  lvt_feed(&p, utf, sizeof utf, record, &full);
  CHECK(full.count == 4 && full.events[1].codepoint == 0xe9);
  CHECK(full.events[2].codepoint == 0x65e5 && full.events[3].codepoint == 0x1f4bb);
  for (size_t chunk = 1; chunk <= sizeof utf; chunk++) {
    start(&p, &pieces);
    for (size_t i = 0; i < sizeof utf; i += chunk) {
      size_t n = sizeof utf - i < chunk ? sizeof utf - i : chunk;
      lvt_feed(&p, utf + i, n, record, &pieces);
    }
    CHECK(memcmp(&full, &pieces, sizeof full) == 0);
  }
  start(&p, &log);
  const unsigned char malformed[] = { 0xc0, 0xaf, 0xed, 0xa0, 0x80, 0xc3, 0x1b, '[', 'H', 'X' };
  lvt_feed(&p, malformed, sizeof malformed, record, &log);
  CHECK(log.count == 8);
  for (size_t i = 0; i < 6; i++) CHECK(log.events[i].codepoint == 0xfffd);
  CHECK(log.events[6].type == LVT_CSI && log.events[7].codepoint == 'X');
  start(&p, &log);
  lvt_feed(&p, utf + 6, 2, record, &log);
  CHECK(log.count == 0);
  lvt_finish(&p, record, &log);
  CHECK(log.count == 1 && log.events[0].codepoint == 0xfffd);

  start(&p, &log); lvt_init(&other);
  text(&p, &log, "\033[31");
  lvt_feed(&other, (const unsigned char *)"hello", 5, NULL, NULL);
  text(&p, &log, "m");
  CHECK(log.count == 1 && log.events[0].params[0] == 31 && other.state == LVT_GROUND);
  /* Exercise every transition with fresh storage and random adversarial input.
   * This also gives sanitizer builds meaningful bounded-buffer coverage. */
  for (unsigned state = 0; state < LVT_STATE_COUNT; state++) {
    for (unsigned c = 0; c < 256; c++) {
      lvt_init(&p); p.state = (lvt_state)state;
      lvt_next(&p, (uint8_t)c, actions);
      CHECK(p.state == lvt_transition((lvt_state)state, (uint8_t)c).state);
    }
  }
  uint32_t random = 42;
  lvt_init(&p);
  for (unsigned i = 0; i < 1000000; i++) {
    random = random * 1664525u + 1013904223u;
    unsigned char c = (unsigned char)(random >> 24);
    lvt_feed(&p, &c, 1, NULL, NULL);
  }
  puts("VT parser: 3584 transitions, ordered events, UTF-8 and overflow checks passed");
  return 0;
}
