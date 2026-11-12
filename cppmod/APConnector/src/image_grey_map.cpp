// The world map pictures in grey: greyscale_png, compose_map (locked areas grey on the colour map) and sample_png,
// which reads one spot of a PNG (image_tools.hpp says what each takes and returns).
#include "image_tools.hpp"
#include "image_basics.hpp"

#include <algorithm>
#include <cmath>
#include <sstream>
#include <vector>

using namespace image_basics;

namespace
{
// compose_map's soft boundary between colour and grey, and its inner shadow along a locked area's edge: blur radii
// as the map's width divided by the first number (pixels at a 4096 map in brackets), never below the second.
constexpr int BOUNDARY_SOFTEN_DIVISOR = 2048, BOUNDARY_SOFTEN_MIN_PX = 1;   // (2) a couple of pixels
constexpr int SHADOW_DIVISOR = 400, SHADOW_MIN_PX = 2;                      // (10, three passes)
// The shadow darkens the grey to SHADOW_DARKEST at a locked area's edge; SHADOW_STRENGTH is how quickly the shadow's
// blur reaches that.
constexpr double SHADOW_DARKEST = 0.45;
constexpr double SHADOW_STRENGTH = 1.1;

// A locked area's mask (255 inside), softened two ways: `soft` for the boundary, `shade` for the inner shadow.
struct LockedMask
{
    std::vector<uint8_t> soft;
    std::vector<uint8_t> shade;
};

// The locked areas of a label picture (w x h, one area index per pixel) as a softened mask.
auto locked_mask(const unsigned char* labels, int w, int h, const bool (&locked)[AREA_LABELS]) -> LockedMask
{
    const size_t count = static_cast<size_t>(w) * h;
    LockedMask mask;
    mask.soft.resize(count);
    for (size_t i = 0; i < count; ++i) mask.soft[i] = locked[labels[i]] ? 255 : 0;
    mask.shade = mask.soft;
    const int edge = std::max(BOUNDARY_SOFTEN_MIN_PX, w / BOUNDARY_SOFTEN_DIVISOR);
    const int shadow = std::max(SHADOW_MIN_PX, w / SHADOW_DIVISOR);
    for (int pass = 0; pass < GAUSSIAN_BOX_PASSES; ++pass)
    {
        box_blur(mask.soft, w, h, edge);
        box_blur(mask.shade, w, h, shadow);
    }
    return mask;
}

// One map pixel (RGBA bytes, in place): the gamma applied, then mixed toward grey by `locked` (0 open .. 1 inside a
// locked area), the grey darkened by the inner shadow (`shade` 0..1, 1 deep inside).
void paint_map_pixel(unsigned char* p, const GammaTable& lut, double locked, double shade)
{
    if (locked <= 0)
    {
        for (int c = 0; c < 3; ++c) p[c] = lut[p[c]];
        return;
    }
    const double r = lut[p[0]], g = lut[p[1]], b = lut[p[2]];
    const double dark = std::min(1.0, std::max(SHADOW_DARKEST, 1.0 - SHADOW_STRENGTH * (1.0 - shade)));
    const double grey = luminance(r, g, b) * dark;
    p[0] = static_cast<unsigned char>(std::lround(r * (1 - locked) + grey * locked));
    p[1] = static_cast<unsigned char>(std::lround(g * (1 - locked) + grey * locked));
    p[2] = static_cast<unsigned char>(std::lround(b * (1 - locked) + grey * locked));
    p[3] = 255;
}
} // namespace

auto greyscale_png(const std::string& in, const std::string& out, double gamma) -> std::string
{
    int w = 0, h = 0;
    const StbPixels px = read_png(in, 4, w, h);
    if (!px) return read_failure(in);
    const GammaTable lut = gamma_table(gamma);
    for (long i = 0, count = static_cast<long>(w) * h; i < count; ++i)
    {
        unsigned char* p = px.get() + i * 4;
        const double y = luminance(static_cast<double>(lut[p[0]]), lut[p[1]], lut[p[2]]);
        p[0] = p[1] = p[2] = static_cast<unsigned char>(std::lround(y));
    }
    return stbi_write_png(out.c_str(), w, h, 4, px.get(), w * 4) ? "" : "could not write " + out;
}

auto compose_map(const std::string& colour, const std::string& labels, const std::string& locked,
                 const std::string& out, double gamma) -> std::string
{
    int w = 0, h = 0, lw = 0, lh = 0;
    const StbPixels px = read_png(colour, 4, w, h);
    if (!px) return read_failure(colour);
    const StbPixels lab = read_png(labels, 1, lw, lh);
    if (!lab) return read_failure(labels);
    if (lw != w || lh != h) return "the labels picture is not the size of the map";
    bool lockedArea[AREA_LABELS] = {};
    const std::string badLocked = read_locked_areas(locked, lockedArea);
    if (!badLocked.empty()) return badLocked;
    const LockedMask mask = locked_mask(lab.get(), w, h, lockedArea);
    const GammaTable lut = gamma_table(gamma);
    for (size_t i = 0, count = static_cast<size_t>(w) * h; i < count; ++i)
    {
        paint_map_pixel(px.get() + i * 4, lut, mask.soft[i] / 255.0, mask.shade[i] / 255.0);
    }
    return write_png_fast(out, w, h, 4, px.get()) ? "" : "could not write " + out;
}

auto sample_png(const std::string& path, double u, double v) -> std::string
{
    int w = 0, h = 0;
    const StbPixels px = read_png(path, 4, w, h);
    if (!px) return "error: " + read_failure(path);
    const int cx = std::clamp(static_cast<int>(u * w), 0, w - 1), cy = std::clamp(static_cast<int>(v * h), 0, h - 1);
    int sum[4] = {}, count = 0;
    for (int y = std::max(cy - 1, 0); y <= std::min(cy + 1, h - 1); ++y)
    {
        for (int x = std::max(cx - 1, 0); x <= std::min(cx + 1, w - 1); ++x, ++count)
        {
            for (int c = 0; c < 4; ++c) sum[c] += px.get()[(static_cast<size_t>(y) * w + x) * 4 + c];
        }
    }
    std::ostringstream out;
    out << sum[0] / count << "," << sum[1] / count << "," << sum[2] / count << "," << sum[3] / count;
    return out.str();
}
