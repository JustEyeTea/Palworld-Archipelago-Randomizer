#include "image_tools.hpp"

#include <algorithm>
#include <array>
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

// The slots are globals that live all session, so a detached job may keep a pointer to its slot.
auto JobSlot::start(std::function<std::string()> job) -> std::string
{
    {
        std::lock_guard<std::mutex> guard(m_lock);
        if (m_state == "busy") return "busy";
        m_state = "busy";
    }
    std::thread([this, job] {
        std::string err;
        try { err = job(); }
        catch (const std::exception& e) { err = e.what(); }
        std::lock_guard<std::mutex> guard(m_lock);
        m_state = err.empty() ? "done" : "error: " + err;
    }).detach();
    return "";
}

auto JobSlot::status() -> std::string
{
    std::lock_guard<std::mutex> guard(m_lock);
    std::string st = m_state;
    if (st != "busy") m_state.clear();
    return st;
}

namespace
{
JobSlot map_slot, chart_slot, fog_slot, territory_slot;
} // namespace

auto chart_jobs() -> JobSlot& { return chart_slot; }
auto fog_jobs() -> JobSlot& { return fog_slot; }
auto territory_jobs() -> JobSlot& { return territory_slot; }

auto compose_map_start(const std::string& colour, const std::string& labels, const std::string& locked,
                       const std::string& out, double gamma) -> std::string
{
    return map_slot.start([=] { return compose_map(colour, labels, locked, out, gamma); });
}

auto compose_map_status() -> std::string
{
    return map_slot.status();
}

namespace
{
using Plane = std::vector<float>;

// Box blur of a float plane, three passes (close to a Gaussian), as box_blur above.
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

// An RGBA picture as floats 0..1, resampled to s x s (area average when shrinking, bilinear when growing).
struct Rgba
{
    int s = 0;
    std::vector<float> px;          // s * s * 4
    const float* at(int x, int y) const { return &px[(static_cast<size_t>(y) * s + x) * 4]; }
};

// One channel of a PNG as floats 0..1, resampled to s x s as load_rgba does (for the fog's masks: a quarter of the
// memory of load_rgba, which matters at 4096).
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

// A line about `width` pixels wide where a soft mask crosses `level` (from its gradient), 0..1.
auto contour_line(const Plane& m, int s, float level, float width) -> Plane
{
    Plane out(m.size(), 0.f);
    for (int y = 0; y < s; ++y)
        for (int x = 0; x < s; ++x)
        {
            auto v = [&](int xx, int yy) { return m[static_cast<size_t>(std::min(std::max(yy, 0), s - 1)) * s + std::min(std::max(xx, 0), s - 1)]; };
            const float gx = (v(x + 1, y) - v(x - 1, y)) * 0.5f, gy = (v(x, y + 1) - v(x, y - 1)) * 0.5f;
            const float g = std::sqrt(gx * gx + gy * gy) + 1e-6f;
            out[static_cast<size_t>(y) * s + x] = std::min(1.f, std::max(0.f, 1.5f - std::fabs(v(x, y) - level) / (g * width)));
        }
    return out;
}

// Deterministic noise, so the same map always gives the same chart.
auto noise_plane(int s, unsigned seed) -> Plane
{
    Plane p(static_cast<size_t>(s) * s);
    unsigned long long st = seed * 2654435761ULL + 1;
    for (auto& v : p)
    {
        st = st * 6364136223846793005ULL + 1442695040888963407ULL;
        v = static_cast<float>((st >> 40) & 0xFFFFFF) / 16777216.f;
    }
    return p;
}

void normalise(Plane& p)
{
    double mean = 0, sq = 0;
    for (float v : p) mean += v;
    mean /= p.size();
    for (float v : p) sq += (v - mean) * (v - mean);
    const float sd = static_cast<float>(std::sqrt(sq / p.size())) + 1e-6f;
    for (auto& v : p) v = static_cast<float>((v - mean) / sd);
}
} // namespace

