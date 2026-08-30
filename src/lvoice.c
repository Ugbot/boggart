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
#include <math.h>

#include "lua.h"
#include "lauxlib.h"

#ifdef BOGGART_VOICE
#include "whisper.h"
#include "miniaudio.h"
#include "uv.h"
/* The main loop belongs to luv (src/vendor/luv). The transcription thread hands
 * transcript deltas back to the main lua_State through a uv_async on this loop,
 * exactly as src/lworker.c delivers worker output. */
extern uv_loop_t *luv_loop(lua_State *L);
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

/* Run whisper over an f32/16k/mono buffer on an already-loaded context and
 * return the joined segment text (malloc'd; caller frees). The context is the
 * caller's to own -- the one-shot path loads and frees one per call, the
 * streaming path keeps one warm. `lang` is an ISO code ("en") or NULL for auto. */
static const char *whisper_run(struct whisper_context *ctx, const float *pcm, size_t n,
                               const char *lang, char **out_text) {
  *out_text = NULL;
  struct whisper_full_params wparams = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
  wparams.print_progress   = false;
  wparams.print_special    = false;
  wparams.print_realtime   = false;
  wparams.print_timestamps = false;
  wparams.translate        = false;
  wparams.single_segment   = false;
  wparams.language         = (lang && *lang) ? lang : NULL;
  wparams.n_threads        = 4;

  if (whisper_full(ctx, wparams, pcm, (int)n) != 0)
    return "whisper transcription failed";

  size_t cap = 256, len = 0;
  char *text = (char *)malloc(cap);
  if (!text) return "out of memory";
  text[0] = '\0';
  int nseg = whisper_full_n_segments(ctx);
  for (int i = 0; i < nseg; i++) {
    const char *seg = whisper_full_get_segment_text(ctx, i);
    if (!seg) continue;
    size_t sl = strlen(seg);
    if (len + sl + 1 > cap) {
      while (len + sl + 1 > cap) cap *= 2;
      char *nt = (char *)realloc(text, cap);
      if (!nt) { free(text); return "out of memory"; }
      text = nt;
    }
    memcpy(text + len, seg, sl);
    len += sl;
    text[len] = '\0';
  }
  *out_text = text;
  return NULL;
}

/* Run whisper over a finished buffer, loading and freeing the model for the
 * call. Used by the one-shot transcribe_wav; the streaming path keeps a context
 * warm instead. */
static const char *transcribe_pcm(const char *model_path, const float *pcm, size_t n,
                                  char **out_text) {
  struct whisper_context_params cparams = whisper_context_default_params();
  struct whisper_context *ctx = whisper_init_from_file_with_params(model_path, cparams);
  if (!ctx) return "failed to load whisper model";
  const char *err = whisper_run(ctx, pcm, n, "en", out_text);
  whisper_free(ctx);
  return err;
}

/* ---- streaming: capture + live transcription -------------------------------
 * voice.start opens a mic, spins a transcription thread, and delivers a growing
 * partial transcript to the main lua_State as the user speaks; voice.stop ends
 * capture, runs a final pass, and returns the finished text. The recognised text
 * is inserted at the cursor by the front ends -- the box stays editable, so you
 * can type and dictate in the same line ("speak and/or type").
 *
 * Three threads, one lua_State. miniaudio's capture callback (its own audio
 * thread) appends f32 samples to a mutex-guarded buffer. A transcription thread
 * re-runs whisper over the whole utterance every ~0.5 s and posts the latest
 * partial. Neither touches Lua: they hand text to the main thread through a
 * uv_async, whose callback (on the main loop) calls the registered Lua handler.
 * The whisper context is loaded once and kept warm across start/stop. */

/* 120 s is the cap on a single utterance -- ample for dictation, and it bounds
 * the capture buffer at ~7.7 MB so the audio callback never allocates. */
#define VOICE_MAX_SECONDS 120
#define VOICE_MAX_SAMPLES ((size_t)VOICE_SAMPLE_RATE * VOICE_MAX_SECONDS)

