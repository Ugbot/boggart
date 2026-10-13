#include "lpage_layout.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"line %d: %s\n",__LINE__,#x); exit(1); } } while (0)
#include "../fixtures/ghostty-page-layout.h"
#include "../fixtures/ghostty-page-growth.h"

int main(void) {
  size_t count=sizeof sdk_layout_cases/sizeof *sdk_layout_cases;
  for (size_t i=0;i<count;i++) {
    lp_layout actual;
    CHECK(lp_capacity_layout(sdk_layout_shape,sdk_layout_cases[i].cap,&actual));
    if (memcmp(&actual,&sdk_layout_cases[i].layout,sizeof actual)) {
      fprintf(stderr,"SDK layout case %zu failed\n",i); return 1;
    }
    if (sdk_layout_cases[i].columns) {
      lp_capacity adjusted,original;
      memset(&adjusted,0xa5,sizeof adjusted); original=adjusted;
      bool ok=lp_capacity_adjust(sdk_layout_shape,sdk_layout_cases[i].cap,sdk_layout_cases[i].columns,&adjusted);
      CHECK(ok==sdk_layout_cases[i].has_adjust);
      CHECK(!memcmp(&adjusted,ok ? &sdk_layout_cases[i].adjusted : &original,sizeof adjusted));
    }
    if (sdk_layout_cases[i].has_initial) {
      lp_capacity initial;
      CHECK(lp_capacity_initial(sdk_layout_shape,sdk_layout_cases[i].columns,&initial));
      CHECK(!memcmp(&initial,&sdk_layout_cases[i].initial,sizeof initial));
    }
  }
  lp_layout unchanged,before; memset(&unchanged,0xa5,sizeof unchanged); before=unchanged;
  lp_layout_shape invalid[]={{0,128,8},{4096,3,8},{64,128,8},{4096,64,16}};
  for (size_t i=0;i<sizeof invalid/sizeof *invalid;i++) {
    CHECK(!lp_capacity_layout(invalid[i],(lp_capacity){0},&unchanged));
    CHECK(!memcmp(&unchanged,&before,sizeof before));
  }
  lp_capacity untouched,original; memset(&untouched,0xa5,sizeof untouched); original=untouched;
  CHECK(!lp_capacity_adjust(sdk_layout_shape,(lp_capacity){0},0,&untouched));
  CHECK(!lp_capacity_initial(sdk_layout_shape,0,&untouched));
  CHECK(!memcmp(&untouched,&original,sizeof original));
  CHECK(!lp_capacity_layout(sdk_layout_shape,(lp_capacity){0},NULL));
  CHECK(!lp_capacity_initial(sdk_layout_shape,1,NULL));
  /* Valid wide grids can require >u16 rows after a large column shrink.
   * Reject that unsupported SDK geometry without truncation. */
  CHECK(!lp_capacity_adjust(sdk_layout_shape,(lp_capacity){65535,65535,0,0,0,0},1,&untouched));
  CHECK(!memcmp(&untouched,&original,sizeof original));
  size_t growth_count=sizeof sdk_growth_cases/sizeof *sdk_growth_cases;
  for (size_t i=0;i<growth_count;i++) {
    lp_capacity grown;
    CHECK(lp_capacity_grow(sdk_growth_shape,sdk_growth_cases[i].before,sdk_growth_cases[i].dimension,
                           sdk_growth_cases[i].used,sdk_growth_cases[i].rows,&grown));
    if (memcmp(&grown,&sdk_growth_cases[i].after,sizeof grown)) {
      fprintf(stderr,"SDK growth event %zu failed\n",i); return 1;
    }
  }
  /* Zero-sized exact pages must recover a nonzero standard dimension, not
   * retry forever with 0*2. Metadata size ceilings preserve the output. */
  lp_capacity zero={1,1,0,0,0,0},grown;
  CHECK(lp_capacity_grow(sdk_growth_shape,zero,LP_GROW_STYLES,0,1,&grown) && grown.styles==128);
  CHECK(lp_capacity_grow(sdk_growth_shape,zero,LP_GROW_GRAPHEMES,0,1,&grown) && grown.grapheme_bytes==8192);
  CHECK(lp_capacity_grow(sdk_growth_shape,zero,LP_GROW_HYPERLINKS,0,1,&grown) && grown.hyperlink_bytes==4*(sdk_growth_shape.word_bytes==8 ? 48 : 28));
  CHECK(lp_capacity_grow(sdk_growth_shape,zero,LP_GROW_STRINGS,0,1,&grown) && grown.string_bytes==2048);
  CHECK(lp_capacity_grow(sdk_growth_shape,zero,LP_GROW_REHASH,0,1,&grown) && !memcmp(&grown,&zero,sizeof zero));
  lp_capacity saturated=zero; saturated.styles=40000;
  CHECK(lp_capacity_grow(sdk_growth_shape,saturated,LP_GROW_STYLES,0,1,&grown) && grown.styles==65535);
  CHECK(!lp_capacity_grow(sdk_growth_shape,grown,LP_GROW_STYLES,0,1,&untouched));
  lp_capacity projection={1,65535,128,0,0,0};
  CHECK(lp_capacity_grow(sdk_growth_shape,projection,LP_GROW_STYLES,UINT32_MAX,1,&grown) && grown.styles==4096);
  projection.grapheme_bytes=67108864;
  CHECK(lp_capacity_grow(sdk_growth_shape,projection,LP_GROW_GRAPHEMES,UINT32_MAX,1,&grown) && grown.grapheme_bytes==134217728);
  projection.grapheme_bytes=UINT32_MAX;
  CHECK(!lp_capacity_grow(sdk_growth_shape,projection,LP_GROW_GRAPHEMES,0,1,&untouched));
  CHECK(!lp_capacity_grow(sdk_growth_shape,zero,(lp_growth)99,0,1,&untouched));
  CHECK(!lp_capacity_grow(sdk_growth_shape,zero,LP_GROW_STYLES,1,2,&untouched));
  CHECK(!lp_capacity_grow(sdk_growth_shape,zero,LP_GROW_STYLES,0,1,NULL));
  CHECK(!memcmp(&untouched,&original,sizeof original));
  printf("%zu SDK page layouts/offsets and capacity adjustments match\n",count);
  printf("%zu SDK metadata growth events and zero/saturation/projection limits match\n",growth_count);
  return 0;
}
