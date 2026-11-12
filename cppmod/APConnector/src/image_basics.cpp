// The shared picture pieces declared in image_basics.hpp. stb_image and stb_image_write are compiled here, once.
#include "image_basics.hpp"
#include "lua_text.hpp"

#include <algorithm>
#include <cmath>
#include <memory>

#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

namespace image_basics
{
auto read_locked_areas(const std::string& csv, bool (&locked)[AREA_LABELS]) -> std::string
{
    const lua_text::IdList list = lua_text::parse_ids(csv);
    if (!list.skipped.empty()) return "locked '" + csv + "': '" + list.skipped.front() + "' is not a number";
    for (const int64_t area : list.numbers)
    {
        if (area < 0 || area >= AREA_LABELS) return "locked '" + csv + "': no area " + std::to_string(area);
        locked[area] = true;
    }
    return "";
}

auto read_png(const std::string& path, int channels, int& w, int& h) -> StbPixels
{
    int in_file = 0;
    return StbPixels(stbi_load(path.c_str(), &w, &h, &in_file, channels), stbi_image_free);
}

auto no_pixels() -> StbPixels
{
    return StbPixels(nullptr, stbi_image_free);
}

auto read_failure(const std::string& path) -> std::string
{
    return "could not read " + path + ": " + stbi_failure_reason();
}

auto write_png_fast(const std::string& path, int w, int h, int channels, const unsigned char* pixels) -> bool
{
    constexpr int FASTEST_COMPRESSION = 1;   // stb's own default is 8
    stbi_write_png_compression_level = FASTEST_COMPRESSION;
    return stbi_write_png(path.c_str(), w, h, channels, pixels, w * channels) != 0;
}

auto gamma_table(double gamma) -> GammaTable
{
    GammaTable table{};
    for (int i = 0; i < 256; ++i)
    {
        table[i] = static_cast<unsigned char>(std::lround(255.0 * std::pow(i / 255.0, gamma)));
    }
    return table;
}

auto labels_at_size(const unsigned char* labels, int w, int h, int size) -> std::vector<unsigned char>
{
    std::vector<unsigned char> out(static_cast<size_t>(size) * size);
    for (int y = 0; y < size; ++y)
    {
        for (int x = 0; x < size; ++x)
        {
            const int lx = nearest_pixel(x, size, w), ly = nearest_pixel(y, size, h);
            out[static_cast<size_t>(y) * size + x] = labels[static_cast<size_t>(ly) * w + lx];
        }
    }
    return out;
}

namespace
{
// One box blur pass of radius r: along the rows into `scratch`, then down the columns back into `img`; past the
// picture's edge the edge pixel repeats. Sum is the running total's type: int for bytes (exact, then whole-number
// division), float for floats.
template <typename Pixel, typename Sum>
void box_blur_pass(std::vector<Pixel>& img, std::vector<Pixel>& scratch, int w, int h, int r)
{
    const Sum span = static_cast<Sum>(2 * r + 1);
    auto at = [w](int x, int y) { return static_cast<size_t>(y) * w + x; };
    for (int y = 0; y < h; ++y)
    {
        Sum sum = 0;
        for (int x = -r; x <= r; ++x) sum += img[at(std::clamp(x, 0, w - 1), y)];
        for (int x = 0; x < w; ++x)
        {
            scratch[at(x, y)] = static_cast<Pixel>(sum / span);
            sum += img[at(std::min(x + r + 1, w - 1), y)] - img[at(std::max(x - r, 0), y)];
        }
    }
    for (int x = 0; x < w; ++x)
    {
        Sum sum = 0;
        for (int y = -r; y <= r; ++y) sum += scratch[at(x, std::clamp(y, 0, h - 1))];
        for (int y = 0; y < h; ++y)
        {
            img[at(x, y)] = static_cast<Pixel>(sum / span);
            sum += scratch[at(x, std::min(y + r + 1, h - 1))] - scratch[at(x, std::max(y - r, 0))];
        }
    }
}
} // namespace

void box_blur(std::vector<uint8_t>& img, int w, int h, int r)
{
    std::vector<uint8_t> scratch(img.size());
    box_blur_pass<uint8_t, int>(img, scratch, w, h, r);
}

void blur(Plane& a, int w, int h, int r)
{
    if (r < 1) return;
    Plane scratch(a.size());
    for (int pass = 0; pass < GAUSSIAN_BOX_PASSES; ++pass)
    {
        box_blur_pass<float, float>(a, scratch, w, h, r);
    }
}

namespace
{
// A picture being resampled: RGBA bytes, w x h.
struct Source
{
    const unsigned char* px;
    int w;
    int h;
    auto at(int x, int y, int c) const -> float
    {
        return px[(static_cast<size_t>(y) * w + x) * 4 + c];
    }
};

// Channel c (0..1) averaged over the source pixels that fall in pixel (x, y) of an s x s picture: for shrinking.
auto area_average(const Source& src, int s, int x, int y, int c) -> float
{
    const int x0 = x * src.w / s, x1 = std::max(x0 + 1, (x + 1) * src.w / s);
    const int y0 = y * src.h / s, y1 = std::max(y0 + 1, (y + 1) * src.h / s);
    float sum = 0;
    for (int sy = y0; sy < y1; ++sy)
    {
        for (int sx = x0; sx < x1; ++sx) sum += src.at(sx, sy, c);
    }
    return sum / (static_cast<float>((x1 - x0) * (y1 - y0)) * 255.f);
}

// Channel c (0..1) at pixel (x, y) of an s x s picture, mixed from the four source pixels around it: for growing.
auto bilinear(const Source& src, int s, int x, int y, int c) -> float
{
    const float fx = std::max(0.f, (x + 0.5f) * src.w / s - 0.5f), fy = std::max(0.f, (y + 0.5f) * src.h / s - 0.5f);
    const int ix = std::min(static_cast<int>(fx), src.w - 1), iy = std::min(static_cast<int>(fy), src.h - 1);
    const int jx = std::min(ix + 1, src.w - 1), jy = std::min(iy + 1, src.h - 1);
    const float tx = fx - ix, ty = fy - iy;
    auto v = [&](int sx, int sy) { return src.at(sx, sy, c) / 255.f; };
    return (v(ix, iy) * (1 - tx) + v(jx, iy) * tx) * (1 - ty) + (v(ix, jy) * (1 - tx) + v(jx, jy) * tx) * ty;
}

// Channels first .. first + count - 1 of the source at s x s, as floats 0..1, `count` per pixel: an area average
// when shrinking, bilinear when growing.
auto resample(const Source& src, int s, int first, int count) -> std::vector<float>
{
    std::vector<float> out(static_cast<size_t>(s) * s * count, 0.f);
    const bool shrinking = src.w >= s && src.h >= s;
    for (int y = 0; y < s; ++y)
    {
        for (int x = 0; x < s; ++x)
        {
            float* d = &out[(static_cast<size_t>(y) * s + x) * count];
            for (int c = 0; c < count; ++c)
            {
                d[c] = shrinking ? area_average(src, s, x, y, first + c) : bilinear(src, s, x, y, first + c);
            }
        }
    }
    return out;
}
} // namespace

auto load_channel(const std::string& path, int s, int ch, std::string& err) -> Plane
{
    int w = 0, h = 0;
    const StbPixels src = read_png(path, 4, w, h);
    if (!src)
    {
        err = read_failure(path);
        return {};
    }
    return resample(Source{src.get(), w, h}, s, ch, 1);
}

auto load_rgba(const std::string& path, int s, std::string& err) -> Rgba
{
    int w = 0, h = 0;
    const StbPixels src = read_png(path, 4, w, h);
    Rgba out;
    if (!src)
    {
        err = read_failure(path);
        return out;
    }
    out.s = s;
    out.px = resample(Source{src.get(), w, h}, s, 0, 4);
    return out;
}
} // namespace image_basics
