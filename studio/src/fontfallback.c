/* fontfallback.c -- find fonts on this machine to draw what ours cannot.
 *
 * THE PROBLEM. studio/data/fonts/font.ttf and monospace.ttf carry 896 and 878
 * codepoints between them: Latin, Greek, Cyrillic, and not one ideograph, not
 * one Arabic letter, not even an arrow or a box-drawing character. Everything
 * else drew as blank or as the notdef box. Fixing that by bundling is not on:
 * Noto Sans CJK alone is 10-20 MB and boggart ships one small binary.
 *
 * THE POLICY, which is why this is C and not Lua. Every desktop already has
 * the fonts. The question "can this machine draw Japanese" has a real answer
 * that only the OS knows, it is answered differently on three platforms, and
 * the answer is a *capability* -- exactly the shape sys.caps() exists for.
 * Lua asks; it does not infer from a path separator. renderer.font.fallbacks()
 * is how it asks.
 *
 * BOGGART_STUDIO_FONTS overrides the whole search with an explicit list. See
 * discover_from_env().
 *
 * HOW IT DEGRADES. Every step is allowed to fail. A candidate that is not
 * installed is skipped, a file that will not open is skipped, a font the
 * renderer cannot rasterise is skipped, and a machine that yields nothing at
 * all gets an empty chain and renders exactly what it rendered before this
 * file existed. Nothing here can stop the editor starting.
 *
 * WHAT IT DELIBERATELY REFUSES. Colour emoji fonts. Apple Color Emoji, Noto
 * Color Emoji and Segoe UI Emoji store bitmaps or layered vectors in sbix,
 * CBDT or COLR tables. Accepting one would be worse than refusing it: the cmap
 * says the codepoint is covered, so the fallback search would stop there, and
 * the emoji would come out as a blank with a correct advance and no way to
 * tell why. So probe_sfnt() rejects them by table, and on a machine whose only
 * emoji font is a colour one -- which is every stock macOS -- emoji do not
 * draw. That is a stated limit, not an oversight. A monochrome symbols font
 * (Apple Symbols, Noto Sans Symbols2, Segoe UI Symbol) does get picked up,
 * which covers arrows, box drawing, maths and dingbats.
 *
 * That rule outlived the reason it was written for. It was stb_truetype that
 * could not read those tables at all; FreeType can, and returns BGRA bitmaps.
 * Two things still stand in the way, and either alone is enough: sbix and CBDT
 * store their strikes as PNG, which needs a FreeType built against libpng --
 * ours is not, on purpose (see CMakeLists.txt) -- and the glyph atlas here is
 * one coverage per pixel multiplied by the caller's colour, so a colour glyph
 * would arrive as a silhouette even if it decoded. Colour emoji is a real
 * feature and this is where it would start; it is not a comment that needs
 * deleting.
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "uv.h"
#include "fontfallback.h"

#define MAX_FALLBACKS 16

/* A fallback is consulted once per 256-codepoint block, not once per glyph, so
 * a long chain costs little. It is capped anyway: past a dozen faces the next
 * one is not adding coverage, it is adding a file to keep open. */
static FontFallback chain[MAX_FALLBACKS];
static int chain_n = -1;   /* -1 until discovery has run */

/* A 25 MB pan-Unicode face is worth mapping. A 192 MB one is a colour emoji
 * font that probe_sfnt() will reject anyway; this is the belt to that braces,
 * so a pathological file cannot be read into memory before we look at it. */
#define MAX_FONT_BYTES (64u * 1024u * 1024u)

static uint32_t be32(const unsigned char *p) {
  return ((uint32_t) p[0] << 24) | ((uint32_t) p[1] << 16)
       | ((uint32_t) p[2] << 8)  | (uint32_t) p[3];
}

static uint16_t be16(const unsigned char *p) {
  return (uint16_t) (((uint16_t) p[0] << 8) | (uint16_t) p[1]);
}


/* Read a font's table directory and decide whether it is worth keeping.
 *
 * Header-only: a few hundred bytes per candidate, so the whole scan costs less
 * than one glyph bake even when nothing matches. Returns 1 if this file has
 * outlines we can rasterise and no colour-glyph table, 0 otherwise. */
