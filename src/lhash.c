/* lhash.c -- SHA-256 in C (BOG-14).
 *
 * workflow.hash (pure Lua) ran at 227 ms per MiB, and boggart hashes a lot of
 * text: imports hash each file whole and then every record, the story mirror
 * hashes the book on each sync, learning hashes canonical forms. This returns
 * the identical lowercase hex digest. On macOS it uses CommonCrypto (hardware
 * SHA on Apple silicon); elsewhere a portable FIPS 180-4 implementation.
 *
 *   hash_c.sha256(s) -> 64 hex chars
 *   hash_c.sha256_portable(s) -> the same, always via the portable code (tests)
 */
#include <stdint.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#if defined(__APPLE__)
#include <CommonCrypto/CommonDigest.h>
#endif

static const uint32_t K[64] = {
  0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
  0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
  0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
  0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
  0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
  0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
  0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
  0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2 };

#define ROTR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void block(uint32_t h[8], const unsigned char *p) {
  uint32_t w[64];
  for (int i = 0; i < 16; i++)
    w[i] = (uint32_t)p[4*i] << 24 | (uint32_t)p[4*i+1] << 16 | (uint32_t)p[4*i+2] << 8 | (uint32_t)p[4*i+3];
  for (int i = 16; i < 64; i++) {
    uint32_t s0 = ROTR(w[i-15], 7) ^ ROTR(w[i-15], 18) ^ (w[i-15] >> 3);
    uint32_t s1 = ROTR(w[i-2], 17) ^ ROTR(w[i-2], 19) ^ (w[i-2] >> 10);
    w[i] = w[i-16] + s0 + w[i-7] + s1;
  }
  uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], j = h[7];
  for (int i = 0; i < 64; i++) {
    uint32_t t1 = j + (ROTR(e, 6) ^ ROTR(e, 11) ^ ROTR(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i];
    uint32_t t2 = (ROTR(a, 2) ^ ROTR(a, 13) ^ ROTR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
    j = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
  }
  h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += j;
}

static void sha256_portable(const unsigned char *s, size_t n, unsigned char out[32]) {
  uint32_t h[8] = { 0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19 };
  size_t full = n / 64;
  for (size_t i = 0; i < full; i++) block(h, s + 64 * i);
  unsigned char tail[128];
  size_t rem = n - full * 64;
  memcpy(tail, s + full * 64, rem);
  tail[rem] = 0x80;
  size_t tl = (rem < 56) ? 64 : 128;
  memset(tail + rem + 1, 0, tl - rem - 1);
  uint64_t bits = (uint64_t)n * 8;
  for (int i = 0; i < 8; i++) tail[tl - 1 - i] = (unsigned char)(bits >> (8 * i));
  block(h, tail);
  if (tl == 128) block(h, tail + 64);
  for (int i = 0; i < 8; i++) {
    out[4*i] = (unsigned char)(h[i] >> 24); out[4*i+1] = (unsigned char)(h[i] >> 16);
    out[4*i+2] = (unsigned char)(h[i] >> 8); out[4*i+3] = (unsigned char)h[i];
  }
}

static void push_hex(lua_State *L, const unsigned char d[32]) {
  static const char *hx = "0123456789abcdef";
  char out[64];
  for (int i = 0; i < 32; i++) { out[2*i] = hx[d[i] >> 4]; out[2*i+1] = hx[d[i] & 15]; }
  lua_pushlstring(L, out, 64);
}

static int l_sha256(lua_State *L) {
  size_t n;
  const unsigned char *s = (const unsigned char *)luaL_checklstring(L, 1, &n);
  unsigned char d[32];
#if defined(__APPLE__)
  CC_SHA256_CTX ctx;
  CC_SHA256_Init(&ctx);
  /* CC_LONG is 32-bit: feed large inputs in pieces */
  while (n > 0) {
    CC_LONG take = (CC_LONG)(n > 0x40000000u ? 0x40000000u : n);
    CC_SHA256_Update(&ctx, s, take);
    s += take; n -= take;
  }
  CC_SHA256_Final(d, &ctx);
#else
  sha256_portable(s, n, d);
#endif
  push_hex(L, d);
  return 1;
}

static int l_sha256_portable(lua_State *L) {
  size_t n;
  const unsigned char *s = (const unsigned char *)luaL_checklstring(L, 1, &n);
  unsigned char d[32];
  sha256_portable(s, n, d);
  push_hex(L, d);
  return 1;
}

int luaopen_boggart_hash(lua_State *L) {
  static const luaL_Reg f[] = { { "sha256", l_sha256 }, { "sha256_portable", l_sha256_portable }, { NULL, NULL } };
  luaL_newlib(L, f);
  return 1;
}
