// The pieces the map pictures (image_*.cpp) share: the locked-area list, blurs, and PNGs loaded and resampled as
// floats. Internal to the picture code: the functions the Lua mod's calls reach are in image_tools.hpp.
#pragma once

#include <cstdint>
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
