#ifndef BOGGART_VERSION_H
#define BOGGART_VERSION_H

/* The one place the version lives. Both front ends (src/boggart.c and
 * studio/src/main.c) include this, so the CLI and the studio can never report
 * different versions -- a drift the core-parity check (tools/parity.cmake) would
 * otherwise catch at build time. Bump here on release. */
#define BOGGART_VERSION "0.2.0"

#endif