typedef struct {
  /* warm model, reused across start/stop; reloaded only if the path changes */
  struct whisper_context *ctx;
  char        model[1024];
  char        lang[16];

  /* capture: miniaudio thread appends, transcription thread snapshots */
  ma_device   device;
  int         device_up;
  float      *cap;          /* whole utterance, preallocated to VOICE_MAX_SAMPLES */
  size_t      cap_len;
  uv_mutex_t  cap_mtx;

  /* transcription thread */
  uv_thread_t thread;
  int         thread_up;
  volatile int running;
  char       *final_text;   /* set by the thread on stop; l_stop reads + frees */

  /* energy VAD: auto-stop after silence_samples of quiet once speech was heard.
   * 0 disables (manual toggle only). Off by default -- opt in per start or via
   * $BOGGART_VOICE_SILENCE_MS -- so it can never cut off the toggle UX untuned. */
  long        silence_samples;
  double      vad_threshold;

  /* delivery to the main thread */
  uv_async_t  async;
  int         async_up;
  lua_State  *L;
  int         cbref;        /* Lua handler: function(kind, text) | LUA_NOREF */
  uv_mutex_t  ev_mtx;
  char       *pending_partial; /* coalesced: only the latest partial matters */
  char       *pending_final;

  int         mtx_up;       /* the two mutexes are init'd once, lazily */
} vstate;

static vstate G = { .cbref = LUA_NOREF };

/* miniaudio capture callback -- its own high-priority thread. Append the f32
 * mono frames to the utterance buffer; never allocates (cap is preallocated) and
 * silently drops past the 120 s cap. */
static void capture_cb(ma_device *dev, void *out, const void *in, ma_uint32 frames) {
  (void)out;
  vstate *g = (vstate *)dev->pUserData;
  const float *src = (const float *)in;
  if (!src || !g->cap) return;
  uv_mutex_lock(&g->cap_mtx);
  size_t room = VOICE_MAX_SAMPLES - g->cap_len;
  size_t take = frames < room ? frames : room;
  if (take) {
    memcpy(g->cap + g->cap_len, src, take * sizeof(float));
    g->cap_len += take;
  }
  uv_mutex_unlock(&g->cap_mtx);
}

/* Post the latest partial to the main thread (coalescing: a still-undelivered
 * partial is replaced, since the front end rewrites the whole dictated span). */
static void emit_partial(vstate *g, const char *text) {
  char *dup = text ? strdup(text) : NULL;
  uv_mutex_lock(&g->ev_mtx);
  free(g->pending_partial);
  g->pending_partial = dup;
  uv_mutex_unlock(&g->ev_mtx);
  uv_async_send(&g->async);
}

/* The async callback, on the main loop: drain the pending partial/final and
 * hand each to the Lua handler. Errors in the handler are swallowed -- it runs
 * off a wakeup and must never propagate. */
static void deliver(vstate *g, const char *kind, char *text) {
  if (!text) return;
  if (g->L && g->cbref != LUA_NOREF) {
    lua_State *L = g->L;
    int top = lua_gettop(L);
    lua_rawgeti(L, LUA_REGISTRYINDEX, g->cbref);
    if (lua_isfunction(L, -1)) {
      lua_pushstring(L, kind);
      lua_pushstring(L, text);
      (void)lua_pcall(L, 2, 0, 0);
    }
    lua_settop(L, top);
  }
  free(text);
}

static void voice_async_cb(uv_async_t *a) {
  (void)a;                 /* state is the file-scope singleton, not a->data */
  vstate *g = &G;
  uv_mutex_lock(&g->ev_mtx);
  char *p = g->pending_partial; g->pending_partial = NULL;
  char *f = g->pending_final;   g->pending_final = NULL;
  uv_mutex_unlock(&g->ev_mtx);
  deliver(g, "partial", p);
  deliver(g, "final", f);
}

/* The transcription thread: snapshot the utterance and re-run whisper every
 * ~0.5 s of new audio, posting the growing partial; on stop, one final pass. */
