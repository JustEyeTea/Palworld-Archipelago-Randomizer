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

void box_blur(std::vector<uint8_t>& img, int w, int h, int r)
{
    std::vector<uint8_t> tmp(img.size());
    const int span = 2 * r + 1;
    for (int y = 0; y < h; ++y)
    {
        const uint8_t* row = &img[static_cast<size_t>(y) * w];
        uint8_t* dst = &tmp[static_cast<size_t>(y) * w];
        int sum = 0;
        for (int x = -r; x <= r; ++x) sum += row[std::min(std::max(x, 0), w - 1)];
        for (int x = 0; x < w; ++x)
        {
            dst[x] = static_cast<uint8_t>(sum / span);
            sum += row[std::min(x + r + 1, w - 1)] - row[std::max(x - r, 0)];
        }
    }
    for (int x = 0; x < w; ++x)
    {
        int sum = 0;
        for (int y = -r; y <= r; ++y) sum += tmp[static_cast<size_t>(std::min(std::max(y, 0), h - 1)) * w + x];
        for (int y = 0; y < h; ++y)
        {
            img[static_cast<size_t>(y) * w + x] = static_cast<uint8_t>(sum / span);
            sum += tmp[static_cast<size_t>(std::min(y + r + 1, h - 1)) * w + x] - tmp[static_cast<size_t>(std::max(y - r, 0)) * w + x];
        }
    }
}

void blur(Plane& a, int w, int h, int r)
{
    if (r < 1) return;
    Plane tmp(a.size());
    const float span = static_cast<float>(2 * r + 1);
    for (int pass = 0; pass < 3; ++pass)
    {
        for (int y = 0; y < h; ++y)
        {
            const float* row = &a[static_cast<size_t>(y) * w];
            float* dst = &tmp[static_cast<size_t>(y) * w];
            float sum = 0;
            for (int x = -r; x <= r; ++x) sum += row[std::min(std::max(x, 0), w - 1)];
            for (int x = 0; x < w; ++x)
            {
                dst[x] = sum / span;
                sum += row[std::min(x + r + 1, w - 1)] - row[std::max(x - r, 0)];
            }
        }
        for (int x = 0; x < w; ++x)
        {
            float sum = 0;
            for (int y = -r; y <= r; ++y) sum += tmp[static_cast<size_t>(std::min(std::max(y, 0), h - 1)) * w + x];
            for (int y = 0; y < h; ++y)
            {
                a[static_cast<size_t>(y) * w + x] = sum / span;
                sum += tmp[static_cast<size_t>(std::min(y + r + 1, h - 1)) * w + x] - tmp[static_cast<size_t>(std::max(y - r, 0)) * w + x];
            }
        }
    }
}

auto load_channel(const std::string& path, int s, int ch, std::string& err) -> Plane
{
    int w = 0, h = 0, n = 0;
    std::unique_ptr<unsigned char, void (*)(void*)> src(stbi_load(path.c_str(), &w, &h, &n, 4), stbi_image_free);
    Plane out;
    if (!src) { err = "could not read " + path + ": " + stbi_failure_reason(); return out; }
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
    int w = 0, h = 0, n = 0;
    std::unique_ptr<unsigned char, void (*)(void*)> src(stbi_load(path.c_str(), &w, &h, &n, 4), stbi_image_free);
    Rgba out;
    if (!src) { err = "could not read " + path + ": " + stbi_failure_reason(); return out; }
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
