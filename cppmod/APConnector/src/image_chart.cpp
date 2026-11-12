// The explorer's-chart picture of the map (compose_chart in image_tools.hpp).
#include "image_tools.hpp"
#include "image_basics.hpp"
#include "image_land_sea.hpp"

#include <algorithm>
#include <cmath>
#include <vector>

using namespace image_basics;

namespace
{
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
    // Beyond the world's edge, the sea and land, and the map's brightness (image_land_sea.hpp).
    Plane Y;
    const LandAndSea planes = classify_map(map, gamma, &Y);
    const Plane& outside = planes.outside;
    const Plane& outS = planes.outside_soft;
    const Plane& land = planes.land;
    const Plane& landS = planes.land_soft;
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
    // Paper: the paper tile (two across the chart) or plain cream with mottling; darker toward the corners.
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
            const bool nearEdge = outS[i] > NEAR_EDGE_ABOVE;
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
