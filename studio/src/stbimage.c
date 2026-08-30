/* stbimage.c -- the single implementation TU for stb_image.
 *
 * Decodes PNG/JPEG/GIF/BMP/etc. to RGBA for the renderer's image binding (inline
 * Markdown images now; PDF page bitmaps come pre-rasterised, not through this).
 * Compiled with the studio's -w since stb is third-party. Decode only: no image
 * writing, no HDR path. */
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_ONLY_GIF
#define STBI_ONLY_BMP
#define STBI_ONLY_TGA
#define STBI_ONLY_PNM
#include "stb_image.h"
