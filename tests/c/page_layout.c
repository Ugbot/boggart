#include "lpage_layout.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"line %d: %s\n",__LINE__,#x); exit(1); } } while (0)
#include "../fixtures/ghostty-page-layout.h"

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
  printf("%zu SDK page layouts/offsets and capacity adjustments match\n",count);
  return 0;
}