auto compose_chart(const std::string& colour, const std::string& paper, const std::string& sea, const std::string& compass,
                   const std::string& out, int size, double gamma) -> std::string
{
    const int S = size;
    if (S < 64 || S > 8192) return "chart size " + std::to_string(S);
    std::string err;
    Rgba map = load_rgba(colour, S, err);
    if (!err.empty()) return err;
    const size_t N = static_cast<size_t>(S) * S;
    // The map as compose_map reads it: gamma on each channel (the export is in linear light).
    Plane R(N), G(N), B(N), Y(N);
    for (size_t i = 0; i < N; ++i)
    {
        const float* p = &map.px[i * 4];
        R[i] = static_cast<float>(std::pow(p[0], gamma));
        G[i] = static_cast<float>(std::pow(p[1], gamma));
        B[i] = static_cast<float>(std::pow(p[2], gamma));
        Y[i] = 0.2126f * R[i] + 0.7152f * G[i] + 0.0722f * B[i];
    }
    // Beyond the world's edge the map is flat dark grey; the sea is teal (deep and shallow); the rest is land.
    Plane outside(N), sea_m(N), land(N);
    for (size_t i = 0; i < N; ++i)
    {
        outside[i] = (std::fabs(R[i] - G[i]) < 0.02f && std::fabs(G[i] - B[i]) < 0.02f && Y[i] < 0.16f) ? 1.f : 0.f;
        sea_m[i] = (!outside[i] && B[i] > R[i] + 0.08f && G[i] > R[i] && Y[i] < 0.45f && R[i] < 0.25f) ? 1.f : 0.f;
    }
    Plane outS = outside;
    blur(outS, S, S, std::max(2, S / 250));
    Plane seaS = sea_m;
    blur(seaS, S, S, std::max(1, S / 1000));
    for (size_t i = 0; i < N; ++i) land[i] = (!outside[i] && outS[i] <= 0.02f && seaS[i] < 0.5f) ? 1.f : 0.f;
    Plane landS = land;
    blur(landS, S, S, std::max(1, S / 700));
    const Plane coast = contour_line(landS, S, 0.5f, 1.2f);
    Plane outWide = outside;
    blur(outWide, S, S, std::max(3, S / 120));
    const Plane frame1 = contour_line(outS, S, 0.5f, 1.4f), frame2 = contour_line(outWide, S, 0.06f, 0.8f);
    // Coastal ripple rings: where a wide blur of the land crosses set levels, over the sea.
    Plane far = land;
    blur(far, S, S, std::max(2, S / 160));
    // Land: contour lines from banded brightness, and relief from fine detail.
    Plane Yb = Y;
    blur(Yb, S, S, std::max(1, S / 400));
    Plane Yd = Y;
    blur(Yd, S, S, std::max(2, S / 250));
    Plane nearLand = land;
    blur(nearLand, S, S, std::max(2, S / 100));
    // Paper: the Art lane's tile (two across the chart) or plain cream with mottling; darker toward the corners.
    Rgba paperTile, seaTile, compassArt;
    if (!paper.empty()) { paperTile = load_rgba(paper, S / 2, err); if (!err.empty()) return err; }
    if (!sea.empty()) { seaTile = load_rgba(sea, std::max(128, S / 4), err); if (!err.empty()) return err; }
    if (!compass.empty()) { compassArt = load_rgba(compass, S / 5, err); if (!err.empty()) return err; }
    Plane mott, fib;
    if (paperTile.s == 0)
    {
        mott = noise_plane(S, 7);
        blur(mott, S, S, std::max(1, S / 60));
        normalise(mott);
        fib = noise_plane(S, 11);
        blur(fib, S, S, 1);
        normalise(fib);
    }
    const float ink_c[3] = {0.231f, 0.165f, 0.102f};
    std::vector<unsigned char> img(N * 3);
    for (int y = 0; y < S; ++y)
        for (int x = 0; x < S; ++x)
        {
            const size_t i = static_cast<size_t>(y) * S + x;
            const float fx = static_cast<float>(x) / S, fy = static_cast<float>(y) / S;
            const float vig = 1.f - 0.18f * std::min(1.f, std::max(0.f, (std::hypot(fx - 0.5f, fy - 0.5f) - 0.35f) / 0.35f));
            float base[3];
            if (paperTile.s)
            {
                const float* t = paperTile.at(x % paperTile.s, y % paperTile.s);
                for (int c = 0; c < 3; ++c) base[c] = t[c] * vig;
            }
            else
            {
                const float k = (1.f + 0.025f * mott[i] + 0.012f * fib[i]) * vig;
                base[0] = 0.918f * k; base[1] = 0.859f * k; base[2] = 0.706f * k;
            }
            static const float landT[3] = {1.03f, 1.02f, 0.98f}, seaT[3] = {0.90f, 0.95f, 1.00f}, beyondT[3] = {0.80f, 0.76f, 0.70f};
            const float* tint = land[i] ? landT : (outside[i] ? beyondT : seaT);
            float ink = 0;
            ink = std::max(ink, coast[i]);
            ink = std::max(ink, std::max(frame1[i], 0.6f * frame2[i]));
            const bool nearEdge = outS[i] > 0.02f;
            if (!land[i] && !nearEdge)
                for (float lvl : {0.30f, 0.12f, 0.04f})
                    ink = std::max(ink, std::min(1.f, std::max(0.f, 1.f - std::fabs(far[i] - lvl) / 0.012f)) * 0.45f);
            if (land[i])
            {
                auto band = [&](int xx, int yy) { return std::floor(Yb[static_cast<size_t>(yy) * S + xx] * 7.f); };
                const bool edge = (x + 1 < S && band(x, y) != band(x + 1, y)) || (y + 1 < S && band(x, y) != band(x, y + 1));
                if (edge) ink = std::max(ink, 0.35f);
                ink = std::max(ink, std::min(1.f, std::max(0.f, (Y[i] - Yd[i]) * -2.5f)) * 0.22f);
            }
            if (outS[i] > 0.5f && ((x + y) % 9 == 0 || ((x - y) % 9 + 9) % 9 == 0)) ink = std::max(ink, 0.22f);
            if (seaTile.s && !land[i] && !nearEdge && nearLand[i] < 0.02f)
                ink = std::max(ink, seaTile.at(x % seaTile.s, y % seaTile.s)[3] * 0.9f);
            float col[3];
            for (int c = 0; c < 3; ++c) col[c] = base[c] * tint[c] * (1 - ink * 0.85f) + ink_c[c] * ink * 0.85f;
            if (compassArt.s)   // in the hatched corner beyond the frame's top-left
            {
                const int cx = x - static_cast<int>(S * 0.07f), cy = y - static_cast<int>(S * 0.08f);
                if (cx >= 0 && cy >= 0 && cx < compassArt.s && cy < compassArt.s)
                {
                    const float* a = compassArt.at(cx, cy);
                    for (int c = 0; c < 3; ++c) col[c] = col[c] * (1 - a[3]) + a[c] * a[3];
                }
            }
            for (int c = 0; c < 3; ++c) img[i * 3 + c] = static_cast<unsigned char>(std::lround(255.f * std::min(1.f, std::max(0.f, col[c]))));
        }
    stbi_write_png_compression_level = 1;
    return stbi_write_png(out.c_str(), S, S, 3, img.data(), S * 3) ? "" : "could not write " + out;
}

