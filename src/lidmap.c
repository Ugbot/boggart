/* Adapted from Ben Gamble's Venus src/core/venus_ds.h; see THIRD_PARTY/venus-map.md.
 * NEON movemask: Venus C translation of Apache-2.0 Bolt; licence retained.
 * Changes: C11 allocation adapters, Boggart namespace, release-active checks,
 * checked capacity refusal and update-at-limit support. */
#include "lidmap.h"
#include <stdlib.h>
#include <stddef.h>
#include <string.h>
#if defined(_MSC_VER)
#include <intrin.h>
#endif
#if defined(_WIN32)
#include <malloc.h>
#endif
#define LIDMAP_ASSERT(c) do { if (!(c)) abort(); } while (0)
#if !defined(LIDMAP_FORCE_SCALAR) && (defined(_M_X64) || defined(_M_IX86) || defined(__x86_64__) || defined(__i386__))
#define LIDMAP_SSE2 1
#include <emmintrin.h>
#else
#define LIDMAP_SSE2 0
#endif
#if !defined(LIDMAP_FORCE_SCALAR) && (defined(__aarch64__) || defined(_M_ARM64))
#define LIDMAP_NEON 1
#include <arm_neon.h>
#else
#define LIDMAP_NEON 0
#endif
static void *lidmap_alloc_(size_t size) {
    if (size > SIZE_MAX - 63u) return NULL;
    size = (size + 63u) & ~(size_t)63u;
#if defined(_WIN32)
    return _aligned_malloc(size, 64);
#else
    return aligned_alloc(64, size);
#endif
}
static void lidmap_dealloc_(void *p) {
#if defined(_WIN32)
    _aligned_free(p);
#else
    free(p);
#endif
}
#define LIDMAP_GROUP 16u
#define LIDMAP_CTRL_EMPTY ((uint8_t)0x80)     /* high bit set, never a tag */
#define LIDMAP_CTRL_TOMBSTONE ((uint8_t)0xFE) /* high bit set, != EMPTY */
#define LIDMAP_MIN_CAPACITY 16u

/* 3 ops, full avalanche. */
static inline uint64_t lidmap_hash_mum_(uint64_t a, uint64_t b) {
#if defined(_MSC_VER) && defined(_M_X64)
    uint64_t hi = 0u;
    const uint64_t lo = _umul128(a, b, &hi);
    return lo ^ hi;
#elif defined(__SIZEOF_INT128__)
    const unsigned __int128 r = (unsigned __int128)a * b;
    return (uint64_t)r ^ (uint64_t)(r >> 64);
#else
    uint64_t x = a ^ b;
    x ^= x >> 30; x *= 0xbf58476d1ce4e5b9ull;
    x ^= x >> 27; x *= 0x94d049bb133111ebull;
    x ^= x >> 31;
    return x;
#endif
}

static inline uint64_t lidmap_hash_u64(uint64_t x) {
    return lidmap_hash_mum_(x ^ 0xa0761d6478bd642full, 0xe7037ed1a0b428dbull);
}

/* Low 7 bits of the top byte: tag with high bit 0 (never EMPTY/TOMBSTONE).
 * PERF-2026-09 bolt review #e: this picks h's TOP 7 bits (h>>57) -- the
 * exact placement bolt's own swiss table abandoned after a partition-
 * collision bug (their fix moved to bits 49-55, i.e. one byte lower). Ours
 * is safe TODAY because the bucket index below is taken from the LOW bits
 * of h (`(uint32_t)h & m->mask`), so the tag byte and the index byte never
 * share bits and cannot correlate the way bolt's bug required -- noted here
 * rather than silently copying a fix for a failure mode we do not have. */
static inline uint8_t lidmap_tag_(uint64_t h) {
    return (uint8_t)((h >> 57) & 0x7Fu);
}



static inline uint32_t lidmap_round_pow2_(uint32_t x) {
    uint32_t r = LIDMAP_MIN_CAPACITY;
    for (uint32_t i = 0; i < 28u && r < x; ++i) {
        LIDMAP_ASSERT(r <= UINT32_MAX / 2u);
        r <<= 1;
    }
    return r;
}

