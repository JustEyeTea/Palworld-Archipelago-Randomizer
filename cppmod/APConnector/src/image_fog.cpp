// The fog picture: the chart where the player hasn't explored, with the areas' borders and the locks' stamps
// (compose_fog in image_tools.hpp).
#include "image_tools.hpp"
#include "image_basics.hpp"
#include "image_land_sea.hpp"

#include <algorithm>
#include <cmath>
#include <memory>
#include <sstream>
#include <vector>

using namespace image_basics;

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
    bool locked[AREA_LABELS] = {};
    const std::string badLocked = read_locked_areas(f[1], locked);
    if (!badLocked.empty()) return "regions: " + badLocked;
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