static int probe_sfnt(const char *path) {
  FILE *fp = fopen(path, "rb");
  if (!fp) { return 0; }

  unsigned char hdr[12];
  int ok = 0;
  if (fread(hdr, 1, 12, fp) != 12) { goto done; }

  /* Offsets of each face's table directory: one for a plain font, a list for
   * a .ttc collection. */
  uint32_t offsets[16];
  int nfaces = 1;
  offsets[0] = 0;
  if (be32(hdr) == 0x74746366u) {           /* 'ttcf' */
    uint32_t n = be32(hdr + 8);
    if (n > 16) { n = 16; }
    nfaces = (int) n;
    for (int i = 0; i < nfaces; i++) {
      unsigned char b[4];
      if (fseek(fp, 12 + 4 * i, SEEK_SET) != 0) { goto done; }
      if (fread(b, 1, 4, fp) != 4) { goto done; }
      offsets[i] = be32(b);
    }
  }

  for (int i = 0; i < nfaces; i++) {
    unsigned char d[12];
    if (fseek(fp, (long) offsets[i], SEEK_SET) != 0) { goto done; }
    if (fread(d, 1, 12, fp) != 12) { goto done; }
    int ntab = be16(d + 4);
    if (ntab <= 0 || ntab > 512) { continue; }
    int has_outlines = 0;
    for (int t = 0; t < ntab; t++) {
      unsigned char rec[16];
      if (fread(rec, 1, 16, fp) != 16) { goto done; }
      /* Any colour-glyph table disqualifies the whole file: this renderer
       * cannot draw one (see the header comment), and a font we accept must
       * be one we can draw. */
      if (!memcmp(rec, "sbix", 4) || !memcmp(rec, "CBDT", 4)
          || !memcmp(rec, "COLR", 4) || !memcmp(rec, "SVG ", 4)) {
        ok = 0;
        goto done;
      }
      /* 'glyf' is TrueType outlines, 'CFF ' is PostScript ones. FreeType has
       * a driver for both, and hints both. */
      if (!memcmp(rec, "glyf", 4) || !memcmp(rec, "CFF ", 4)) { has_outlines = 1; }
    }
    if (has_outlines) { ok = 1; }
  }

done:
  fclose(fp);
  return ok;
}


static void add_candidate(const char *path) {
  if (chain_n >= MAX_FALLBACKS) { return; }
  for (int i = 0; i < chain_n; i++) {
    if (!strcmp(chain[i].path, path)) { return; }
  }

  uv_fs_t req;
  int rc = uv_fs_stat(NULL, &req, path, NULL);
  uint64_t size = (rc == 0) ? req.statbuf.st_size : 0;
  uv_fs_req_cleanup(&req);
  if (rc != 0 || size == 0 || size > MAX_FONT_BYTES) { return; }
  if (!probe_sfnt(path)) { return; }

  FontFallback *f = &chain[chain_n++];
  memset(f, 0, sizeof *f);
  snprintf(f->path, sizeof f->path, "%s", path);
}


static void add_in(const char *dir, const char *name) {
  char buf[512];
  snprintf(buf, sizeof buf, "%s/%s", dir, name);
  add_candidate(buf);
}


/* Case-insensitive "does `name` start with `prefix`". Linux font packages
 * agree on stems (NotoSansCJK, DejaVuSans) and disagree on everything after
 * them -- weight, style, version, .ttf against .ttc -- so matching a prefix is
 * the only thing that survives a distro change. */
static int starts_with_ci(const char *name, const char *prefix) {
  while (*prefix) {
    char a = *name++, b = *prefix++;
    if (a >= 'A' && a <= 'Z') { a = (char) (a - 'A' + 'a'); }
    if (b >= 'A' && b <= 'Z') { b = (char) (b - 'A' + 'a'); }
    if (a != b) { return 0; }
  }
  return 1;
}


static int is_font_name(const char *name) {
  size_t n = strlen(name);
  if (n < 5) { return 0; }
  const char *ext = name + n - 4;
  return !strcmp(ext, ".ttf") || !strcmp(ext, ".ttc")
      || !strcmp(ext, ".otf") || !strcmp(ext, ".otc")
      || !strcmp(ext, ".TTF") || !strcmp(ext, ".TTC");
}


