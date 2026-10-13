/* Private geometry ownership. Pools belong to the stable public screen. */
#ifndef BOGGART_LPAGE_INTERNAL_H
#define BOGGART_LPAGE_INTERNAL_H
#include "lpage.h"
lpage_screen *lp_geometry_new(const lpage_screen *source, size_t columns, size_t rows);
/* Candidate rows are populated lazily. Capacity 0 chooses ordinary available
 * storage; a nonzero capacity preserves a copied page's allocated width. */
bool lp_geometry_row(lpage_screen *geometry, size_t row, size_t capacity);
size_t lp_row_capacity(const lpage_screen *screen, size_t absolute_row);
bool lp_row_page_has_head(const lpage_screen *screen, size_t absolute_row);
void lp_geometry_trim(lpage_screen *geometry);
void lp_geometry_destroy(lpage_screen *geometry);
void lp_geometry_replace(lpage_screen *screen, lpage_screen *geometry);
#endif
