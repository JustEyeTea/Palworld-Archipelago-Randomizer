// The pieces the map pictures (image_*.cpp) share: the list of locked locks, blurs, and PNGs loaded and resampled as
// floats. Internal to the picture code: the functions the Lua mod's calls reach are in image_tools.hpp.
#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "stb_image.h"
#include "stb_image_write.h"

namespace image_basics
{
// Lua gives the pictures' sizes (a stamp's width, a wall's glow) in pixels of a map this wide; each picture scales
// them to its own size.
constexpr int REFERENCE_MAP_PX = 4096;

// The smallest picture a composer makes: below this the borders and rims would not show.
constexpr int MIN_PICTURE_PX = 64;

// The explorer's chart's ink, a dark brown (red, green, blue 0..1): its coasts, its frame and the fog's inked edge,
// and the fog's borders when Lua gives no ink. Copy: map_fog.lua's BORDER_INK ("59,42,26", the same in 0-255).
constexpr float CHART_INK[3] = {0.231f, 0.165f, 0.102f};

// Rec. 709 luminance, how bright a colour looks: the weights of red, green and blue.
constexpr double LUMA_RED = 0.2126, LUMA_GREEN = 0.7152, LUMA_BLUE = 0.0722;
inline auto luminance(double r, double g, double b) -> double
{
    return LUMA_RED * r + LUMA_GREEN * g + LUMA_BLUE * b;
}
inline auto luminance(float r, float g, float b) -> float
{
    constexpr float red = static_cast<float>(LUMA_RED), green = static_cast<float>(LUMA_GREEN);
    constexpr float blue = static_cast<float>(LUMA_BLUE);
    return red * r + green * g + blue * b;
}

// Writes a PNG with stb's fastest compression: each picture is read back once, by the game, straight after, so
// speed matters more than size. False if it could not be written.
auto write_png_fast(const std::string& path, int w, int h, int channels, const unsigned char* pixels) -> bool;

// A value 0..1 as a byte 0..255, rounded; outside 0..1 it is clamped.
inline auto to_byte(float v) -> unsigned char
{
    return static_cast<unsigned char>(std::lround(255.f * std::min(1.f, std::max(0.f, v))));
}
// A lock label picture holds one byte per pixel: lock indexes 0..255 (0 is no lock).
constexpr int LOCK_LABELS = 256;

// The locked locks from Lua's "3,7,12" (lock label indexes), into `locked`. Returns "" or the reason: a part that
// is not a whole number, or not 0..255, fails the job rather than greying another lock.
auto read_locked_indexes(const std::string& csv, bool (&locked)[LOCK_LABELS]) -> std::string;

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

// Box blurs repeated this many times come close to a Gaussian blur.
constexpr int GAUSSIAN_BOX_PASSES = 3;

// One box blur of an 8-bit image, horizontally then vertically (GAUSSIAN_BOX_PASSES of them come close to a Gaussian).
void box_blur(std::vector<uint8_t>& img, int w, int h, int r);

using Plane = std::vector<float>;

// A box blur of a float plane GAUSSIAN_BOX_PASSES times, close to a Gaussian.
void blur(Plane& a, int w, int h, int r);

// An RGBA picture as floats 0..1, resampled to s x s (box average when shrinking, bilinear when growing).
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