/* Walk `dir` looking for files whose name begins with any of `stems`.
 *
 * Bounded in depth because /usr/share/fonts is a tree of vendor directories on
 * some distros and a flat directory on others, and an unbounded walk of a
 * machine with a thousand fonts installed is a startup cost nobody asked for.
 * Three levels reaches every layout fontconfig's own default config expects. */
static void scan_dir(const char *dir, const char *const *stems, int depth) {
  if (depth <= 0 || chain_n >= MAX_FALLBACKS) { return; }

  uv_fs_t req;
  if (uv_fs_scandir(NULL, &req, dir, 0, NULL) < 0) {
    uv_fs_req_cleanup(&req);
    return;
  }
  uv_dirent_t ent;
  while (uv_fs_scandir_next(&req, &ent) != UV_EOF) {
    if (ent.name[0] == '.') { continue; }
    char path[512];
    snprintf(path, sizeof path, "%s/%s", dir, ent.name);
    if (ent.type == UV_DIRENT_DIR) {
      scan_dir(path, stems, depth - 1);
      continue;
    }
    if (!is_font_name(ent.name)) { continue; }
    for (int i = 0; stems[i]; i++) {
      if (starts_with_ci(ent.name, stems[i])) { add_candidate(path); break; }
    }
    if (chain_n >= MAX_FALLBACKS) { break; }
  }
  uv_fs_req_cleanup(&req);
}


/* Order is coverage policy, and it is the whole of the visible behaviour.
 *
 * Small and specific first, broad and heavy last. A symbols font answers
 * arrows and box drawing from a couple of megabytes; the pan-Unicode face that
 * would also answer them is twenty-five, and its Latin-adjacent glyphs are not
 * as good a match for the UI. The first font in the chain that has the
 * codepoint wins, so this list is read as "prefer". */
/* BOGGART_STUDIO_FONTS overrides the search entirely: a list of font files
 * separated by the platform's path separator, used in the order given.
 *
 * Two jobs. It is the answer for someone whose font is somewhere this does not
 * look -- a Nix store path, a container, a font they prefer to the one the
 * ordering below picks -- without which the only recourse is a rebuild. And it
 * is how the no-fallbacks path gets tested: set it to empty and this machine
 * behaves exactly like one with nothing but the bundled fonts, which is a
 * state that otherwise only exists on hardware nobody developing this has. */
static int discover_from_env(void) {
  const char *spec = getenv("BOGGART_STUDIO_FONTS");
  if (!spec) { return 0; }
#ifdef _WIN32
  const char sep = ';';
#else
  const char sep = ':';
#endif
  const char *p = spec;
  while (*p) {
    const char *e = strchr(p, sep);
    size_t n = e ? (size_t) (e - p) : strlen(p);
    if (n > 0 && n < 512) {
      char buf[512];
      memcpy(buf, p, n);
      buf[n] = '\0';
      add_candidate(buf);
    }
    if (!e) { break; }
    p = e + 1;
  }
  return 1;
}


