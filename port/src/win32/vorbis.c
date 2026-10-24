// stb_vorbis (Odin's vendor/stb/src copy) with its sin and cos taken from
// x86/libm.odin. Its decoded samples land in guest memory, so a Linux and a
// Windows co-op peer must decode the same bits; the prebuilt stb_vorbis.a and
// .lib call each platform's libm for the IMDCT twiddles and the window, and
// those differ by an ulp, so the samples differed by 1 (docs/hle.md §11).
// Its pow, exp and log only size codebooks, where the result is an integer
// checked against exact powers, and floor and ldexp are exact.
#include <math.h>

double je_vorbis_sin(double x);
double je_vorbis_cos(double x);

#define sin je_vorbis_sin
#define cos je_vorbis_cos
#include "stb_vorbis.c"