// Where the map is land (0..1, softened), as compose_chart tells land from sea and from beyond the world's edge.
static auto land_mask(const std::string& colour, int S, double gamma, std::string& err) -> Plane
{
    Rgba map = load_rgba(colour, S, err);
    if (!err.empty()) return {};
    const size_t N = static_cast<size_t>(S) * S;
    Plane outside(N), sea_m(N), land(N);
    for (size_t i = 0; i < N; ++i)
    {
        const float* p = &map.px[i * 4];
        const float R = static_cast<float>(std::pow(p[0], gamma)), G = static_cast<float>(std::pow(p[1], gamma)),
                    B = static_cast<float>(std::pow(p[2], gamma));
        const float Y = 0.2126f * R + 0.7152f * G + 0.0722f * B;
        outside[i] = (std::fabs(R - G) < 0.02f && std::fabs(G - B) < 0.02f && Y < 0.16f) ? 1.f : 0.f;
        sea_m[i] = (!outside[i] && B > R + 0.08f && G > R && Y < 0.45f && R < 0.25f) ? 1.f : 0.f;
    }
    Plane outS = outside;
    blur(outS, S, S, std::max(2, S / 250));
    blur(sea_m, S, S, std::max(1, S / 1000));
    for (size_t i = 0; i < N; ++i) land[i] = (!outside[i] && outS[i] <= 0.02f && sea_m[i] < 0.5f) ? 1.f : 0.f;
    blur(land, S, S, std::max(1, S / 700));
    return land;
}

// The regions on the chart (see compose_fog in image_tools.hpp): a hatch over locked areas, then borders between areas
// (both sides land: label 0 is no area, whose edge is the coast the chart already inks).
static auto draw_regions(Rgba& art, int S, const std::string& regions) -> std::string
{
    if (regions.empty()) return "";
    std::vector<std::string> f;
    {
        std::stringstream ss(regions);
        for (std::string p; std::getline(ss, p, '|');) f.push_back(p);
        if (!regions.empty() && regions.back() == '|') f.push_back("");
    }
    if (f.size() != 8 && f.size() != 10) return "regions '" + regions + "': want 8 or 10 fields";
    int lw = 0, lh = 0, ln = 0;
    std::unique_ptr<unsigned char, void (*)(void*)> lab(stbi_load(f[0].c_str(), &lw, &lh, &ln, 1), stbi_image_free);
    if (!lab) return "could not read " + f[0] + ": " + stbi_failure_reason();
    bool locked[256] = {};
    {
        std::stringstream ls(f[1]);
        for (std::string p; std::getline(ls, p, ',');)
        {
            try { const int k = std::stoi(p); if (k >= 0 && k < 256) locked[k] = true; } catch (...) {}
        }
    }
    float ink[4] = {0.231f, 0.165f, 0.102f, 0.8f};
    float width = 2.f, dash = 0.f, gap = 0.f, hop = 0.25f;
    try
    {
        std::stringstream cs(f[3]);
        int c = 0;
        for (std::string p; std::getline(cs, p, ',') && c < 4; ++c) ink[c] = std::stof(p) / 255.f;
        width = std::stof(f[4]); dash = std::stof(f[5]); gap = std::stof(f[6]); hop = std::stof(f[7]);
    }
    catch (...) { return "regions '" + regions + "': a number would not read"; }
    int tw = 0, th = 0, tn = 0;
    std::unique_ptr<unsigned char, void (*)(void*)> tile(nullptr, stbi_image_free);
    if (!f[2].empty())
    {
        tile.reset(stbi_load(f[2].c_str(), &tw, &th, &tn, 4));
        if (!tile) return "could not read " + f[2] + ": " + stbi_failure_reason();
    }
    const size_t N = static_cast<size_t>(S) * S;
    Plane land;                                       // empty: everywhere counts as land
    if (f.size() == 10 && !f[8].empty())
    {
        double gamma = 1.0;
        try { gamma = std::stod(f[9]); } catch (...) { return "regions: gamma '" + f[9] + "'"; }
        std::string err;
        land = land_mask(f[8], S, gamma, err);
        if (!err.empty()) return err;
    }
    auto onLand = [&](size_t i) { return land.empty() ? 1.f : land[i]; };
    std::vector<unsigned char> L(N);
    for (int y = 0; y < S; ++y)
        for (int x = 0; x < S; ++x)
        {
            const int lx = std::min(lw - 1, (2 * x + 1) * lw / (2 * S)), ly = std::min(lh - 1, (2 * y + 1) * lh / (2 * S));
            L[static_cast<size_t>(y) * S + x] = lab.get()[static_cast<size_t>(ly) * lw + lx];
        }
    auto blend = [&](size_t i, const float* c, float a) {
        float* d = &art.px[i * 4];
        for (int k = 0; k < 3; ++k) d[k] = d[k] * (1 - a) + c[k] * a;
    };
    // The hatch over locked areas.
    for (int y = 0; y < S; ++y)
        for (int x = 0; x < S; ++x)
        {
            const size_t i = static_cast<size_t>(y) * S + x;
            if (!L[i] || !locked[L[i]]) continue;
            const float l = onLand(i);
            if (l <= 0.f) continue;
            if (tile)
            {
                const unsigned char* t = tile.get() + (static_cast<size_t>(y % th) * tw + (x % tw)) * 4;
                const float c[3] = {t[0] / 255.f, t[1] / 255.f, t[2] / 255.f};
                blend(i, c, t[3] / 255.f * hop * l);
            }
            else if (std::fmod(static_cast<float>(x + y), 14.f) < 1.6f)
                blend(i, ink, hop * l);
        }
    // The borders: pixels whose right or lower neighbour is another area (both land), then the distance along each
    // border from where a walk over it began (8-connected), for the dashes; then each kept pixel inked as a small disc.
    std::vector<int> dist(N, -1);
    std::vector<size_t> edge;
    for (int y = 0; y + 1 < S; ++y)
        for (int x = 0; x + 1 < S; ++x)
        {
            const size_t i = static_cast<size_t>(y) * S + x;
            const unsigned char a = L[i], r = L[i + 1], d = L[i + S];
            const bool here = onLand(i) >= 0.5f;
            if (a && here && ((r && r != a && onLand(i + 1) >= 0.5f) || (d && d != a && onLand(i + S) >= 0.5f)))
            {
                dist[i] = -2;
                edge.push_back(i);
            }
        }
    std::vector<size_t> queue;
    for (size_t start : edge)
    {
        if (dist[start] != -2) continue;
        dist[start] = 0;
        queue.assign(1, start);
        for (size_t q = 0; q < queue.size(); ++q)
        {
            const size_t i = queue[q];
            const int x = static_cast<int>(i % S), y = static_cast<int>(i / S);
            for (int dy = -1; dy <= 1; ++dy)
                for (int dx = -1; dx <= 1; ++dx)
                {
                    const int nx = x + dx, ny = y + dy;
                    if ((!dx && !dy) || nx < 0 || ny < 0 || nx >= S || ny >= S) continue;
                    const size_t j = static_cast<size_t>(ny) * S + nx;
                    if (dist[j] != -2) continue;
                    dist[j] = dist[i] + 1;
                    queue.push_back(j);
                }
        }
    }
    const float period = dash + gap;
    const int r = std::max(0, static_cast<int>(std::lround(width / 2.f - 0.5f)));
    std::vector<float> cover(N, 0.f);
    for (size_t i : edge)
    {
        if (dash > 0.f && period > 0.f && std::fmod(static_cast<float>(dist[i]), period) >= dash) continue;
        const int x = static_cast<int>(i % S), y = static_cast<int>(i / S);
        for (int dy = -r; dy <= r; ++dy)
            for (int dx = -r; dx <= r; ++dx)
            {
                const int nx = x + dx, ny = y + dy;
                if (nx < 0 || ny < 0 || nx >= S || ny >= S || dx * dx + dy * dy > r * r + r) continue;
                cover[static_cast<size_t>(ny) * S + nx] = 1.f;
            }
    }
    blur(cover, S, S, 1);                             // a softened edge: no stair steps when the map is zoomed in
    for (size_t i = 0; i < N; ++i)
        if (cover[i] > 0.f) blend(i, ink, ink[3] * std::min(1.f, cover[i] * 1.5f));
    return "";
}

