/* Private geometry ownership. Pools belong to the stable public screen. */
#ifndef BOGGART_LPAGE_INTERNAL_H
#define BOGGART_LPAGE_INTERNAL_H
#include "lpage.h"
#include "lpage_layout.h"
typedef struct { lp_capacity capacity; size_t first, rows; } lp_group_span;
bool lp_row_group(const lpage_screen *screen, size_t absolute_row, lp_group_span *out);
bool lp_geometry_crop_groups(lpage_screen *geometry, const lpage_screen *source,
                             size_t end, size_t padding);
lpage_screen *lp_geometry_new(const lpage_screen *source, size_t columns, size_t rows);
/* Borrow retained rows and reserve unused source slots without mutation;
 * own only separately allocated padding pages. Source stays alive and
 * unmodified until commit/abort. Reserved slots initialize only at commit. */
lpage_screen *lp_geometry_height(lpage_screen *source, size_t rows, size_t end, size_t padding);
/* Candidate rows are populated lazily. Capacity 0 chooses ordinary available
 * storage; a nonzero capacity preserves a copied page's allocated width. */
bool lp_geometry_row(lpage_screen *geometry, size_t row, size_t capacity);
size_t lp_row_capacity(const lpage_screen *screen, size_t absolute_row);
bool lp_row_page_has_head(const lpage_screen *screen, size_t absolute_row);
void lp_geometry_trim(lpage_screen *geometry);
void lp_geometry_destroy(lpage_screen *geometry);
void lp_geometry_replace(lpage_screen *screen, lpage_screen *geometry);
#endif
