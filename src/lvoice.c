/* lvoice.c -- native voice input: whisper.cpp transcription (+ miniaudio capture).
 *
 * "Speak and/or type." This module is the shared core behind voice dictation in
 * both front ends (the cTUI and the studio): mic capture and speech-to-text both
 * happen in-process, so there is no external `whisper` binary, no HTTP server,
 * and no temp-file round trip. The Lua surfaces call the same `voice` global and
 * insert recognised text at the cursor as the user speaks -- the box stays
 * keyboard-editable throughout (see lua/tui.lua / studio agentview.lua).
 *
 * ----------------------------------------------------------------------------
 * BUILD GUARD
 * ----------------------------------------------------------------------------
 * The whole audio stack (whisper.cpp + GGML + miniaudio) is heavy, so it is
 * opt-in behind the CMake option BOGGART_VOICE (default OFF). This translation
 * unit is ALWAYS compiled into both binaries; only the code that touches whisper
 * and miniaudio is #ifdef BOGGART_VOICE. Built without it, `voice` still exists
 * as a global -- voice.built()==false and voice.available()==false -- so the
 * front ends can hide the affordance and /voice can say how to turn it on. That
 * keeps the default build and CI free of the dependency.
 *
 * ----------------------------------------------------------------------------
 * THREADING (phase 2, capture + streaming)
 * ----------------------------------------------------------------------------
 * miniaudio's capture callback runs on its own high-priority audio thread and
 * writes PCM into a lock-free ring; a dedicated transcription thread drains that
 * ring, runs whisper over a rolling window, and hands transcript deltas back to
 * the main lua_State through a uv_async bound to the main loop -- the exact
 * discipline src/lworker.c uses for worker output. Nothing off the main thread
 * ever touches a lua_State.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"

#ifdef BOGGART_VOICE
#include "whisper.h"
#endif

/* whisper wants 16 kHz mono f32 PCM. These are the canonical capture params
 * too, so keep them in one place. */
#define VOICE_SAMPLE_RATE 16000
#define VOICE_CHANNELS    1

/* ---- model resolution ------------------------------------------------------
 * Policy stays tiny and lives here so `voice.available()` is a single call the
 * UI can make cheaply: $BOGGART_WHISPER_MODEL wins, else the default drop point
 * ~/.boggart/models/ggml-base.en.bin. We deliberately do NOT bundle the weights
 * (~142 MB); voice.model_path() names the expected file so a /voice download can
 * fetch it and doctor can point at it. */

/* The home directory, POSIX ($HOME) and Windows (%USERPROFILE%). Mirrors the
 * fallback order in src/lsys.c without pulling that TU in. */
static const char *voice_home(void) {
  const char *h = getenv("HOME");
  if (h && *h) return h;
#ifdef _WIN32
  h = getenv("USERPROFILE");
  if (h && *h) return h;
#endif
  return NULL;
}

/* Write the resolved model path into buf (cap bytes). Returns 1 if a path was
 * produced (whether or not the file exists), 0 if even a candidate can't be
 * formed (no HOME and no override). */
static int voice_model_path(char *buf, size_t cap) {
  const char *env = getenv("BOGGART_WHISPER_MODEL");
  if (env && *env) { snprintf(buf, cap, "%s", env); return 1; }
  const char *home = voice_home();
  if (!home) return 0;
  snprintf(buf, cap, "%s/.boggart/models/ggml-base.en.bin", home);
  return 1;
}

static int file_readable(const char *path) {
  FILE *f = fopen(path, "rb");
  if (!f) return 0;
  fclose(f);
  return 1;
}

/* voice.model_path() -> string | nil
 * The path voice looks for the model at (env override or the default drop
 * point). nil only when no home directory can be determined. */
static int l_model_path(lua_State *L) {
  char path[1024];
  if (!voice_model_path(path, sizeof path)) { lua_pushnil(L); return 1; }
  lua_pushstring(L, path);
  return 1;
}

/* voice.built() -> bool -- was this binary compiled with BOGGART_VOICE? */
static int l_built(lua_State *L) {
#ifdef BOGGART_VOICE
  lua_pushboolean(L, 1);
#else
  lua_pushboolean(L, 0);
#endif
  return 1;
}

/* voice.available() -> bool -- built AND the model file is present. (Device
 * presence is checked lazily at voice.start; transcribe_wav needs no device.) */
static int l_available(lua_State *L) {
#ifdef BOGGART_VOICE
  char path[1024];
  lua_pushboolean(L, voice_model_path(path, sizeof path) && file_readable(path));
#else
  lua_pushboolean(L, 0);
#endif
  return 1;
}