auto compose_fog(const std::string& chart, const std::string& mask, const std::string& default_mask,
                 const std::string& spec, const std::string& out, int size, const std::string& stamps,
                 const std::string& regions) -> std::string
{
    const int S = size;
    if (S < 64 || S > 8192) return "fog size " + std::to_string(S);
    if (spec.size() != 2 || std::string("rgba").find(spec[0]) == std::string::npos || (spec[1] != '+' && spec[1] != '-'))
        return "mask spec '" + spec + "' (want a channel r/g/b/a and + or -)";
    const int ch = static_cast<int>(std::string("rgba").find(spec[0]));
    const bool high = spec[1] == '+';
    std::string err;
    // The picture: as 8 bits when it is already this size and nothing is drawn on it (the Territories' fog art at 4096:
    // floats would take 256 MB more), else as floats.
    Rgba art;
    std::unique_ptr<unsigned char, void (*)(void*)> raw(nullptr, stbi_image_free);
    if (regions.empty())
    {
        int w = 0, h = 0, n = 0;
        raw.reset(stbi_load(chart.c_str(), &w, &h, &n, 4));
        if (!raw) return "could not read " + chart + ": " + stbi_failure_reason();
        if (w != S || h != S) raw.reset();
    }
    if (!raw)
    {
        art = load_rgba(chart, S, err);
        if (!err.empty()) return err;
        err = draw_regions(art, S, regions);
        if (!err.empty()) return err;
    }
    auto artAt = [&](size_t i, int c) { return raw ? raw.get()[i * 4 + c] / 255.f : art.px[i * 4 + c]; };
    const size_t N = static_cast<size_t>(S) * S;
    Plane explored = load_channel(mask, S, ch, err);
    if (!err.empty()) return err;
    if (!high) for (auto& e : explored) e = 1.f - e;
    if (!default_mask.empty())
    {
        const Plane d = load_channel(default_mask, S, ch, err);
        if (!err.empty()) return err;
        for (size_t i = 0; i < N; ++i) explored[i] = std::max(explored[i], high ? d[i] : 1.f - d[i]);
    }
    blur(explored, S, S, std::max(1, S / 400));       // soft, as the game blurs its fog's edge
    const float ink_c[3] = {0.231f, 0.165f, 0.102f};
    std::vector<unsigned char> img(N * 4);
    for (int y = 0; y < S; ++y)
        for (int x = 0; x < S; ++x)
        {
            const size_t i = static_cast<size_t>(y) * S + x;
            auto e = [&](int xx, int yy) { return explored[static_cast<size_t>(std::min(std::max(yy, 0), S - 1)) * S + std::min(std::max(xx, 0), S - 1)]; };
            const float gx = (e(x + 1, y) - e(x - 1, y)) * 0.5f, gy = (e(x, y + 1) - e(x, y - 1)) * 0.5f;
            const float wash = std::min(1.f, std::sqrt(gx * gx + gy * gy) * S / 50.f);   // an ink wash along the edge
            const float alpha = std::min(1.f, std::max(1.f - explored[i], 0.5f * wash));
            for (int c = 0; c < 3; ++c)
            {
                const float v = artAt(i, c) * (1 - 0.35f * wash) + ink_c[c] * 0.35f * wash;
                img[i * 4 + c] = static_cast<unsigned char>(std::lround(255.f * std::min(1.f, std::max(0.f, v))));
            }
            img[i * 4 + 3] = static_cast<unsigned char>(std::lround(255.f * alpha));
        }
    // The stamps, over the fog only (where it covers the map: on explored land the map's own picture has them).
    std::stringstream list(stamps);
    for (std::string item; std::getline(list, item, ';');)
    {
        if (item.empty()) continue;
        std::stringstream parts(item);
        std::string path, su, sv, spx;
        std::getline(parts, path, '|'); std::getline(parts, su, '|'); std::getline(parts, sv, '|'); std::getline(parts, spx, '|');
        double u = 0, v = 0, px = 0;
        try { u = std::stod(su); v = std::stod(sv); px = std::stod(spx); } catch (...) { return "stamp '" + item + "'"; }
        const int sp = std::max(4, static_cast<int>(std::lround(px * S / 4096.0)));
        Rgba st = load_rgba(path, sp, err);
        if (!err.empty()) return err;
        const int x0 = static_cast<int>(std::lround(u * S - sp / 2.0)), y0 = static_cast<int>(std::lround(v * S - sp / 2.0));
        for (int y = 0; y < sp; ++y)
            for (int x = 0; x < sp; ++x)
            {
                const int X = x0 + x, Y = y0 + y;
                if (X < 0 || Y < 0 || X >= S || Y >= S) continue;
                unsigned char* d = &img[(static_cast<size_t>(Y) * S + X) * 4];
                const float fog = d[3] / 255.f;
                const float* q = st.at(x, y);
                const float a = q[3] * fog;
                for (int k = 0; k < 3; ++k) d[k] = static_cast<unsigned char>(std::lround(d[k] * (1 - a) + 255.f * q[k] * a));
            }
    }
    stbi_write_png_compression_level = 1;
    return stbi_write_png(out.c_str(), S, S, 4, img.data(), S * 4) ? "" : "could not write " + out;
}