static void transcribe_thread(void *arg) {
  vstate *g = (vstate *)arg;
  const size_t step = VOICE_SAMPLE_RATE / 2;      /* re-transcribe per 0.5 s */
  const size_t minn = VOICE_SAMPLE_RATE / 3;      /* need ~0.33 s before a pass */
  float *snap = (float *)malloc(VOICE_MAX_SAMPLES * sizeof(float));
  if (!snap) return;
  size_t last_n = 0;
  /* energy-VAD bookkeeping (thread-local): scan newly-arrived samples for level,
   * remember when speech was last heard, and end after a quiet gap. */
  size_t vad_pos = 0, last_speech_n = 0;
  int seen_speech = 0, vad_done = 0;

  while (g->running) {
    uv_mutex_lock(&g->cap_mtx);
    size_t n = g->cap_len;
    if (n) memcpy(snap, g->cap, n * sizeof(float));
    uv_mutex_unlock(&g->cap_mtx);

    /* VAD: RMS of the newest chunk. Above threshold is speech; a long enough
     * gap after speech auto-stops (only when enabled). */
    if (g->silence_samples > 0 && n > vad_pos) {
      double sum = 0.0;
      for (size_t i = vad_pos; i < n; i++) sum += (double)snap[i] * snap[i];
      double rms = (n > vad_pos) ? sqrt(sum / (double)(n - vad_pos)) : 0.0;
      if (rms > g->vad_threshold) { seen_speech = 1; last_speech_n = n; }
      vad_pos = n;
      if (seen_speech && (long)(n - last_speech_n) >= g->silence_samples) {
        char *text = NULL;
        if (n > 0 && whisper_run(g->ctx, snap, n, g->lang, &text) == NULL && text) {
          uv_mutex_lock(&g->ev_mtx);
          free(g->pending_final); g->pending_final = text;
          uv_mutex_unlock(&g->ev_mtx);
          uv_async_send(&g->async);   /* deliver "final"; the UI tears down */
        } else {
          free(text);
        }
        g->running = 0;
        vad_done = 1;
        break;
      }
    }

    if (n >= minn && n >= last_n + step) {
      char *text = NULL;
      const char *err = whisper_run(g->ctx, snap, n, g->lang, &text);
      if (!err && text) emit_partial(g, text);
      free(text);
      last_n = n;
    }
    uv_sleep(80);
  }

  /* Final pass for the explicit-stop path (VAD already delivered its own). */
  if (!vad_done) {
    uv_mutex_lock(&g->cap_mtx);
    size_t n = g->cap_len;
    if (n) memcpy(snap, g->cap, n * sizeof(float));
    uv_mutex_unlock(&g->cap_mtx);
    if (n > 0) {
      char *text = NULL;
      if (whisper_run(g->ctx, snap, n, g->lang, &text) == NULL)
        g->final_text = text;   /* handed to l_stop */
      else
        free(text);
    }
  }
  free(snap);
}

/* Load (or reuse a warm) whisper context for `model`. Returns NULL on success
 * with G.ctx valid, else an error string. */
