#include "image_tools.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <memory>
#include <mutex>
#include <sstream>
#include <thread>
#include <vector>

#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

auto greyscale_png(const std::string& in, const std::string& out, double gamma) -> std::string
{
    int w = 0, h = 0, n = 0;
    unsigned char* px = stbi_load(in.c_str(), &w, &h, &n, 4);
    if (!px) return std::string("could not read ") + in + ": " + stbi_failure_reason();
    unsigned char lut[256];
    for (int i = 0; i < 256; ++i)
        lut[i] = static_cast<unsigned char>(std::lround(255.0 * std::pow(i / 255.0, gamma)));
    for (long i = 0, count = static_cast<long>(w) * h; i < count; ++i)
    {
        unsigned char* p = px + i * 4;
        const double y = 0.2126 * lut[p[0]] + 0.7152 * lut[p[1]] + 0.0722 * lut[p[2]];
        p[0] = p[1] = p[2] = static_cast<unsigned char>(std::lround(y));
    }
    const int ok = stbi_write_png(out.c_str(), w, h, 4, px, w * 4);
    stbi_image_free(px);
    return ok ? "" : "could not write " + out;
}

namespace
{
// Box blur of an 8-bit image, horizontally then vertically; three passes come close to a Gaussian.
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
} // namespace

auto compose_map(const std::string& colour, const std::string& labels, const std::string& locked, const std::string& out,
                 double gamma) -> std::string
{
    int w = 0, h = 0, n = 0, lw = 0, lh = 0, ln = 0;
    std::unique_ptr<unsigned char, void (*)(void*)> px(stbi_load(colour.c_str(), &w, &h, &n, 4), stbi_image_free);
    if (!px) return "could not read " + colour + ": " + stbi_failure_reason();
    std::unique_ptr<unsigned char, void (*)(void*)> lab(stbi_load(labels.c_str(), &lw, &lh, &ln, 1), stbi_image_free);
    if (!lab) return "could not read " + labels + ": " + stbi_failure_reason();
    if (lw != w || lh != h) return "the labels picture is not the size of the map";
    bool lockedArea[256] = {};
    std::stringstream ss(locked);
    for (std::string item; std::getline(ss, item, ',');)
        if (!item.empty()) lockedArea[std::stoi(item) & 255] = true;
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
    unsigned char lut[256];
    for (int i = 0; i < 256; ++i) lut[i] = static_cast<unsigned char>(std::lround(255.0 * std::pow(i / 255.0, gamma)));
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

namespace
{
std::mutex compose_mutex;
std::string compose_state;                          // "busy", "done", "error: ..." or ""
} // namespace

auto compose_map_start(const std::string& colour, const std::string& labels, const std::string& locked,
                       const std::string& out, double gamma) -> std::string
{
    {
        std::lock_guard<std::mutex> lock(compose_mutex);
        if (compose_state == "busy") return "busy";
        compose_state = "busy";
    }
    std::thread([=] {
        std::string err;
        try { err = compose_map(colour, labels, locked, out, gamma); }
        catch (const std::exception& e) { err = e.what(); }
        std::lock_guard<std::mutex> lock(compose_mutex);
        compose_state = err.empty() ? "done" : "error: " + err;
    }).detach();
    return "";
}

auto compose_map_status() -> std::string
{
    std::lock_guard<std::mutex> lock(compose_mutex);
    std::string s = compose_state;
    if (s != "busy") compose_state.clear();
    return s;
}
