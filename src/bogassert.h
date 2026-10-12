/* bogassert.h -- assertions that stay on in release builds (BOG-8).
 *
 * After Venus's venus_assert.h: an invariant violated in the field should stop
 * the process AT THE CALL SITE with the condition, file and line on stderr --
 * not carry on and segfault three calls later somewhere unrelated, which is
 * what the 2026-09-28 station crash did (a Lua stack invariant broken in one
 * place, the fault surfacing in resizebox). They do not depend on NDEBUG.
 *
 * Use them for things that can only be false through a bug in boggart's C
 * code: the Lua stack's shape across a block that must leave it unchanged, a
 * userdata of the right type, an index in range. For bad INPUT from Lua, keep
 * raising a Lua error (luaL_argerror and friends) -- that is not a bug.
 *
 *   BOG_ASSERT(cond, "fmt", ...)        trap unless cond
 *   BOG_ASSERT_BOUNDS(i, n)             trap unless 0 <= i < n
 *   BOG_STACK_GUARD(L)                  remember the stack top here ...
 *   BOG_STACK_EXPECT(L, delta)          ... and trap unless it moved by exactly delta
 *   BOG_CHECK_UDATA(L, idx, tname)      a non-NULL userdata of metatable tname, or trap
 */
#ifndef BOGASSERT_H
#define BOGASSERT_H

#include <stdio.h>
#include <stdlib.h>
#include "lua.h"
#include "lauxlib.h"

#if defined(_MSC_VER)
  #define BOG_TRAP() __debugbreak()
#elif defined(__GNUC__) || defined(__clang__)
  #define BOG_TRAP() __builtin_trap()
#else
  #define BOG_TRAP() abort()
#endif

/* Out of line in spirit: write, flush, trap. stderr is unbuffered, but the
 * explicit flush also pushes any stdout the user was looking at. */
#define BOG_FAIL_(kind, condtext, ...)                                          \
  do {                                                                          \
    fflush(stdout);                                                             \
    fprintf(stderr, "boggart: %s FAILED: %s @ %s:%d\n", kind, condtext,          \
            __FILE__, __LINE__);                                                \
    fprintf(stderr, "boggart: " __VA_ARGS__);                                   \
    fprintf(stderr, "\n");                                                      \
    fflush(stderr);                                                             \
    BOG_TRAP();                                                                 \
  } while (0)

#define BOG_ASSERT(cond, ...)                                                   \
  do { if (!(cond)) BOG_FAIL_("ASSERT", #cond, __VA_ARGS__); } while (0)

#define BOG_ASSERT_BOUNDS(idx, count)                                           \
  do {                                                                          \
    long long bog_i_ = (long long)(idx), bog_n_ = (long long)(count);          \
    if (bog_i_ < 0 || bog_i_ >= bog_n_)                                        \
      BOG_FAIL_("BOUNDS", #idx " in [0," #count ")", "%lld not in [0,%lld)",   \
                bog_i_, bog_n_);                                                \
  } while (0)

/* Stack-shape guards for blocks that must not disturb the Lua stack (or must
 * move it by a known amount): the bug class behind luaL_Buffer misuse. */
#define BOG_STACK_GUARD(L) int bog_top_guard_ = lua_gettop(L)
#define BOG_STACK_EXPECT(L, delta)                                              \
  do {                                                                          \
    int bog_now_ = lua_gettop(L);                                               \
    if (bog_now_ != bog_top_guard_ + (delta))                                  \
      BOG_FAIL_("LUA STACK", "top == guard + " #delta,                         \
                "stack top is %d, expected %d", bog_now_, bog_top_guard_ + (delta)); \
  } while (0)

/* A userdata argument that must exist and be of the given type. Use where the
 * caller is boggart's own Lua (a handle it created), so a mismatch is a bug in
 * boggart rather than a user mistake. */
#define BOG_CHECK_UDATA(L, idx, tname)                                          \
  ((void *)bog_check_udata_((L), (idx), (tname), __FILE__, __LINE__))
static inline void *bog_check_udata_(lua_State *L, int idx, const char *tname,
                                     const char *file, int line) {
  void *p = luaL_testudata(L, idx, tname);
  if (!p) {
    fflush(stdout);
    fprintf(stderr, "boggart: USERDATA FAILED: arg %d is not a %s (it is a %s) @ %s:%d\n",
            idx, tname, luaL_typename(L, idx), file, line);
    fflush(stderr);
    BOG_TRAP();
  }
  return p;
}

#endif /* BOGASSERT_H */