static const char *voice_warm_ctx(const char *model) {
  if (G.ctx && strcmp(G.model, model) == 0) return NULL; /* already warm */
  if (G.ctx) { whisper_free(G.ctx); G.ctx = NULL; }
  struct whisper_context_params cparams = whisper_context_default_params();
  G.ctx = whisper_init_from_file_with_params(model, cparams);
  if (!G.ctx) return "failed to load whisper model";
  snprintf(G.model, sizeof G.model, "%s", model);
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

/* voice.start(opts) -> true | nil, err
 * Open the mic and begin live transcription. opts (all optional):
 *   on_event = function(kind, text)  -- kind is "partial" (live) or "final"
 *   model    = path to a ggml model  (default voice.model_path())
 *   language = ISO code like "en"    (default "en"; "" or "auto" for detect)
 * Partials arrive on the main thread as the user speaks; voice.stop returns the
 * finished text. The input box stays editable throughout. */
static int l_start(lua_State *L) {
#ifdef BOGGART_VOICE
  if (G.running) { lua_pushnil(L); lua_pushstring(L, "already listening"); return 2; }

  int has_opts = lua_istable(L, 1);
  char modelbuf[1024];
  const char *model = NULL;
  if (has_opts) {
    lua_getfield(L, 1, "model");
    if (lua_isstring(L, -1)) { snprintf(modelbuf, sizeof modelbuf, "%s", lua_tostring(L, -1)); model = modelbuf; }
    lua_pop(L, 1);
  }
  if (!model) {
    if (!voice_model_path(modelbuf, sizeof modelbuf)) {
      lua_pushnil(L); lua_pushstring(L, "no model path (set BOGGART_WHISPER_MODEL or $HOME)"); return 2;
    }
    model = modelbuf;
  }
  if (!file_readable(model)) {
    lua_pushnil(L);
    lua_pushfstring(L, "whisper model not found at %s (run /voice download)", model);
    return 2;
  }

  /* language: opts.language, else $BOGGART_WHISPER_LANG, else "en"; "auto" (or
   * empty) lets whisper detect it. */
  G.lang[0] = '\0';
  const char *lang = NULL;
  if (has_opts) {
    lua_getfield(L, 1, "language");
    if (lua_isstring(L, -1)) lang = lua_tostring(L, -1);
    /* leave the value on the stack until copied below */
  }
  if (!lang) {
    const char *env = getenv("BOGGART_WHISPER_LANG");
    lang = (env && *env) ? env : "en";
  }
  if (strcmp(lang, "auto") != 0) snprintf(G.lang, sizeof G.lang, "%s", lang);
  if (has_opts) lua_pop(L, 1);

  /* energy VAD (opt-in): opts.silence_ms or $BOGGART_VOICE_SILENCE_MS, in ms of
   * silence after speech; opts.silence_threshold overrides the RMS gate. 0 = off
   * (the default) so the toggle UX is never cut off by an untuned detector. */
  long silence_ms = 0;
  if (has_opts) {
    lua_getfield(L, 1, "silence_ms");
    if (lua_isnumber(L, -1)) silence_ms = (long)lua_tointeger(L, -1);
    lua_pop(L, 1);
  }
  if (silence_ms == 0) {
    const char *env = getenv("BOGGART_VOICE_SILENCE_MS");
    if (env && *env) silence_ms = strtol(env, NULL, 10);
  }
  G.silence_samples = silence_ms > 0 ? silence_ms * (VOICE_SAMPLE_RATE / 1000) : 0;
  G.vad_threshold = 0.012;
  if (has_opts) {
    lua_getfield(L, 1, "silence_threshold");
    if (lua_isnumber(L, -1)) G.vad_threshold = lua_tonumber(L, -1);
    lua_pop(L, 1);
  }

  /* One-time resource init (the mutexes; the async is bound to this loop). */
  if (!G.mtx_up) {
    if (uv_mutex_init(&G.cap_mtx) != 0 || uv_mutex_init(&G.ev_mtx) != 0) {
      lua_pushnil(L); lua_pushstring(L, "voice: mutex init failed"); return 2;
    }
    G.mtx_up = 1;
  }
  if (!G.async_up) {
    if (uv_async_init(luv_loop(L), &G.async, voice_async_cb) != 0) {
      lua_pushnil(L); lua_pushstring(L, "voice: async init failed"); return 2;
    }
    /* .data stays NULL on purpose: if the state shuts down before this closes,
     * luv's loop_gc uv_close()es every handle with luv_close_cb, which returns
     * early on NULL data instead of misreading ours as a luv handle and
     * crashing (the same discipline as src/lworker.c's delivery async). */
    G.async.data = NULL;
    uv_unref((uv_handle_t *)&G.async); /* deliveries must not hold the loop open */
    G.async_up = 1;
  }

  const char *err = voice_warm_ctx(model);
  if (err) { lua_pushnil(L); lua_pushstring(L, err); return 2; }

  /* handler ref */
  G.L = L;
  if (G.cbref != LUA_NOREF) { luaL_unref(L, LUA_REGISTRYINDEX, G.cbref); G.cbref = LUA_NOREF; }
  if (has_opts) {
    lua_getfield(L, 1, "on_event");
    if (lua_isfunction(L, -1)) { G.cbref = luaL_ref(L, LUA_REGISTRYINDEX); }
    else lua_pop(L, 1);
  }

  /* capture buffer (preallocated so the audio callback never allocates) */
  if (!G.cap) {
    G.cap = (float *)malloc(VOICE_MAX_SAMPLES * sizeof(float));
    if (!G.cap) {
      if (G.cbref != LUA_NOREF) { luaL_unref(L, LUA_REGISTRYINDEX, G.cbref); G.cbref = LUA_NOREF; }
      lua_pushnil(L); lua_pushstring(L, "voice: out of memory"); return 2;
    }
  }
  G.cap_len = 0;
  free(G.final_text); G.final_text = NULL;
  uv_mutex_lock(&G.ev_mtx);
  free(G.pending_partial); G.pending_partial = NULL;
  free(G.pending_final);   G.pending_final = NULL;
  uv_mutex_unlock(&G.ev_mtx);

  /* open + start the capture device (16 kHz mono f32; miniaudio resamples) */
  ma_device_config cfg = ma_device_config_init(ma_device_type_capture);
  cfg.capture.format   = ma_format_f32;
  cfg.capture.channels = VOICE_CHANNELS;
  cfg.sampleRate       = VOICE_SAMPLE_RATE;
  cfg.dataCallback     = capture_cb;
  cfg.pUserData        = &G;
  if (ma_device_init(NULL, &cfg, &G.device) != MA_SUCCESS) {
    if (G.cbref != LUA_NOREF) { luaL_unref(L, LUA_REGISTRYINDEX, G.cbref); G.cbref = LUA_NOREF; }
    lua_pushnil(L); lua_pushstring(L, "no microphone available (or permission denied)"); return 2;
  }
  G.device_up = 1;
  if (ma_device_start(&G.device) != MA_SUCCESS) {
    ma_device_uninit(&G.device); G.device_up = 0;
    if (G.cbref != LUA_NOREF) { luaL_unref(L, LUA_REGISTRYINDEX, G.cbref); G.cbref = LUA_NOREF; }
    lua_pushnil(L); lua_pushstring(L, "could not start microphone capture"); return 2;
  }

  /* spin the transcription thread */
  G.running = 1;
  if (uv_thread_create(&G.thread, transcribe_thread, &G) != 0) {
    ma_device_stop(&G.device); ma_device_uninit(&G.device); G.device_up = 0;
    G.running = 0;
    if (G.cbref != LUA_NOREF) { luaL_unref(L, LUA_REGISTRYINDEX, G.cbref); G.cbref = LUA_NOREF; }
    lua_pushnil(L); lua_pushstring(L, "voice: could not start transcription thread"); return 2;
  }
  G.thread_up = 1;

  lua_pushboolean(L, 1);
  return 1;
#else
  (void)L;
  lua_pushnil(L);
  lua_pushstring(L, "voice support not built (configure with -DBOGGART_VOICE=ON)");
  return 2;
#endif
}

/* voice.stop() -> final_text | nil
 * Stop capture, run the final transcription pass, and return the finished text.
 * nil if we were not listening. The warm model stays loaded for the next start. */
static int l_stop(lua_State *L) {
#ifdef BOGGART_VOICE
  if (!G.running && !G.thread_up) { lua_pushnil(L); return 1; }

  if (G.device_up) ma_device_stop(&G.device);
  G.running = 0;                    /* the thread finishes with a final pass */
  if (G.thread_up) { uv_thread_join(&G.thread); G.thread_up = 0; }
  if (G.device_up) { ma_device_uninit(&G.device); G.device_up = 0; }

  /* The final supersedes any last partial still queued. */
  uv_mutex_lock(&G.ev_mtx);
  free(G.pending_partial); G.pending_partial = NULL;
  free(G.pending_final);   G.pending_final = NULL;
  uv_mutex_unlock(&G.ev_mtx);

  if (G.cbref != LUA_NOREF) { luaL_unref(L, LUA_REGISTRYINDEX, G.cbref); G.cbref = LUA_NOREF; }

  char *f = G.final_text; G.final_text = NULL;
  lua_pushstring(L, f ? f : "");
  free(f);
  return 1;
#else
  (void)L;
  lua_pushnil(L);
  return 1;
#endif
}

/* voice.listening() -> bool */
static int l_listening(lua_State *L) {
#ifdef BOGGART_VOICE
  lua_pushboolean(L, G.running ? 1 : 0);
#else
  lua_pushboolean(L, 0);
#endif
  return 1;
}

static const luaL_Reg voice_lib[] = {
  {"built",          l_built},
  {"available",      l_available},
  {"model_path",     l_model_path},
  {"transcribe_wav", l_transcribe_wav},
  {"start",          l_start},
  {"stop",           l_stop},
  {"listening",      l_listening},
  {NULL, NULL},
};

/* Release the warm whisper context (and any live capture) before the process
 * tears down. This MUST run before GGML's Metal device destructors at exit:
 * whisper holds Metal residency sets that ggml_metal_device_free asserts have
 * all been released (GGML_ASSERT([rsets->data count] == 0)). Called from main()
 * just before lua_close, exactly like boggart_http_shutdown. Idempotent, and a
 * no-op when built without voice. */
void boggart_voice_shutdown(void) {
#ifdef BOGGART_VOICE
  if (G.running || G.thread_up) {
    if (G.device_up) ma_device_stop(&G.device);
    G.running = 0;
    if (G.thread_up) { uv_thread_join(&G.thread); G.thread_up = 0; }
    if (G.device_up) { ma_device_uninit(&G.device); G.device_up = 0; }
  }
  if (G.ctx) { whisper_free(G.ctx); G.ctx = NULL; }
  free(G.cap);             G.cap = NULL; G.cap_len = 0;
  free(G.final_text);      G.final_text = NULL;
  free(G.pending_partial); G.pending_partial = NULL;
  free(G.pending_final);   G.pending_final = NULL;
#endif
}

int luaopen_boggart_voice(lua_State *L) {
  luaL_newlib(L, voice_lib);
  return 1;
}