#ifdef BOGGART_VOICE

/* ---- a small, self-contained WAV reader ------------------------------------
 * Just enough of RIFF/WAVE to load the offline smoke-test fixture and any clip a
 * user hands transcribe_wav: PCM16 or IEEE-float32, mono or stereo (down-mixed),
 * any sample rate (linearly resampled to 16 kHz). Not a general decoder -- no
 * compressed formats -- which is all whisper needs. Returns a malloc'd f32 mono
 * 16 kHz buffer in *out (caller frees) and its length in *out_n, or an error
 * string (static) on failure. */
static uint32_t rd_u32(const unsigned char *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static uint16_t rd_u16(const unsigned char *p) {
  return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static const char *wav_load_f32_mono16k(const char *path, float **out, size_t *out_n) {
  *out = NULL; *out_n = 0;
  FILE *f = fopen(path, "rb");
  if (!f) return "cannot open file";
  fseek(f, 0, SEEK_END);
  long fsz = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (fsz < 44) { fclose(f); return "not a WAV file (too small)"; }
  unsigned char *buf = (unsigned char *)malloc((size_t)fsz);
  if (!buf) { fclose(f); return "out of memory"; }
  if (fread(buf, 1, (size_t)fsz, f) != (size_t)fsz) { free(buf); fclose(f); return "short read"; }
  fclose(f);

  if (memcmp(buf, "RIFF", 4) != 0 || memcmp(buf + 8, "WAVE", 4) != 0) {
    free(buf); return "not a RIFF/WAVE file";
  }

  /* Walk chunks for `fmt ` and `data`. */
  uint16_t fmt = 0, channels = 0, bits = 0;
  uint32_t rate = 0;
  const unsigned char *data = NULL;
  uint32_t data_len = 0;
  size_t off = 12;
  while (off + 8 <= (size_t)fsz) {
    const unsigned char *ck = buf + off;
    uint32_t cklen = rd_u32(ck + 4);
    const unsigned char *body = ck + 8;
    if (memcmp(ck, "fmt ", 4) == 0 && cklen >= 16 && off + 8 + 16 <= (size_t)fsz) {
      fmt = rd_u16(body);        /* 1 = PCM, 3 = IEEE float */
      channels = rd_u16(body + 2);
      rate = rd_u32(body + 4);
      bits = rd_u16(body + 14);
    } else if (memcmp(ck, "data", 4) == 0) {
      data = body;
      data_len = cklen;
      if (off + 8 + (size_t)cklen > (size_t)fsz) data_len = (uint32_t)((size_t)fsz - (off + 8));
    }
    off += 8 + cklen + (cklen & 1); /* chunks are word-aligned */
  }
  if (!data || channels == 0 || rate == 0) { free(buf); return "WAV missing fmt/data"; }
  if (!((fmt == 1 && (bits == 16 || bits == 8)) || (fmt == 3 && bits == 32))) {
    free(buf); return "unsupported WAV encoding (need PCM8/16 or float32)";
  }

  size_t bytes_per_sample = bits / 8;
  size_t frame_bytes = bytes_per_sample * channels;
  size_t frames = frame_bytes ? (data_len / frame_bytes) : 0;
  if (frames == 0) { free(buf); return "WAV has no audio frames"; }

  /* Decode + down-mix to mono f32 at the source rate. */
  float *mono = (float *)malloc(frames * sizeof(float));
  if (!mono) { free(buf); return "out of memory"; }
  for (size_t i = 0; i < frames; i++) {
    double acc = 0.0;
    const unsigned char *fp = data + i * frame_bytes;
    for (uint16_t c = 0; c < channels; c++) {
      const unsigned char *sp = fp + c * bytes_per_sample;
      double v = 0.0;
      if (fmt == 1 && bits == 16) {
        int16_t s = (int16_t)rd_u16(sp);
        v = s / 32768.0;
      } else if (fmt == 1 && bits == 8) {
        v = ((int)sp[0] - 128) / 128.0;   /* 8-bit PCM is unsigned */
      } else { /* float32 */
        uint32_t u = rd_u32(sp);
        float fv; memcpy(&fv, &u, sizeof fv);
        v = fv;
      }
      acc += v;
    }
    mono[i] = (float)(acc / channels);
  }
  free(buf);

  /* Resample to 16 kHz if needed (linear -- fine for speech recognition). */
  if (rate == VOICE_SAMPLE_RATE) {
    *out = mono; *out_n = frames;
    return NULL;
  }
  size_t out_frames = (size_t)((double)frames * VOICE_SAMPLE_RATE / (double)rate);
  if (out_frames == 0) out_frames = 1;
  float *res = (float *)malloc(out_frames * sizeof(float));
  if (!res) { free(mono); return "out of memory"; }
  for (size_t i = 0; i < out_frames; i++) {
    double src = (double)i * (double)rate / (double)VOICE_SAMPLE_RATE;
    size_t i0 = (size_t)src;
    double frac = src - (double)i0;
    size_t i1 = i0 + 1 < frames ? i0 + 1 : frames - 1;
    res[i] = (float)(mono[i0] * (1.0 - frac) + mono[i1] * frac);
  }
  free(mono);
  *out = res; *out_n = out_frames;
  return NULL;
}

/* Run whisper over a finished f32/16k/mono buffer and return the joined text.
 * Loads and frees the model each call: fine for the one-shot transcribe_wav;
 * the streaming path (phase 2) keeps a context warm instead. */
static const char *transcribe_pcm(const char *model_path, const float *pcm, size_t n,
                                  char **out_text) {
  *out_text = NULL;
  struct whisper_context_params cparams = whisper_context_default_params();
  struct whisper_context *ctx = whisper_init_from_file_with_params(model_path, cparams);
  if (!ctx) return "failed to load whisper model";

  struct whisper_full_params wparams = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
  wparams.print_progress   = false;
  wparams.print_special    = false;
  wparams.print_realtime   = false;
  wparams.print_timestamps = false;
  wparams.translate        = false;
  wparams.single_segment   = false;
  wparams.language         = "en";
  wparams.n_threads        = 4;

  if (whisper_full(ctx, wparams, pcm, (int)n) != 0) {
    whisper_free(ctx);
    return "whisper transcription failed";
  }

  /* Join the segments. */
  size_t cap = 256, len = 0;
  char *text = (char *)malloc(cap);
  if (!text) { whisper_free(ctx); return "out of memory"; }
  text[0] = '\0';
  int nseg = whisper_full_n_segments(ctx);
  for (int i = 0; i < nseg; i++) {
    const char *seg = whisper_full_get_segment_text(ctx, i);
    if (!seg) continue;
    size_t sl = strlen(seg);
    if (len + sl + 1 > cap) {
      while (len + sl + 1 > cap) cap *= 2;
      char *nt = (char *)realloc(text, cap);
      if (!nt) { free(text); whisper_free(ctx); return "out of memory"; }
      text = nt;
    }
    memcpy(text + len, seg, sl);
    len += sl;
    text[len] = '\0';
  }
  whisper_free(ctx);
  *out_text = text;
  return NULL;
}

#endif /* BOGGART_VOICE */

/* voice.transcribe_wav(path[, model_path]) -> text | nil, err
 * Offline transcription of a WAV file -- the smoke test, and a useful primitive
 * on its own. model_path defaults to voice.model_path(). */
static int l_transcribe_wav(lua_State *L) {
#ifdef BOGGART_VOICE
  const char *wav = luaL_checkstring(L, 1);
  char modelbuf[1024];
  const char *model = luaL_optstring(L, 2, NULL);
  if (!model) {
    if (!voice_model_path(modelbuf, sizeof modelbuf)) {
      lua_pushnil(L); lua_pushstring(L, "no model path (set BOGGART_WHISPER_MODEL or $HOME)");
      return 2;
    }
    model = modelbuf;
  }
  if (!file_readable(model)) {
    lua_pushnil(L);
    lua_pushfstring(L, "whisper model not found at %s (run /voice download)", model);
    return 2;
  }
  float *pcm = NULL; size_t n = 0;
  const char *err = wav_load_f32_mono16k(wav, &pcm, &n);
  if (err) { lua_pushnil(L); lua_pushstring(L, err); return 2; }
  char *text = NULL;
  err = transcribe_pcm(model, pcm, n, &text);
  free(pcm);
  if (err) { lua_pushnil(L); lua_pushstring(L, err); return 2; }
  lua_pushstring(L, text ? text : "");
  free(text);
  return 1;
#else
  (void)L;
  lua_pushnil(L);
  lua_pushstring(L, "voice support not built (configure with -DBOGGART_VOICE=ON)");
  return 2;
#endif
}

static const luaL_Reg voice_lib[] = {
  {"built",          l_built},
  {"available",      l_available},
  {"model_path",     l_model_path},
  {"transcribe_wav", l_transcribe_wav},
  {NULL, NULL},
};

int luaopen_boggart_voice(lua_State *L) {
  luaL_newlib(L, voice_lib);
  return 1;
}
