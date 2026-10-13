#include "bosc.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "line %d: %s\n", __LINE__, #x); exit(1); } } while (0)
static uint8_t scratch[BOSC_MAX_PAYLOAD];
static bosc_command command;
static bool parse(const char *s) { return bosc_parse((const uint8_t *)s, strlen(s), false, scratch, &command); }
static bool eq(bosc_slice s, const char *text) { return s.length == strlen(text) && (!s.length || !memcmp(s.data, text, s.length)); }
int main(void) {
  CHECK(parse("0;window;title") && command.type == BOSC_TITLE && eq(command.value.text, "window;title"));
  CHECK(parse("2;") && command.value.text.length == 0);
  CHECK(parse("2;caf\xc3\xa9 \xf0\x9f\x99\x82"));
  CHECK(!parse("2;\xff") && !parse("2;\xed\xa0\x80") && !parse("2;\xc0\xaf") && !parse("2;\xf4\x90\x80\x80"));
  CHECK(!parse("2;\xe2\x82") && !parse("2;\xc2\x9b") && !parse("2;line\nnext"));
  CHECK(parse("7;file:///tmp/work%20tree") && command.type == BOSC_CWD);
  CHECK(parse("7;file://remote/tmp/dir") && parse("7;"));
  CHECK(!parse("7;http://example.com/dir") && !parse("7;file://host") && !parse("7;file:///tmp/a b"));
  CHECK(!parse("7;file:///tmp/%zz") && !parse("7;file:///tmp?foo"));
  CHECK(parse("8;other=x:id=build;https://example.com/path?q=1") && command.type == BOSC_HYPERLINK);
  CHECK(eq(command.value.link.id, "build") && eq(command.value.link.uri, "https://example.com/path?q=1"));
  CHECK(parse("8;;mailto:user@example.com") && parse("8;;file:///tmp/test") && parse("8;;"));
  CHECK(!parse("8;id=a;") && !parse("8;;relative/path") && !parse("8;;http://a/<x>") && !parse("8;;https://a/%a"));
  CHECK(parse("9;finished") && command.type == BOSC_NOTIFY && eq(command.value.notify.title, "finished"));
  CHECK(!parse("9;4;3;10") && !parse("9;7;run something") && !parse("9;1;200"));
  CHECK(!parse("9;10") && !parse("9;12") && !parse("9;12;ignored"));
  CHECK(parse("777;notify;build;first;second") && eq(command.value.notify.title, "build") && eq(command.value.notify.body, "first;second"));
  CHECK(!parse("777;notify;title") && !parse("777;other;title;body"));
  CHECK(parse("99;;hello") && command.value.notify.done && command.value.notify.payload == BOSC_NOTIFY_TITLE);
  CHECK(parse("99;i=job:d=0:u=2;title") && !command.value.notify.done && command.value.notify.urgency == 2 && eq(command.value.notify.id, "job"));
  CHECK(parse("99;i=job:p=body:e=1:a=focus;Y2Fmw6k=") && eq(command.value.notify.body, "caf\xc3\xa9"));
  CHECK(parse("99;i=job:p=body:e=1;SGVsbG8") && eq(command.value.notify.body, "Hello"));
  CHECK(parse("99;i=job:p=?;") && command.value.notify.payload == BOSC_NOTIFY_QUERY);
  CHECK(parse("99;i=job:p=close;") && command.value.notify.payload == BOSC_NOTIFY_CLOSE);
  CHECK(!parse("99;p=icon;payload") && !parse("99;e=2;hello") && !parse("99;d=3;hello"));
  CHECK(!parse("99;i=a b;hello") && !parse("99;i=a=b;hello") && !parse("99;p=?;not empty"));
  CHECK(!parse("99;e=1;SGVsbG9=") && !parse("99;e=1;A") && !parse("99;e=1;===="));
  CHECK(!parse("99;e=1;AA==") && !parse("99;e=1;wK8="));
  CHECK(parse("133;A;aid=job") && command.type == BOSC_SHELL && command.value.shell.mark == 'A');
  CHECK(parse("133;D;137;aid=job") && command.value.shell.has_status && command.value.shell.status == 137);
  CHECK(parse("133;D;-2147483648") && command.value.shell.status == INT32_MIN);
  CHECK(parse("133;D;aid=job") && !command.value.shell.has_status);
  CHECK(!parse("133;Q") && !parse("133;AB") && !parse("133;D;bad") && !parse("133;D;2147483648"));
  CHECK(parse("52;;?") && command.type == BOSC_CLIPBOARD && command.value.clipboard.query && command.value.clipboard.selection == 'c');
  CHECK(parse("52;s;SGVsbG8=") && eq(command.value.clipboard.text, "Hello"));
  CHECK(parse("52;c;YQo=") && eq(command.value.clipboard.text, "a\n"));
  CHECK(parse("52;;") && !command.value.clipboard.query && !command.value.clipboard.text.length);
  CHECK(!parse("52;cc;SGVsbG8=") && !parse("52;x;SGVsbG8="));
  CHECK(!parse("52;c;SGVsbG8===") && !parse("52;c;S=GVsbG8") && !parse("52;c;SGVsbG8=garbage"));
  const uint8_t nul[] = {'5','2',';',0,';','?'};
  CHECK(!bosc_parse(nul, sizeof nul, true, scratch, &command));
  CHECK(bosc_parse((const uint8_t *)"52;c;?", 6, true, scratch, &command) && command.value.clipboard.bel);
  CHECK(!parse("9999;unknown") && !parse(";missing") && !parse("x;title"));
  uint8_t large[BOSC_MAX_PAYLOAD + 1]; memset(large, 'a', sizeof large); large[0] = '2'; large[1] = ';';
  CHECK(bosc_parse(large, BOSC_MAX_PAYLOAD, false, scratch, &command));
  CHECK(!bosc_parse(large, sizeof large, false, scratch, &command));
  uint32_t random = 9319;
  for (size_t trial = 0; trial < 10000; trial++) {
    for (size_t i = 0; i < sizeof large; i++) { random ^= random << 13; random ^= random >> 17; random ^= random << 5; large[i] = (uint8_t)random; }
    bosc_parse(large, random % sizeof large, false, scratch, &command);
    bosc_text((bosc_slice){large, random % sizeof large}, true);
  }
  puts("OSC commands: typed payloads, UTF-8/URI/base64 validation and bounds passed");
  return 0;
}