auto sample_png(const std::string& path, double u, double v) -> std::string
{
    int w = 0, h = 0, n = 0;
    std::unique_ptr<unsigned char, void (*)(void*)> px(stbi_load(path.c_str(), &w, &h, &n, 4), stbi_image_free);
    if (!px) return std::string("error: could not read ") + path + ": " + stbi_failure_reason();
    const int cx = std::min(std::max(static_cast<int>(u * w), 0), w - 1), cy = std::min(std::max(static_cast<int>(v * h), 0), h - 1);
    int sum[4] = {}, count = 0;
    for (int y = std::max(cy - 1, 0); y <= std::min(cy + 1, h - 1); ++y)
        for (int x = std::max(cx - 1, 0); x <= std::min(cx + 1, w - 1); ++x, ++count)
            for (int c = 0; c < 4; ++c) sum[c] += px.get()[(static_cast<size_t>(y) * w + x) * 4 + c];
    std::ostringstream out;
    out << sum[0] / count << "," << sum[1] / count << "," << sum[2] / count << "," << sum[3] / count;
    return out.str();
}

static auto hex_rgb(const std::string& h, float* c) -> bool
{
    if (h.size() != 6) return false;
    try
    {
        for (int k = 0; k < 3; ++k) c[k] = static_cast<float>(std::stoi(h.substr(k * 2, 2), nullptr, 16)) / 255.f;
    }
    catch (...) { return false; }
    return true;
}

// Draws a line's coverage into cov: hard (1 within hw of the segment) or anti-aliased (fading over the last pixel).
static void draw_segment(Plane& cov, int S, float x1, float y1, float x2, float y2, float hw, bool aa)
{
    const int x0 = std::max(0, static_cast<int>(std::floor(std::min(x1, x2) - hw - 2)));
    const int xe = std::min(S - 1, static_cast<int>(std::ceil(std::max(x1, x2) + hw + 2)));
    const int y0 = std::max(0, static_cast<int>(std::floor(std::min(y1, y2) - hw - 2)));
    const int ye = std::min(S - 1, static_cast<int>(std::ceil(std::max(y1, y2) + hw + 2)));
    const float dx = x2 - x1, dy = y2 - y1, len2 = dx * dx + dy * dy;
    for (int y = y0; y <= ye; ++y)
        for (int x = x0; x <= xe; ++x)
        {
            const float px = x + 0.5f, py = y + 0.5f;
            float t = len2 > 0 ? ((px - x1) * dx + (py - y1) * dy) / len2 : 0.f;
            t = std::min(1.f, std::max(0.f, t));
            const float qx = x1 + t * dx - px, qy = y1 + t * dy - py;
            const float d = std::sqrt(qx * qx + qy * qy);
            const float c = aa ? std::min(1.f, std::max(0.f, hw + 0.5f - d)) : (d <= hw ? 1.f : 0.f);
            float& v = cov[static_cast<size_t>(y) * S + x];
            v = std::max(v, c);
        }
}

// The Territories' look, shared by compose_territories and compose_field: each area's state and colour, the walls'
// style and the fog colour (see image_tools.hpp).
struct TerrLook
{
    char state[256] = {};
    float colour[256][3] = {};
    float glowC[3] = {1.f, 0.914f, 0.690f}, coreC[3] = {1.f, 0.957f, 0.863f};
    float glowA = 0.55f, coreA = 1.f, glowW = 10.f, glowSigma = 3.f, coreW = 5.f;
    float fogC[3] = {0.055f, 0.102f, 0.141f};
};