static inline bool lidmap_storage_bytes_valid_(uint32_t cap) {
    const size_t n = (size_t)cap;
    return n <= SIZE_MAX - LIDMAP_GROUP &&
           n <= SIZE_MAX / sizeof(uint64_t) &&
           n <= SIZE_MAX / sizeof(uint32_t);
}

static inline uint32_t lidmap_load_limit_(const lidmap *m) {
    return m->capacity - m->capacity / 8u;
}

/* Init sized for `capacity_hint` live entries at <=50% load (2x oversize, bolt_swiss.h create() shape). */
bool lidmap_init(lidmap *m, uint32_t capacity_hint) {
    if (!m || !capacity_hint || capacity_hint > UINT32_C(1073741824)) return false;
    uint32_t cap = lidmap_round_pow2_(capacity_hint * 2u);
    LIDMAP_ASSERT((cap & (cap - 1u)) == 0u && cap >= LIDMAP_MIN_CAPACITY);
    if (!lidmap_storage_bytes_valid_(cap)) return false;
    memset(m, 0, sizeof(*m));

    const size_t ctrl_bytes = (size_t)cap + LIDMAP_GROUP;
    const size_t keys_bytes = (size_t)cap * sizeof(uint64_t);
    const size_t values_bytes = (size_t)cap * sizeof(uint32_t);
    uint8_t *ctrl = (uint8_t *)lidmap_alloc_(ctrl_bytes);
    uint64_t *keys = (uint64_t *)lidmap_alloc_(keys_bytes);
    uint32_t *values = (uint32_t *)lidmap_alloc_(values_bytes);
    if (ctrl == NULL || keys == NULL || values == NULL) {
        lidmap_dealloc_(ctrl);
        lidmap_dealloc_(keys);
        lidmap_dealloc_(values);
        return false;
    }
    memset(ctrl, LIDMAP_CTRL_EMPTY, (size_t)cap + LIDMAP_GROUP);
    memset(keys, 0, (size_t)cap * sizeof(uint64_t));
    memset(values, 0, (size_t)cap * sizeof(uint32_t));

    m->ctrl = ctrl;
    m->keys = keys;
    m->values = values;
    m->capacity = cap;
    m->mask = cap - 1u;
    m->count = 0u;
    m->tombstones = 0u;
    LIDMAP_ASSERT(m->ctrl != NULL && m->keys != NULL && m->values != NULL);
    LIDMAP_ASSERT(m->mask == m->capacity - 1u && m->count == 0u && m->tombstones == 0u);
    return true;
}

void lidmap_free(lidmap *m) {
    if (m == NULL) return;
    LIDMAP_ASSERT(lidmap_storage_bytes_valid_(m->capacity));
    lidmap_dealloc_(m->ctrl);
    lidmap_dealloc_(m->keys);
    lidmap_dealloc_(m->values);
    memset(m, 0, sizeof(*m));
    LIDMAP_ASSERT(m->ctrl == NULL && m->keys == NULL && m->values == NULL && m->capacity == 0u);
}

void lidmap_clear(lidmap *m) {
    LIDMAP_ASSERT(m != NULL && m->ctrl != NULL);
    memset(m->ctrl, LIDMAP_CTRL_EMPTY,
           (size_t)m->capacity + LIDMAP_GROUP);
    m->count = 0u;
    m->tombstones = 0u;
}

/* Set ctrl byte + tail mirror (first GROUP bytes mirrored past the end so 16-wide loads at base <=... */
static inline void lidmap_set_ctrl_(lidmap *m, uint32_t idx, uint8_t c) {
    LIDMAP_ASSERT(idx < m->capacity);
    m->ctrl[idx] = c;
    if (idx < LIDMAP_GROUP) m->ctrl[m->capacity + idx] = c;
}

