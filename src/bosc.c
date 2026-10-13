/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/osc.zig
 * ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/osc/parsers/change_window_title.zig
 * ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/osc/parsers/report_pwd.zig
 * ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/osc/parsers/hyperlink.zig
 * ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/osc/parsers/osc9.zig
 * ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/osc/parsers/kitty_desktop_notification.zig
 * ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/osc/parsers/rxvt_extension.zig
 * ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/osc/parsers/semantic_prompt.zig
 * ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/osc/parsers/clipboard_operation.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE.
 * Adaptation: bounded borrowed slices and stricter UTF-8/URI/base64 validation.
 */
#include "bosc.h"
#include <string.h>
static bool equal(bosc_slice s, const char *text) { size_t n = strlen(text); return s.length == n && (!n || !memcmp(s.data, text, n)); }
static bool split(bosc_slice *s, uint8_t separator, bosc_slice *head) {
  const uint8_t *p = s->length ? memchr(s->data, separator, s->length) : NULL;
  if (!p) return false;
  head->data = s->data; head->length = (size_t)(p - s->data);
  s->length -= head->length + 1; s->data = p + 1; return true;
}
static bool alpha(uint8_t c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }
static bool digit(uint8_t c) { return c >= '0' && c <= '9'; }
static bool hex(uint8_t c) { return digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'); }
bool bosc_text(bosc_slice s, bool multiline) {
  size_t i = 0;
  while (i < s.length) {
    uint32_t cp; uint8_t a = s.data[i++]; unsigned n;
    if (a < 0x80) { cp = a; n = 0; }
    else if (a >= 0xc2 && a <= 0xdf) { cp = a & 31u; n = 1; }
    else if (a >= 0xe0 && a <= 0xef) { cp = a & 15u; n = 2; }
    else if (a >= 0xf0 && a <= 0xf4) { cp = a & 7u; n = 3; }
    else return false;
    if (n > s.length - i) return false;
    for (unsigned j = 0; j < n; j++) {
      uint8_t c = s.data[i++]; if (c < 0x80 || c > 0xbf) return false;
      cp = (cp << 6) | (c & 63u);
    }
    if ((n == 1 && cp < 0x80) || (n == 2 && cp < 0x800) || (n == 3 && cp < 0x10000)
      || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) return false;
    if ((cp < 32 || (cp >= 127 && cp <= 159)) && !(multiline && (cp == 9 || cp == 10 || cp == 13))) return false;
  }
  return true;
}
bool bosc_uri(bosc_slice s) {
  if (!s.length || !alpha(s.data[0]) || !bosc_text(s, false)) return false;
  size_t colon = 1;
  while (colon < s.length && s.data[colon] != ':') {
    uint8_t c = s.data[colon++]; if (!alpha(c) && !digit(c) && c != '+' && c != '-' && c != '.') return false;
  }
  if (colon + 1 >= s.length) return false;
  for (size_t i = colon + 1; i < s.length; i++) {
    uint8_t c = s.data[i]; if (c <= 32 || c == 127) return false;
    if (c < 128 && !alpha(c) && !digit(c) && !strchr(":/?#[]@!$&'()*+,;=-._~%", c)) return false;
    if (c == '%') { if (i + 2 >= s.length || !hex(s.data[i + 1]) || !hex(s.data[i + 2])) return false; i += 2; }
  }
  return true;
}
static int base64_digit(uint8_t c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  return c == '+' ? 62 : c == '/' ? 63 : -1;
}
static bool decode(bosc_slice input, uint8_t *scratch, bosc_slice *output) {
  size_t n = input.length, pad = 0;
  while (n && input.data[n - 1] == '=') { n--; pad++; }
  if (pad > 2 || n % 4 == 1 || (pad && (input.length % 4 || pad != (4 - n % 4) % 4))) return false;
  size_t written = 0; uint32_t value = 0; unsigned bits = 0;
  for (size_t i = 0; i < n; i++) {
    int d = base64_digit(input.data[i]); if (d < 0) return false;
    value = (value << 6) | (unsigned)d; bits += 6;
    if (bits >= 8) { bits -= 8; scratch[written++] = (uint8_t)(value >> bits); }
  }
  if (bits && (value & ((1u << bits) - 1))) return false;
  *output = (bosc_slice){scratch, written}; return true;
}
static bool signed_number(bosc_slice s, int32_t *result) {
  if (!s.length) return false;
  bool negative = s.data[0] == '-'; size_t i = negative ? 1 : 0; uint64_t value = 0;
  if (i == s.length) return false;
  for (; i < s.length; i++) {
    if (!digit(s.data[i])) return false;
    value = value * 10 + s.data[i] - '0'; if (value > (negative ? UINT64_C(2147483648) : INT32_MAX)) return false;
  }
  *result = negative ? (int32_t)(-(int64_t)value) : (int32_t)value; return true;
}
static bool identifier(bosc_slice s) {
  if (s.length > 256) return false;
  for (size_t i = 0; i < s.length; i++) if (!alpha(s.data[i]) && !digit(s.data[i]) && s.data[i] != '_' && s.data[i] != '-') return false;
  return true;
}
static bool kitty(bosc_slice s, uint8_t *scratch, bosc_command *c) {
  bosc_slice metadata; if (!split(&s, ';', &metadata)) return false;
  c->type = BOSC_NOTIFY; c->value.notify.done = true; c->value.notify.urgency = 1;
  bool encoded = false;
  while (metadata.length) {
    bosc_slice item; if (!split(&metadata, ':', &item)) { item = metadata; metadata.length = 0; }
    if (item.length < 3 || !alpha(item.data[0]) || item.data[1] != '=') return false;
    bosc_slice value = {item.data + 2, item.length - 2};
    for (size_t i = 0; i < value.length; i++)
      if (value.data[i] < 33 || value.data[i] > 126 || value.data[i] == ':' || value.data[i] == ';' || value.data[i] == '=' || value.data[i] == '\\') return false;
    switch (item.data[0]) {
      case 'i': if (!identifier(value)) return false; c->value.notify.id = value; break;
      case 'd': if (!equal(value, "0") && !equal(value, "1")) return false; c->value.notify.done = equal(value, "1"); break;
      case 'e': if (!equal(value, "0") && !equal(value, "1")) return false; encoded = equal(value, "1"); break;
      case 'u': c->value.notify.urgency_set = true; if (equal(value, "0")) c->value.notify.urgency = 0; else if (equal(value, "2")) c->value.notify.urgency = 2; break;
      case 'p':
        if (equal(value, "title")) c->value.notify.payload = BOSC_NOTIFY_TITLE;
        else if (equal(value, "body")) c->value.notify.payload = BOSC_NOTIFY_BODY;
        else if (equal(value, "close")) c->value.notify.payload = BOSC_NOTIFY_CLOSE;
        else if (equal(value, "?")) c->value.notify.payload = BOSC_NOTIFY_QUERY;
        else return false;
        break;
      default: break; /* Future notification UI options are opaque and inert. */
    }
  }
  if (c->value.notify.payload == BOSC_NOTIFY_CLOSE || c->value.notify.payload == BOSC_NOTIFY_QUERY) return s.length == 0;
  if (encoded) { if (!decode(s, scratch, &s)) return false; }
  if (!bosc_text(s, true)) return false;
  if (c->value.notify.payload == BOSC_NOTIFY_TITLE) c->value.notify.title = s; else c->value.notify.body = s;
  return true;
}
bool bosc_parse(const uint8_t *data, size_t length, bool bel, uint8_t scratch[BOSC_MAX_PAYLOAD], bosc_command *c) {
  memset(c, 0, sizeof *c);
  if (!length || length > BOSC_MAX_PAYLOAD) return false;
  bosc_slice s = {data, length}, code;
  if (!split(&s, ';', &code) || !code.length || code.length > 4) return false;
  for (size_t i = 0; i < code.length; i++) { if (!digit(code.data[i])) return false; c->code = c->code * 10 + code.data[i] - '0'; }
  switch (c->code) {
    case 0: case 2: c->type = BOSC_TITLE; c->value.text = s; return bosc_text(s, false);
    case 7:
      c->type = BOSC_CWD; c->value.text = s;
      if (!s.length) return true;
      if (s.length < 8 || memcmp(s.data, "file://", 7) || !bosc_uri(s)) return false;
      return memchr(s.data + 7, '/', s.length - 7) != NULL && !memchr(s.data, '?', s.length) && !memchr(s.data, '#', s.length);
    case 8: {
      bosc_slice options; if (!split(&s, ';', &options) || !bosc_text(options, false)) return false;
      c->type = BOSC_HYPERLINK; c->value.link.uri = s;
      while (options.length) {
        bosc_slice item; if (!split(&options, ':', &item)) { item = options; options.length = 0; }
        bosc_slice key; if (split(&item, '=', &key) && equal(key, "id")) c->value.link.id = item;
      }
      if (c->value.link.id.length > 256) return false;
      return s.length ? bosc_uri(s) : !c->value.link.id.length;
    }
    case 9: {
      /* ConEmu subcommands must never turn into desktop notifications. */
      bosc_slice rest = s, prefix; int32_t number;
      if (equal(s, "10") || (s.length >= 2 && s.data[0] == '1' && s.data[1] == '2')) return false;
      if (split(&rest, ';', &prefix) && signed_number(prefix, &number) && number >= 1 && number <= 12) return false;
      c->type = BOSC_NOTIFY; c->value.notify.title = s; c->value.notify.done = true; c->value.notify.urgency = 1;
      return s.length && bosc_text(s, true);
    }
    case 99: return kitty(s, scratch, c);
    case 777: {
      bosc_slice extension, title; if (!split(&s, ';', &extension) || !equal(extension, "notify") || !split(&s, ';', &title)) return false;
      c->type = BOSC_NOTIFY; c->value.notify.title = title; c->value.notify.body = s;
      c->value.notify.done = true; c->value.notify.urgency = 1;
      return (title.length || s.length) && bosc_text(title, true) && bosc_text(s, true);
    }
    case 133: {
      if (!s.length || !strchr("LABICDNP", s.data[0]) || (s.length > 1 && s.data[1] != ';') || !bosc_text(s, false)) return false;
      c->type = BOSC_SHELL; c->value.shell.mark = (char)s.data[0];
      if (s.length > 1) {
        s.data += 2; s.length -= 2; c->value.shell.options = s;
        if (c->value.shell.mark == 'D' && s.length) {
          bosc_slice first = s, tail = s; split(&tail, ';', &first);
          if (!memchr(first.data, '=', first.length)) {
            if (!signed_number(first, &c->value.shell.status)) return false;
            c->value.shell.has_status = true;
          }
        }
      }
      return true;
    }
    case 52: {
      bosc_slice selection; if (!split(&s, ';', &selection) || selection.length > 1) return false;
      char kind = selection.length ? (char)selection.data[0] : 'c';
      if (!kind || !strchr("cps01234567", kind)) return false;
      c->type = BOSC_CLIPBOARD; c->value.clipboard.selection = kind; c->value.clipboard.bel = bel;
      c->value.clipboard.query = equal(s, "?");
      if (c->value.clipboard.query) return true;
      if (!decode(s, scratch, &c->value.clipboard.text)) return false;
      return bosc_text(c->value.clipboard.text, true);
    }
    default: return false;
  }
}
