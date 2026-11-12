#ifndef BOGGART_FONTCLUSTER_H
#define BOGGART_FONTCLUSTER_H
#include "fontglyph.h"
#include "fontshape.h"
typedef struct FontClusters FontClusters;
typedef struct RenCluster { unsigned face; bool missing; FontShapeRun run; } RenCluster;
const RenCluster *ren_font_cluster(RenFont *font,const char *text,size_t length);
FontClusters *fontcluster_create(void);
void fontcluster_destroy(FontClusters *cache);
/* 64 fixed slots, full byte comparison after hashing. Borrow expires at the
 * next cluster lookup; runs retain IDs/positions, never mutable atlas UVs. */
const RenCluster *fontcluster_layout(FontClusters *cache,RenFont *font,const char *text,size_t length);
#endif