#if LIDMAP_NEON
/* Translated to C from bolt's bmm_movemask_i8 (bolt/bolt_port.h ~1260-1271,
 * Apache-2.0, Ben-owned): shift each lane's top bit into its own bit
 * position (0..7 within each half) via a per-lane vshlq, then vaddv-reduce
 * each 8-lane half into one byte of the final 16-bit mask. Input must
 * already be a per-lane 0xFF/0x00 compare result (e.g. vceqq_u8) -- this
 * function only extracts bit 7 of each lane, it does not compare. */
static inline uint32_t lidmap_movemask_neon_(uint8x16_t cmp) {
    static const int8_t kShift[16] = {0, 1, 2, 3, 4, 5, 6, 7,
                                      0, 1, 2, 3, 4, 5, 6, 7};
    const int8x16_t shift = vld1q_s8(kShift);
    const uint8x16_t bits = vshlq_u8(vshrq_n_u8(cmp, 7), shift);
    const uint32_t lo8 = vaddv_u8(vget_low_u8(bits));
    const uint32_t hi8 = vaddv_u8(vget_high_u8(bits));
    const uint32_t mask = lo8 | (hi8 << 8);
    LIDMAP_ASSERT((mask & ~0xFFFFu) == 0u);
    return mask;
}
#endif

/* PERF-2026-09 bolt review #c: had ZERO assertions before this wave (the
 * hottest helper in the hottest engine-wide header, per src/core/CLAUDE.md's
 * blast-radius note) -- fixed while here. `base` is a probe-sequence offset
 * that has already been wrapped mod capacity by the caller and may itself
 * be within LIDMAP_GROUP of `capacity`; the tail-mirror in lidmap_
 * init/_set_ctrl_ is exactly what makes `ctrl[base .. base+15]` always
 * addressable without a bounds check here. */
#if defined(LIDMAP_TESTING) || (!LIDMAP_SSE2 && !LIDMAP_NEON)
static inline uint32_t lidmap_match_scalar_(const uint8_t *ctrl,
                                                uint32_t base, uint8_t tag) {
    LIDMAP_ASSERT(ctrl != NULL);
    uint32_t mask = 0u;
    for (uint32_t i = 0; i < LIDMAP_GROUP; ++i) {
        mask |= (ctrl[base + i] == tag) ? (1u << i) : 0u;
    }
    LIDMAP_ASSERT((mask & ~0xFFFFu) == 0u);
    return mask;
}
#endif

static inline uint32_t lidmap_match_(const uint8_t *ctrl, uint32_t base,
                                        uint8_t tag) {
    LIDMAP_ASSERT(ctrl != NULL);
    uint32_t mask;
#if LIDMAP_SSE2
    const __m128i grp =
        _mm_loadu_si128((const __m128i *)(const void *)(ctrl + base));
    const __m128i vtag = _mm_set1_epi8((char)tag);
    mask = (uint32_t)_mm_movemask_epi8(_mm_cmpeq_epi8(grp, vtag)) & 0xFFFFu;
#elif LIDMAP_NEON
    const uint8x16_t grp = vld1q_u8(ctrl + base);
    mask = lidmap_movemask_neon_(vceqq_u8(grp, vdupq_n_u8(tag)));
#else
    mask = lidmap_match_scalar_(ctrl, base, tag);
#endif
    LIDMAP_ASSERT((mask & ~0xFFFFu) == 0u);
    return mask;
}

/* Both masks (tag, EMPTY) at ONE base from a SINGLE 16-byte group load.
 * PERF-2026-09 bolt review #a: lidmap_find/_insert used to call
 * lidmap_match_ TWICE per group at the identical base -- once for the
 * probed tag, once for LIDMAP_CTRL_EMPTY -- each doing its own load of
 * the same 16 bytes and throwing the first load away. bolt's kit reuses the
 * load; this does too, on every ISA (scalar included: one pass over the 16
 * bytes computes both masks instead of two passes). */
typedef struct lidmap_masks {
    uint32_t tag;
    uint32_t empty;
} lidmap_masks;

