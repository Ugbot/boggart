/* bogtsan.h -- telling ThreadSanitizer about synchronization it cannot see.
 *
 * libuv's uv_sem_t is a Mach semaphore on macOS (and a futex-ish primitive
 * elsewhere); TSan does not intercept it, so a correct hand-off through one
 * (post after writing, wait before reading -- a real happens-before edge) is
 * reported as a data race. Rather than restructure correct code, mark the
 * edge: release on the posting side before uv_sem_post, acquire on the waiting
 * side after uv_sem_wait, keyed by the semaphore's address. Compiles to
 * nothing outside a TSan build (BOGGART_SANITIZER=thread). */
#ifndef BOGTSAN_H
#define BOGTSAN_H

#if defined(__has_feature)
#  if __has_feature(thread_sanitizer)
#    define BOG_TSAN 1
#  endif
#endif
#if defined(__SANITIZE_THREAD__)
#  define BOG_TSAN 1
#endif

#ifdef BOG_TSAN
void __tsan_acquire(void *addr);
void __tsan_release(void *addr);
#  define BOG_TSAN_RELEASE(p) __tsan_release((void *)(p))
#  define BOG_TSAN_ACQUIRE(p) __tsan_acquire((void *)(p))
#else
#  define BOG_TSAN_RELEASE(p) ((void)0)
#  define BOG_TSAN_ACQUIRE(p) ((void)0)
#endif

/* uv_sem_* with the edge marked: drop-in replacements for code whose
 * correctness rests on semaphore hand-offs. Need "uv.h" included first. */
#ifdef UV_H
static inline void bog_sem_post(uv_sem_t *s) { BOG_TSAN_RELEASE(s); uv_sem_post(s); }
static inline void bog_sem_wait(uv_sem_t *s) { uv_sem_wait(s); BOG_TSAN_ACQUIRE(s); }
static inline int bog_sem_trywait(uv_sem_t *s) { int r = uv_sem_trywait(s); if (r == 0) BOG_TSAN_ACQUIRE(s); return r; }
#endif

#endif
