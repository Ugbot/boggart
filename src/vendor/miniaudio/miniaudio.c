/* miniaudio.c -- the single implementation TU for the vendored miniaudio.h.
 *
 * miniaudio ships as one header that is BOTH the declarations and (behind
 * MINIAUDIO_IMPLEMENTATION) the code. Compiling it once here, as its own static
 * library, keeps that ~4 MB of implementation out of every other translation
 * unit -- the pattern src/vendor/sqlite already uses. Everything boggart needs
 * is capture only, so the unused device backends are compiled out to shrink the
 * binary and the attack surface: no playback path, no decoding/encoding, no
 * resource manager. CoreAudio (macOS), WASAPI (Windows) and ALSA/PulseAudio
 * (Linux) are the capture backends left on by default. */
#define MINIAUDIO_IMPLEMENTATION

/* Capture-only: we open an input device and read f32 PCM. None of playback,
 * the node graph, the resource manager, or file decoders/encoders are used. */
#define MA_NO_ENGINE
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_GENERATION
#define MA_NO_DECODING
#define MA_NO_ENCODING

#include "miniaudio.h"