static auto parse_look(const std::string& areas, const std::string& style, const std::string& fog, TerrLook& t) -> std::string
{
    std::stringstream ss(areas);
    for (std::string item; std::getline(ss, item, ',');)
    {
        if (item.empty()) continue;
        const size_t a = item.find(':'), b = item.find(':', a + 1);
        if (a == std::string::npos || b == std::string::npos || b != a + 2) return "areas item '" + item + "'";
        int idx = -1;
        try { idx = std::stoi(item.substr(0, a)); } catch (...) {}
        if (idx < 0 || idx > 255) return "areas index in '" + item + "'";
        const char st = item[a + 1];
        if (std::string("vuls").find(st) == std::string::npos) return "areas state in '" + item + "'";
        if (!hex_rgb(item.substr(b + 1), t.colour[idx])) return "areas colour in '" + item + "'";
        t.state[idx] = st;
    }
    if (!style.empty())
    {
        std::vector<std::string> f;
        std::stringstream sf(style);
        for (std::string p; std::getline(sf, p, ',');) f.push_back(p);
        try
        {
            if (f.size() != 7 || !hex_rgb(f[0], t.glowC) || !hex_rgb(f[2], t.coreC)) throw 0;
            t.glowA = std::stof(f[1]); t.coreA = std::stof(f[3]); t.glowW = std::stof(f[4]); t.glowSigma = std::stof(f[5]);
            t.coreW = std::stof(f[6]);
        }
        catch (...) { return "style '" + style + "'"; }
    }
    if (!fog.empty() && !hex_rgb(fog, t.fogC)) return "fog colour '" + fog + "'";
    return "";
}

// An area's fill (all over it) and rim (along its edge) strength by state.
static void state_alpha(char st, float& fill, float& rimA)
{
    switch (st)
    {
    case 'v': fill = 0.f; rimA = 0.35f; break;
    case 'u': fill = 0.14f; rimA = 0.95f; break;
    case 'l': fill = 0.34f; rimA = 0.95f; break;
    default: fill = 0.50f; rimA = 0.80f; break;                   // sealed
    }
}

// The standing walls "u1,v1,u2,v2;..." (0..1 of the map square), times scale.
static auto parse_walls(const std::string& walls, float scale, std::vector<std::array<float, 4>>& segs) -> std::string
{
    std::stringstream ss(walls);
    for (std::string item; std::getline(ss, item, ';');)
    {
        if (item.empty()) continue;
        std::array<float, 4> s{};
        std::stringstream is(item);
        std::string p;
        for (int q = 0; q < 4; ++q)
        {
            if (!std::getline(is, p, ',')) return "walls item '" + item + "'";
            try { s[q] = std::stof(p) * scale; } catch (...) { return "walls item '" + item + "'"; }
        }
        segs.push_back(s);
    }
    return "";
}

