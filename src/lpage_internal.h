/* Private geometry ownership. Pools belong to the stable public screen. */
#ifndef BOGGART_LPAGE_INTERNAL_H
#define BOGGART_LPAGE_INTERNAL_H
#include "lpage.h"
lpage_screen *lp_geometry_new(const lpage_screen *source, size_t columns, size_t rows);
void lp_geometry_destroy(lpage_screen *geometry);
void lp_geometry_replace(lpage_screen *screen, lpage_screen *geometry);
#endif