#if defined(LIDMAP_TESTING) || (!LIDMAP_SSE2 && !LIDMAP_NEON)
static inline lidmap_masks lidmap_match2_scalar_(const uint8_t *ctrl,
                                                           uint32_t base,
                                                           uint8_t tag) {
    LIDMAP_ASSERT(ctrl != NULL);
    lidmap_masks out = { 0u, 0u };
    for (uint32_t i = 0; i < LIDMAP_GROUP; ++i) {
        const uint8_t c = ctrl[base + i];
        out.tag   |= (c == tag) ? (1u << i) : 0u;
        out.empty |= (c == LIDMAP_CTRL_EMPTY) ? (1u << i) : 0u;
    }
    LIDMAP_ASSERT((out.tag & ~0xFFFFu) == 0u && (out.empty & ~0xFFFFu) == 0u);
    return out;
}
#endif

static inline lidmap_masks lidmap_match2_(const uint8_t *ctrl,
                                                    uint32_t base,
                                                    uint8_t tag) {
    LIDMAP_ASSERT(ctrl != NULL);
    LIDMAP_ASSERT(tag != LIDMAP_CTRL_EMPTY && "tag and EMPTY masks would alias");
    lidmap_masks out;
#if LIDMAP_SSE2
    const __m128i grp =
        _mm_loadu_si128((const __m128i *)(const void *)(ctrl + base));
    out.tag = (uint32_t)_mm_movemask_epi8(
                  _mm_cmpeq_epi8(grp, _mm_set1_epi8((char)tag))) & 0xFFFFu;
    out.empty = (uint32_t)_mm_movemask_epi8(_mm_cmpeq_epi8(
                    grp, _mm_set1_epi8((char)LIDMAP_CTRL_EMPTY))) & 0xFFFFu;
#elif LIDMAP_NEON
    const uint8x16_t grp = vld1q_u8(ctrl + base);
    out.tag = lidmap_movemask_neon_(vceqq_u8(grp, vdupq_n_u8(tag)));
    out.empty = lidmap_movemask_neon_(
                    vceqq_u8(grp, vdupq_n_u8(LIDMAP_CTRL_EMPTY)));
#else
    out = lidmap_match2_scalar_(ctrl, base, tag);
#endif
    LIDMAP_ASSERT((out.tag & ~0xFFFFu) == 0u && (out.empty & ~0xFFFFu) == 0u);
    LIDMAP_ASSERT((out.tag & out.empty) == 0u && "tag and EMPTY are disjoint bytes");
    return out;
}

static inline uint32_t lidmap_ctz_(uint32_t x) {
    LIDMAP_ASSERT(x != 0u);
#if defined(_MSC_VER)
    unsigned long idx = 0;
    _BitScanForward(&idx, x);
    return (uint32_t)idx;
#else
    return (uint32_t)__builtin_ctz(x);
#endif
}

/* Find. */
bool lidmap_find(const lidmap *m, uint64_t key,
                                  uint32_t *value_out) {
    LIDMAP_ASSERT(m != NULL && m->ctrl != NULL);
    const uint64_t h = lidmap_hash_u64(key);
    const uint8_t tag = lidmap_tag_(h);
    uint32_t base = (uint32_t)h & m->mask;

    for (uint32_t probes = 0; probes < m->capacity;
         probes += LIDMAP_GROUP) {
        const lidmap_masks gm = lidmap_match2_(m->ctrl, base, tag);
        uint32_t tags = gm.tag;
        while (tags != 0u) {
            const uint32_t lane = lidmap_ctz_(tags);
            const uint32_t p = (base + lane) & m->mask;
            if (m->keys[p] == key) {
                if (value_out != NULL) *value_out = m->values[p];
                return true;
            }
            tags &= tags - 1u;
        }
        if (gm.empty != 0u) {
            return false;
        }
        base = (base + LIDMAP_GROUP) & m->mask;
    }
    return false;
}