auto compose_territories(const std::string& labels, const std::string& areas, const std::string& walls,
                         const std::string& style, const std::string& out, const std::string& fogart,
                         const std::string& fog, int size) -> std::string
{
    const int S = size;
    if (S < 64 || S > 4096) return "territories size " + std::to_string(S);
    const float k = S / 4096.f;                                   // the Art lane's px are of a 4096 map
    int lw = 0, lh = 0, ln = 0;
    std::unique_ptr<unsigned char, void (*)(void*)> lab(stbi_load(labels.c_str(), &lw, &lh, &ln, 1), stbi_image_free);
    if (!lab) return "could not read " + labels + ": " + stbi_failure_reason();
    TerrLook t;
    const std::string bad = parse_look(areas, style, fog, t);
    if (!bad.empty()) return bad;
    const char* state = t.state;
    const auto& colour = t.colour;
    const float *glowC = t.glowC, *coreC = t.coreC, *fogC = t.fogC;
    const float glowA = t.glowA, coreA = t.coreA, glowW = t.glowW, glowSigma = t.glowSigma, coreW = t.coreW;
    const size_t N = static_cast<size_t>(S) * S;
    std::vector<unsigned char> L(N);
    for (int y = 0; y < S; ++y)
        for (int x = 0; x < S; ++x)
        {
            const int lx = std::min(lw - 1, (2 * x + 1) * lw / (2 * S)), ly = std::min(lh - 1, (2 * y + 1) * lh / (2 * S));
            L[static_cast<size_t>(y) * S + x] = lab.get()[static_cast<size_t>(ly) * lw + lx];
        }
    // Distance to the area's edge (chamfer 3-4, two passes): 0 on edge pixels (an area pixel with another label, sea
    // included, among its 8 neighbours).
    const int INF = 1 << 28;
    std::vector<int> D(N, INF);
    for (int y = 0; y < S; ++y)
        for (int x = 0; x < S; ++x)
        {
            const size_t i = static_cast<size_t>(y) * S + x;
            if (!L[i]) continue;
            bool edge = false;
            for (int dy = -1; dy <= 1 && !edge; ++dy)
                for (int dx = -1; dx <= 1 && !edge; ++dx)
                {
                    const int nx = x + dx, ny = y + dy;
                    if (nx < 0 || ny < 0 || nx >= S || ny >= S) continue;
                    if (L[static_cast<size_t>(ny) * S + nx] != L[i]) edge = true;
                }
            if (edge) D[i] = 0;
        }
    for (int y = 0; y < S; ++y)
        for (int x = 0; x < S; ++x)
        {
            int& d = D[static_cast<size_t>(y) * S + x];
            if (x > 0) d = std::min(d, D[static_cast<size_t>(y) * S + x - 1] + 3);
            if (y > 0)
            {
                d = std::min(d, D[static_cast<size_t>(y - 1) * S + x] + 3);
                if (x > 0) d = std::min(d, D[static_cast<size_t>(y - 1) * S + x - 1] + 4);
                if (x + 1 < S) d = std::min(d, D[static_cast<size_t>(y - 1) * S + x + 1] + 4);
            }
        }
    for (int y = S - 1; y >= 0; --y)
        for (int x = S - 1; x >= 0; --x)
        {
            int& d = D[static_cast<size_t>(y) * S + x];
            if (x + 1 < S) d = std::min(d, D[static_cast<size_t>(y) * S + x + 1] + 3);
            if (y + 1 < S)
            {
                d = std::min(d, D[static_cast<size_t>(y + 1) * S + x] + 3);
                if (x + 1 < S) d = std::min(d, D[static_cast<size_t>(y + 1) * S + x + 1] + 4);
                if (x > 0) d = std::min(d, D[static_cast<size_t>(y + 1) * S + x - 1] + 4);
            }
        }
    // Fill and rim (straight alpha).
    std::vector<float> img(N * 4, 0.f);
    auto over = [&](size_t i, const float* c, float a) {
        if (a <= 0.f) return;
        float* p = &img[i * 4];
        const float ao = a + p[3] * (1 - a);
        for (int q = 0; q < 3; ++q) p[q] = ao > 0 ? (c[q] * a + p[q] * p[3] * (1 - a)) / ao : 0.f;
        p[3] = ao;
    };
    for (size_t i = 0; i < N; ++i)
    {
        const unsigned char a = L[i];
        if (!a || !state[a]) continue;
        float fill = 0, rimA = 0;
        state_alpha(state[a], fill, rimA);
        const float d = D[i] / 3.f / k;                           // in px of a 4096 map
        const float rim = std::exp(-std::max(d - 2.f, 0.f) / 7.f);
        over(i, colour[a], std::min(1.f, std::max(0.f, fill + rim * rimA)));
    }
    // The walls: a soft glow, then an anti-aliased core.
    std::vector<std::array<float, 4>> segs;
    const std::string badWalls = parse_walls(walls, static_cast<float>(S), segs);
    if (!badWalls.empty()) return badWalls;
    if (!segs.empty())
    {
        Plane glow(N, 0.f), core(N, 0.f);
        for (const auto& s : segs)
        {
            draw_segment(glow, S, s[0], s[1], s[2], s[3], glowW * k / 2.f, false);
            draw_segment(core, S, s[0], s[1], s[2], s[3], coreW * k / 2.f, true);
        }
        const float sigma = glowSigma * k;
        blur(glow, S, S, std::max(1, static_cast<int>(std::lround(std::sqrt(sigma * sigma + 0.25f) - 0.5f))));
        for (size_t i = 0; i < N; ++i)
        {
            over(i, glowC, glowA * std::min(1.f, glow[i]));
            over(i, coreC, coreA * core[i]);
        }
    }
    std::vector<unsigned char> o(N * 4);
    for (size_t i = 0; i < N * 4; ++i) o[i] = static_cast<unsigned char>(std::lround(255.f * std::min(1.f, std::max(0.f, img[i]))));
    stbi_write_png_compression_level = 1;
    if (!stbi_write_png(out.c_str(), S, S, 4, o.data(), S * 4)) return "could not write " + out;
    if (!fogart.empty())
    {
        std::vector<unsigned char> f(N * 3);
        for (size_t i = 0; i < N; ++i)
            for (int q = 0; q < 3; ++q)
            {
                const float a = img[i * 4 + 3];
                f[i * 3 + q] = static_cast<unsigned char>(std::lround(255.f * std::min(1.f, std::max(0.f, img[i * 4 + q] * a + fogC[q] * (1 - a)))));
            }
        if (!stbi_write_png(fogart.c_str(), S, S, 3, f.data(), S * 3)) return "could not write " + fogart;
    }
    return "";
}

