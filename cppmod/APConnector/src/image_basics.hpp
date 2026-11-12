// The pieces the map pictures (image_*.cpp) share: the locked-area list, blurs, and PNGs loaded and resampled as
// floats. Internal to the picture code: the functions the Lua mod's calls reach are in image_tools.hpp.
#pragma once

#include <algorithm>
#include <array>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "stb_image.h"
#include "stb_image_write.h"

namespace image_basics
{
// An area label picture holds one byte per pixel: area indexes 0..255 (0 is no area).
constexpr int AREA_LABELS = 256;

// The locked areas from Lua's "3,7,12" (area label indexes), into `locked`. Returns "" or the reason: a part that
// is not a whole number, or not 0..255, fails the job rather than greying another area.
auto read_locked_areas(const std::string& csv, bool (&locked)[AREA_LABELS]) -> std::string;

// A PNG's pixels as stb_image loaded them, freed with stbi_image_free; null when there are none.
using StbPixels = std::unique_ptr<unsigned char, void (*)(void*)>;

// A PNG read as `channels` bytes per pixel (1 grey, 3 RGB, 4 RGBA, whatever the file holds), its size into w and h;
// null if it would not read (read_failure says why).
auto read_png(const std::string& path, int channels, int& w, int& h) -> StbPixels;

// No pixels yet, for a PNG read only when it is asked for.
auto no_pixels() -> StbPixels;

// "could not read <path>: <why>", for the PNG that just failed to read.
auto read_failure(const std::string& path) -> std::string;

// The gamma curve as a table: byte value i becomes 255 * (i / 255)^gamma, rounded. The game exports render targets
// in linear light, which looks dark once loaded back as a picture; a gamma below 1 brightens it.
using GammaTable = std::array<unsigned char, 256>;
auto gamma_table(double gamma) -> GammaTable;

// The pixel of a `w`-wide picture nearest to the middle of pixel x of a `size`-wide one: to read a picture of another
// size at this one's (also down the height, with y and h).
inline auto nearest_pixel(int x, int size, int w) -> int
{
    return std::min(w - 1, (2 * x + 1) * w / (2 * size));
}

// A label picture (one byte per pixel, w x h) at size x size, by nearest pixel: labels are indexes, never averaged.
auto labels_at_size(const unsigned char* labels, int w, int h, int size) -> std::vector<unsigned char>;

// Lays `top` (RGB 0..1) at `top_alpha` over `colour` at `alpha`, in place: straight (not premultiplied) alpha, the
// result's alpha into `alpha`. Nothing when top_alpha is 0 or less.
inline void blend_over(float* colour, float& alpha, const float* top, float top_alpha)
{
    if (top_alpha <= 0.f) return;
    const float out = top_alpha + alpha * (1 - top_alpha);
    for (int c = 0; c < 3; ++c)
    {
        colour[c] = out > 0 ? (top[c] * top_alpha + colour[c] * alpha * (1 - top_alpha)) / out : 0.f;
    }
    alpha = out;
}

// Box blur of an 8-bit image, horizontally then vertically; three passes come close to a Gaussian.
void box_blur(std::vector<uint8_t>& img, int w, int h, int r);

using Plane = std::vector<float>;

// Box blur of a float plane, three passes (close to a Gaussian), as box_blur above.
void blur(Plane& a, int w, int h, int r);

// An RGBA picture as floats 0..1, resampled to s x s (area average when shrinking, bilinear when growing).
struct Rgba
{
    int s = 0;
    std::vector<float> px;          // s * s * 4
    const float* at(int x, int y) const { return &px[(static_cast<size_t>(y) * s + x) * 4]; }
};

// One channel of a PNG as floats 0..1, resampled to s x s as load_rgba does (for the fog's masks: a quarter of the
// memory of load_rgba, which matters at 4096).
auto load_channel(const std::string& path, int s, int ch, std::string& err) -> Plane;

// An RGBA PNG as an Rgba of s x s; on failure an empty one, with the reason in err.
auto load_rgba(const std::string& path, int s, std::string& err) -> Rgba;
} // namespace image_basics
