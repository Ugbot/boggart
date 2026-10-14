#ifndef BOGGART_STUDIO_UVBRIDGE_H
#define BOGGART_STUDIO_UVBRIDGE_H
#include <SDL3/SDL.h>
#include <uv.h>
typedef struct uvbridge uvbridge;
typedef struct { uint64_t polls, wakes, rearms, push_failures; bool armed; } uvbridge_stats;
/* The loop/callbacks remain main-thread owned. The single waiter only polls a
 * copied backend fd/timeout and posts an SDL event. Unix backend embedding. */
uvbridge *uvbridge_create(uv_loop_t *loop);
/* Call after main-thread dispatch, or after modifying handles before sleep.
 * This interrupts stale waits and coalesces work to one outstanding wake. */
void uvbridge_arm(uvbridge *bridge);
Uint32 uvbridge_event_type(const uvbridge *bridge);
uvbridge_stats uvbridge_get_stats(uvbridge *bridge);
/* Join the waiter before closing/freeing the loop. Flush its queued events. */
void uvbridge_destroy(uvbridge *bridge);
#endif