auto compose_field(const std::string& field, const std::string& areas, const std::string& walls,
                   const std::string& style, const std::string& out, const std::string& fogart,
                   const std::string& fog, int size) -> std::string
{
    const int S = size;
    if (S < 64 || S > 4096) return "field size " + std::to_string(S);
    TerrLook t;
    const std::string bad = parse_look(areas, style, fog, t);
    if (!bad.empty()) return bad;
    int fw = 0, fh = 0, fn = 0;
    std::unique_ptr<unsigned char, void (*)(void*)> fld(stbi_load(field.c_str(), &fw, &fh, &fn, 3), stbi_image_free);
    if (!fld) return "could not read " + field + ": " + stbi_failure_reason();
    if (fw != fh) return "field " + field + " is not square";
    std::vector<std::array<float, 4>> segs;
    const std::string badWalls = parse_walls(walls, static_cast<float>(S), segs);
    if (!badWalls.empty()) return badWalls;
    const float k = S / 4096.f;                                   // the look's px are of a 4096 map
    const float toMap = 4096.f / fw;                              // field px -> px of a 4096 map
    const size_t N = static_cast<size_t>(S) * S;
    // How far each pixel is from the nearest standing wall piece (px of a 4096 map), near the pieces only: walls are drawn
    // along the field's borders only where a piece stands (some borders have none, and must show none). A piece away from
    // every border (the field's distance along it over 6 px: a few stand out at sea, as the box round an island) is drawn
    // where it stands instead, straight (free).
    const float glowSd = t.glowW * 0.4f;                          // the glow across the border (4 px at the Art lane's 10)
    const float reach = 3.f * glowSd + 10.f;
    auto fieldD = [&](float x, float y) {                         // (x, y in px at S)
        const int fx = std::min(fw - 1, std::max(0, static_cast<int>(x / S * fw)));
        const int fy = std::min(fh - 1, std::max(0, static_cast<int>(y / S * fh)));
        return fld.get()[(static_cast<size_t>(fy) * fw + fx) * 3 + 2] / 8.f * toMap;
    };
    Plane segd(N, 1e9f), freed;
    for (const auto& s : segs)
    {
        float along = 0;
        for (int q = 0; q <= 4; ++q) along += fieldD(s[0] + (s[2] - s[0]) * q / 4.f, s[1] + (s[3] - s[1]) * q / 4.f) / 5.f;
        const bool free = along > 6.f;
        if (free && freed.empty()) freed.assign(N, 1e9f);
        Plane& into = free ? freed : segd;
        const float r = reach * k;
        const int x0 = std::max(0, static_cast<int>(std::floor(std::min(s[0], s[2]) - r)));
        const int xe = std::min(S - 1, static_cast<int>(std::ceil(std::max(s[0], s[2]) + r)));
        const int y0 = std::max(0, static_cast<int>(std::floor(std::min(s[1], s[3]) - r)));
        const int ye = std::min(S - 1, static_cast<int>(std::ceil(std::max(s[1], s[3]) + r)));
        const float dx = s[2] - s[0], dy = s[3] - s[1], len2 = dx * dx + dy * dy;
        for (int y = y0; y <= ye; ++y)
            for (int x = x0; x <= xe; ++x)
            {
                const float px = x + 0.5f, py = y + 0.5f;
                float u = len2 > 0 ? ((px - s[0]) * dx + (py - s[1]) * dy) / len2 : 0.f;
                u = std::min(1.f, std::max(0.f, u));
                const float qx = s[0] + u * dx - px, qy = s[1] + u * dy - py;
                float& v = into[static_cast<size_t>(y) * S + x];
                v = std::min(v, std::sqrt(qx * qx + qy * qy) / k);
            }
    }
    std::vector<unsigned char> o(N * 4), f(fogart.empty() ? 0 : N * 3);
    for (int y = 0; y < S; ++y)
        for (int x = 0; x < S; ++x)
        {
            const size_t i = static_cast<size_t>(y) * S + x;
            const int fx = std::min(fw - 1, (2 * x + 1) * fw / (2 * S)), fy = std::min(fh - 1, (2 * y + 1) * fh / (2 * S));
            const unsigned char* q = fld.get() + (static_cast<size_t>(fy) * fw + fx) * 3;
            const int R = q[0], G = q[1];
            const float d = q[2] / 8.f * toMap;                   // to the nearest border, px of a 4096 map
            float c[3] = {0, 0, 0}, a = 0;
            auto over = [&](const float* col, float al) {
                if (al <= 0.f) return;
                const float ao = al + a * (1 - al);
                for (int k2 = 0; k2 < 3; ++k2) c[k2] = ao > 0 ? (col[k2] * al + c[k2] * a * (1 - al)) / ao : 0.f;
                a = ao;
            };
            // Fill and rim: an area's own pixels; the open sea's next to an area take its look over the last part of a
            // pixel (the field's smoothed distance), so the coast's edge is a curve, not the label map's stairs.
            const int lab = R ? R : G;
            if (lab && t.state[lab])
            {
                float fill = 0, rimA = 0;
                state_alpha(t.state[lab], fill, rimA);
                const float cover = R ? 1.f : std::min(1.f, std::max(0.f, 1.f - d));
                const float rim = std::exp(-std::max(d - 2.f, 0.f) / 7.f);
                over(t.colour[lab], std::min(1.f, std::max(0.f, fill + rim * rimA)) * cover);
            }
            // The walls: a glow and a core across the border, where a standing piece is near (fading out past its end).
            const float up = std::min(1.f, std::max(0.f, 1.f - std::max(segd[i] - d - 4.f, 0.f) / 4.f));
            if (up > 0.f)
            {
                over(t.glowC, t.glowA * up * std::exp(-d * d / (2.f * glowSd * glowSd)));
                over(t.coreC, t.coreA * up * std::min(1.f, std::max(0.f, t.coreW / 2.f + 0.5f - d)));
            }
            if (!freed.empty() && freed[i] < reach)
            {
                const float e = freed[i];
                over(t.glowC, t.glowA * std::exp(-e * e / (2.f * glowSd * glowSd)));
                over(t.coreC, t.coreA * std::min(1.f, std::max(0.f, t.coreW / 2.f + 0.5f - e)));
            }
            for (int k2 = 0; k2 < 3; ++k2)
            {
                o[i * 4 + k2] = static_cast<unsigned char>(std::lround(255.f * std::min(1.f, std::max(0.f, c[k2]))));
                if (!f.empty())
                    f[i * 3 + k2] = static_cast<unsigned char>(std::lround(255.f * std::min(1.f, std::max(0.f, c[k2] * a + t.fogC[k2] * (1 - a)))));
            }
            o[i * 4 + 3] = static_cast<unsigned char>(std::lround(255.f * std::min(1.f, std::max(0.f, a))));
        }
    fld.reset();
    Plane().swap(segd);
    Plane().swap(freed);
    stbi_write_png_compression_level = 1;
    if (!stbi_write_png(out.c_str(), S, S, 4, o.data(), S * 4)) return "could not write " + out;
    if (!f.empty() && !stbi_write_png(fogart.c_str(), S, S, 3, f.data(), S * 3)) return "could not write " + fogart;
    return "";
}