uint32_t lidmap_get(const lidmap *m, uint64_t key,
                                     uint32_t missing) {
    uint32_t v = missing;
    return lidmap_find(m, key, &v) ? v : missing;
}

/* O(capacity) with a bounded displacement chain per slot. */
void lidmap_rehash_in_place(lidmap *m) {
    LIDMAP_ASSERT(m != NULL && m->ctrl != NULL);
    const uint8_t NEEDS_PLACE = 0xFFu; /* temporary marker, high bit set */

    for (uint32_t i = 0; i < m->capacity; ++i) {
        const uint8_t c = m->ctrl[i];
        m->ctrl[i] = ((c & 0x80u) == 0u) ? NEEDS_PLACE : LIDMAP_CTRL_EMPTY;
    }
    m->tombstones = 0u;

    /* Pass 2: place every marked entry. */
    for (uint32_t i = 0; i < m->capacity; ++i) {
        if (m->ctrl[i] != NEEDS_PLACE) continue;
        uint64_t key = m->keys[i];
        uint32_t value = m->values[i];
        m->ctrl[i] = LIDMAP_CTRL_EMPTY; /* slot i is now a hole */

        bool placed = false;
        for (uint32_t hop = 0; hop <= m->count && !placed; ++hop) {
            /* PERF-2026-09 bolt review #f: lidmap_hash_u64(key) used to be
             * called 3x per hop -- once for `base`, then AGAIN for the tag
             * byte in each of the two placement branches below -- despite
             * `key` not changing within a hop iteration. One call, reused
             * for both the bucket and the tag; off the hot per-tick path
             * (rehash only runs at tombstone-pressure, doc's own comment)
             * but free to fix while touching this code for the other bolt
             * items. */
            const uint64_t h = lidmap_hash_u64(key);
            const uint8_t new_tag = lidmap_tag_(h);
            uint32_t base = (uint32_t)h & m->mask;
            uint32_t dst = UINT32_MAX;
            for (uint32_t probes = 0; probes < m->capacity && dst == UINT32_MAX;
                 probes += LIDMAP_GROUP) {
                for (uint32_t lane = 0; lane < LIDMAP_GROUP; ++lane) {
                    const uint32_t p = (base + lane) & m->mask;
                    const uint8_t c = m->ctrl[p];
                    if (c == LIDMAP_CTRL_EMPTY || c == NEEDS_PLACE) {
                        dst = p;
                        break;
                    }
                }
                base = (base + LIDMAP_GROUP) & m->mask;
            }
            LIDMAP_ASSERT(dst != UINT32_MAX && "rehash must find a slot");
            if (m->ctrl[dst] == LIDMAP_CTRL_EMPTY) {
                m->ctrl[dst] = new_tag;
                m->keys[dst] = key;
                m->values[dst] = value;
                placed = true; /* placed into a hole — chain ends */
                continue;
            }
            LIDMAP_ASSERT(m->ctrl[dst] == NEEDS_PLACE);
            const uint64_t tmp_key = m->keys[dst];
            const uint32_t tmp_val = m->values[dst];
            m->ctrl[dst] = new_tag;
            m->keys[dst] = key;
            m->values[dst] = value;
            key = tmp_key;
            value = tmp_val;
        }
        LIDMAP_ASSERT(placed && "rehash displacement chain must terminate");
    }

    for (uint32_t i = 0; i < LIDMAP_GROUP; ++i) {
        m->ctrl[m->capacity + i] = m->ctrl[i];
    }
}