static void discover(void) {
  chain_n = 0;
  if (discover_from_env()) { return; }

#if defined(__APPLE__)
  static const char *const mac[] = {
    /* symbols, arrows, box drawing, maths -- small and monochrome */
    "/System/Library/Fonts/Apple Symbols.ttf",
    "/System/Library/Fonts/Menlo.ttc",
    /* CJK: PingFang on current macOS, Hiragino on older, STHeiti older still */
    "/System/Library/Fonts/PingFang.ttc",
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
    "/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc",
    "/System/Library/Fonts/STHeiti Light.ttc",
    /* Korean, which the Chinese faces above do not carry */
    "/System/Library/Fonts/AppleSDGothicNeo.ttc",
    /* Arabic, Hebrew, Devanagari, Thai */
    "/System/Library/Fonts/GeezaPro.ttc",
    "/System/Library/Fonts/Kohinoor.ttc",
    "/System/Library/Fonts/Supplemental/Tahoma.ttf",
    /* the catch-all: everything above and more, at 23 MB */
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
    "/Library/Fonts/Arial Unicode.ttf",
    NULL,
  };
  for (int i = 0; mac[i]; i++) { add_candidate(mac[i]); }

  /* A user's own fonts are a deliberate act, so they are worth a look, but
   * only after the system's -- someone's novelty display face should not be
   * what Japanese renders in. */
  const char *home = getenv("HOME");
  if (home) {
    char dir[512];
    snprintf(dir, sizeof dir, "%s/Library/Fonts", home);
    static const char *const stems[] = { "Noto", "DejaVu", "Unifont", NULL };
    scan_dir(dir, stems, 2);
  }

#elif defined(_WIN32)
  const char *root = getenv("SystemRoot");
  char fonts[512];
  snprintf(fonts, sizeof fonts, "%s\\Fonts", root ? root : "C:\\Windows");
  static const char *const win[] = {
    "seguisym.ttf",                 /* Segoe UI Symbol: arrows, box, dingbats */
    "msgothic.ttc", "meiryo.ttc",   /* Japanese */
    "simsun.ttc", "msyh.ttc",       /* Simplified Chinese */
    "mingliu.ttc",                  /* Traditional Chinese */
    "malgun.ttf", "gulim.ttc",      /* Korean */
    "Nirmala.ttf",                  /* Indic */
    "tahoma.ttf", "arial.ttf",      /* Arabic, Hebrew, Thai */
    "micross.ttf",
    NULL,
  };
  for (int i = 0; win[i]; i++) { add_in(fonts, win[i]); }

#else
  /* Linux has no fixed paths, only conventions. These are fontconfig's own
   * default directories, walked for the stems the common packages use --
   * fonts-noto-cjk, fonts-dejavu, fonts-liberation and their RPM equivalents
   * all land somewhere under one of these. Missing directories cost a failed
   * scandir each. */
  static const char *const stems[] = {
    "NotoSansCJK", "NotoSerifCJK", "NotoSansMono", "NotoSansSymbols",
    "NotoSansArabic", "NotoSansHebrew", "NotoSansDevanagari", "NotoSansThai",
    "NotoSans-", "NotoSansMath",
    "DejaVuSans", "DejaVuSansMono",
    "wqy-", "wqy", "uming", "ukai",              /* WenQuanYi, common on CN */
    "unifont", "LiberationSans", "FreeSans",
    "SourceHanSans", "SourceHanSerif",
    NULL,
  };
  scan_dir("/usr/share/fonts", stems, 3);
  scan_dir("/usr/local/share/fonts", stems, 3);
  const char *home = getenv("HOME");
  if (home) {
    char dir[512];
    snprintf(dir, sizeof dir, "%s/.local/share/fonts", home);
    scan_dir(dir, stems, 3);
    snprintf(dir, sizeof dir, "%s/.fonts", home);
    scan_dir(dir, stems, 3);
  }
#endif
  (void) add_in;   /* unused on the platforms that name absolute paths */
}


FontFallback* fontfallback_chain(int *n) {
  if (chain_n < 0) { discover(); }
  if (n) { *n = chain_n; }
  return chain;
}


void* fontfallback_data(FontFallback *f, size_t *size) {
  if (f->data) {
    if (size) { *size = f->size; }
    return f->data;
  }
  /* One attempt per font per session. A font that vanished between discovery
   * and first use, or that we have no permission to read, must not be retried
   * once per glyph block for the rest of the run. */
  if (f->tried) { return NULL; }
  f->tried = 1;

  FILE *fp = fopen(f->path, "rb");
  if (!fp) { return NULL; }
  if (fseek(fp, 0, SEEK_END) != 0) { fclose(fp); return NULL; }
  long len = ftell(fp);
  if (len <= 0 || (uint64_t) len > MAX_FONT_BYTES) { fclose(fp); return NULL; }
  rewind(fp);

  void *buf = malloc((size_t) len);
  if (!buf) { fclose(fp); return NULL; }
  size_t got = fread(buf, 1, (size_t) len, fp);
  fclose(fp);
  if (got != (size_t) len) { free(buf); return NULL; }

  f->data = buf;
  f->size = (size_t) len;
  if (size) { *size = f->size; }
  return buf;
}
