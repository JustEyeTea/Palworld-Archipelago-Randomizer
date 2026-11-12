// The greyscale pictures of the world map (greyscale_png, compose_map) and sample_png (image_tools.hpp).
#include "image_tools.hpp"
#include "image_basics.hpp"

#include <algorithm>
#include <cmath>
#include <memory>
#include <sstream>
#include <vector>

using namespace image_basics;

auto greyscale_png(const std::string& in, const std::string& out, double gamma) -> std::string
{
    int w = 0, h = 0;
    const StbPixels px = read_png(in, 4, w, h);
    if (!px) return read_failure(in);
    const GammaTable lut = gamma_table(gamma);
    for (long i = 0, count = static_cast<long>(w) * h; i < count; ++i)
    {
        unsigned char* p = px.get() + i * 4;
        const double y = 0.2126 * lut[p[0]] + 0.7152 * lut[p[1]] + 0.0722 * lut[p[2]];
        p[0] = p[1] = p[2] = static_cast<unsigned char>(std::lround(y));
    }
    return stbi_write_png(out.c_str(), w, h, 4, px.get(), w * 4) ? "" : "could not write " + out;
}

auto compose_map(const std::string& colour, const std::string& labels, const std::string& locked, const std::string& out,
                 double gamma) -> std::string
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
    const size_t count = static_cast<size_t>(w) * h;
    std::vector<uint8_t> hard(count), soft(count), shade(count);
    for (size_t i = 0; i < count; ++i) hard[i] = lockedArea[lab.get()[i]] ? 255 : 0;
    soft = hard;
    shade = hard;
    const int edge = std::max(1, w / 2048);         // soft boundary: a couple of pixels at 4096
    const int shadow = std::max(2, w / 400);        // inner shadow: about 10 pixels at 4096, three passes
    for (int pass = 0; pass < 3; ++pass)
    {
        box_blur(soft, w, h, edge);
        box_blur(shade, w, h, shadow);
    }
    const GammaTable lut = gamma_table(gamma);
    unsigned char* p = px.get();
    for (size_t i = 0; i < count; ++i, p += 4)
    {
        const double m = soft[i] / 255.0;
        if (m <= 0) { p[0] = lut[p[0]]; p[1] = lut[p[1]]; p[2] = lut[p[2]]; continue; }
        const double r = lut[p[0]], g = lut[p[1]], b = lut[p[2]];
        const double y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
        const double dark = std::min(1.0, std::max(0.45, 1.0 - 1.1 * (1.0 - shade[i] / 255.0)));   // 0.45 at the edge
        const double gy = y * dark;
        p[0] = static_cast<unsigned char>(std::lround(r * (1 - m) + gy * m));
        p[1] = static_cast<unsigned char>(std::lround(g * (1 - m) + gy * m));
        p[2] = static_cast<unsigned char>(std::lround(b * (1 - m) + gy * m));
        p[3] = 255;
    }
    stbi_write_png_compression_level = 1;            // speed over size: the file is only read back once
    return stbi_write_png(out.c_str(), w, h, 4, px.get(), w * 4) ? "" : "could not write " + out;
}

auto sample_png(const std::string& path, double u, double v) -> std::string
{
    int w = 0, h = 0;
    const StbPixels px = read_png(path, 4, w, h);
    if (!px) return "error: " + read_failure(path);
    const int cx = std::min(std::max(static_cast<int>(u * w), 0), w - 1), cy = std::min(std::max(static_cast<int>(v * h), 0), h - 1);
    int sum[4] = {}, count = 0;
    for (int y = std::max(cy - 1, 0); y <= std::min(cy + 1, h - 1); ++y)
        for (int x = std::max(cx - 1, 0); x <= std::min(cx + 1, w - 1); ++x, ++count)
            for (int c = 0; c < 4; ++c) sum[c] += px.get()[(static_cast<size_t>(y) * w + x) * 4 + c];
    std::ostringstream out;
    out << sum[0] / count << "," << sum[1] / count << "," << sum[2] / count << "," << sum[3] / count;
    return out.str();
}
