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
    for (int pass = 0; pass < 3; ++pass)
    {
        box_blur_pass<float, float>(a, scratch, w, h, r);
    }
}

auto load_channel(const std::string& path, int s, int ch, std::string& err) -> Plane
{
    int w = 0, h = 0;
    const StbPixels src = read_png(path, 4, w, h);
    Plane out;
    if (!src) { err = read_failure(path); return out; }
    out.assign(static_cast<size_t>(s) * s, 0.f);
    const unsigned char* p = src.get();
    auto v = [&](int xx, int yy) { return p[(static_cast<size_t>(yy) * w + xx) * 4 + ch] / 255.f; };
    for (int y = 0; y < s; ++y)
        for (int x = 0; x < s; ++x)
        {
            float& d = out[static_cast<size_t>(y) * s + x];
            if (w >= s && h >= s)
            {
                const int x0 = x * w / s, x1 = std::max(x0 + 1, (x + 1) * w / s);
                const int y0 = y * h / s, y1 = std::max(y0 + 1, (y + 1) * h / s);
                float acc = 0;
                for (int yy = y0; yy < y1; ++yy)
                    for (int xx = x0; xx < x1; ++xx) acc += v(xx, yy);
                d = acc / static_cast<float>((x1 - x0) * (y1 - y0));
            }
            else
            {
                const float fx = std::max(0.f, (x + 0.5f) * w / s - 0.5f), fy = std::max(0.f, (y + 0.5f) * h / s - 0.5f);
                const int ix = std::min(static_cast<int>(fx), w - 1), iy = std::min(static_cast<int>(fy), h - 1);
                const int jx = std::min(ix + 1, w - 1), jy = std::min(iy + 1, h - 1);
                const float tx = fx - ix, ty = fy - iy;
                d = (v(ix, iy) * (1 - tx) + v(jx, iy) * tx) * (1 - ty) + (v(ix, jy) * (1 - tx) + v(jx, jy) * tx) * ty;
            }
        }
    return out;
}

auto load_rgba(const std::string& path, int s, std::string& err) -> Rgba
{
    int w = 0, h = 0;
    const StbPixels src = read_png(path, 4, w, h);
    Rgba out;
    if (!src) { err = read_failure(path); return out; }
    out.s = s;
    out.px.assign(static_cast<size_t>(s) * s * 4, 0.f);
    const unsigned char* p = src.get();
    for (int y = 0; y < s; ++y)
        for (int x = 0; x < s; ++x)
        {
            float* d = &out.px[(static_cast<size_t>(y) * s + x) * 4];
            if (w >= s && h >= s)
            {
                const int x0 = x * w / s, x1 = std::max(x0 + 1, (x + 1) * w / s);
                const int y0 = y * h / s, y1 = std::max(y0 + 1, (y + 1) * h / s);
                float acc[4] = {};
                for (int yy = y0; yy < y1; ++yy)
                    for (int xx = x0; xx < x1; ++xx)
                        for (int c = 0; c < 4; ++c) acc[c] += p[(static_cast<size_t>(yy) * w + xx) * 4 + c];
                const float n2 = static_cast<float>((x1 - x0) * (y1 - y0)) * 255.f;
                for (int c = 0; c < 4; ++c) d[c] = acc[c] / n2;
            }
            else
            {
                const float fx = std::max(0.f, (x + 0.5f) * w / s - 0.5f), fy = std::max(0.f, (y + 0.5f) * h / s - 0.5f);
                const int ix = std::min(static_cast<int>(fx), w - 1), iy = std::min(static_cast<int>(fy), h - 1);
                const int jx = std::min(ix + 1, w - 1), jy = std::min(iy + 1, h - 1);
                const float tx = fx - ix, ty = fy - iy;
                for (int c = 0; c < 4; ++c)
                {
                    auto v = [&](int xx, int yy) { return p[(static_cast<size_t>(yy) * w + xx) * 4 + c] / 255.f; };
                    d[c] = (v(ix, iy) * (1 - tx) + v(jx, iy) * tx) * (1 - ty) + (v(ix, jy) * (1 - tx) + v(jx, jy) * tx) * ty;
                }
            }
        }
    return out;
}
} // namespace image_basics