/* Update existing keys even at the load limit. A new key at the limit fails without mutation. */
bool lidmap_insert(lidmap *m, uint64_t key, uint32_t value) {
    LIDMAP_ASSERT(m != NULL && m->ctrl != NULL);
    const bool saturated = m->count >= lidmap_load_limit_(m);

    if (!saturated && m->count + m->tombstones >= lidmap_load_limit_(m)) {
        lidmap_rehash_in_place(m); /* reclaim tombstones, no alloc */
    }

    const uint64_t h = lidmap_hash_u64(key);
    const uint8_t tag = lidmap_tag_(h);
    uint32_t base = (uint32_t)h & m->mask;
    uint32_t first_free = UINT32_MAX;

    for (uint32_t probes = 0; probes < m->capacity;
         probes += LIDMAP_GROUP) {
        const lidmap_masks gm = lidmap_match2_(m->ctrl, base, tag);
        uint32_t tags = gm.tag;
        while (tags != 0u) {
            const uint32_t lane = lidmap_ctz_(tags);
            const uint32_t p = (base + lane) & m->mask;
            if (m->keys[p] == key) {
                m->values[p] = value;
                return true;
            }
            tags &= tags - 1u;
        }
        if (first_free == UINT32_MAX) {
            const uint32_t tombs =
                lidmap_match_(m->ctrl, base, LIDMAP_CTRL_TOMBSTONE);
            if (tombs != 0u) {
                first_free = (base + lidmap_ctz_(tombs)) & m->mask;
            }
        }
        /* An empty in this group ends the probe: key not present. */
        const uint32_t empties = gm.empty;
        if (empties != 0u) {
            if (saturated) return false;
            uint32_t dst = (base + lidmap_ctz_(empties)) & m->mask;
            if (first_free != UINT32_MAX) {
                dst = first_free; /* prefer reclaiming the tombstone */
                LIDMAP_ASSERT(m->tombstones > 0u);
                m->tombstones--;
            }
            lidmap_set_ctrl_(m, dst, tag);
            m->keys[dst] = key;
            m->values[dst] = value;
            m->count++;
            return true;
        }
        base = (base + LIDMAP_GROUP) & m->mask;
    }
    LIDMAP_ASSERT(0 && "venus_map probe exhausted (unreachable under load limit)");
    return false;
}

/* Erase. */
bool lidmap_erase(lidmap *m, uint64_t key) {
    LIDMAP_ASSERT(m != NULL && m->ctrl != NULL);
    const uint64_t h = lidmap_hash_u64(key);
    const uint8_t tag = lidmap_tag_(h);
    uint32_t base = (uint32_t)h & m->mask;

    for (uint32_t probes = 0; probes < m->capacity;
         probes += LIDMAP_GROUP) {
        uint32_t tags = lidmap_match_(m->ctrl, base, tag);
        while (tags != 0u) {
            const uint32_t lane = lidmap_ctz_(tags);
            const uint32_t p = (base + lane) & m->mask;
            if (m->keys[p] == key) {
                /* abseil "was_never_full": probe windows slide, so the only sound erase-to-empty test... */
                const uint32_t before = (p - LIDMAP_GROUP) & m->mask;
                const uint32_t empty_after =
                    lidmap_match_(m->ctrl, p, LIDMAP_CTRL_EMPTY);
                const uint32_t empty_before =
                    lidmap_match_(m->ctrl, before, LIDMAP_CTRL_EMPTY);
                bool never_full = false;
                if (empty_after != 0u && empty_before != 0u) {
                    /* leading zeros (within 16 bits) of the before-mask + trailing zeros of the... */
                    uint32_t lz16 = 0u;
                    for (uint32_t b = 15u;; --b) {
                        if ((empty_before >> b) & 1u) break;
                        lz16++;
                        if (b == 0u) break;
                    }
                    never_full =
                        (lidmap_ctz_(empty_after) + lz16) < LIDMAP_GROUP;
                }
                if (never_full) {
                    lidmap_set_ctrl_(m, p, LIDMAP_CTRL_EMPTY);
                } else {
                    lidmap_set_ctrl_(m, p, LIDMAP_CTRL_TOMBSTONE);
                    m->tombstones++;
                }
                LIDMAP_ASSERT(m->count > 0u);
                m->count--;
                return true;
            }
            tags &= tags - 1u;
        }
        if (lidmap_match_(m->ctrl, base, LIDMAP_CTRL_EMPTY) != 0u) {
            return false;
        }
        base = (base + LIDMAP_GROUP) & m->mask;
    }
    return false;
}
