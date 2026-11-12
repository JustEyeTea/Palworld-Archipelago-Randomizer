// The Territories pictures: every area tinted by its state, and the standing walls (compose_territories and
// compose_field in image_tools.hpp).
#include "image_tools.hpp"
#include "image_basics.hpp"
#include "lua_text.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <memory>
#include <sstream>
#include <vector>

using namespace image_basics;

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
    float mapGlowA = 0.3f, mapCoreA = 0.5f;                       // compose_field's map picture (style fields 8, 9)
    float fogC[3] = {0.055f, 0.102f, 0.141f};
};

static auto parse_look(const std::string& areas, const std::string& style, const std::string& fog, TerrLook& t) -> std::string
{
    for (const auto& item : lua_text::split_csv(areas))
    {
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
            if ((f.size() != 7 && f.size() != 9) || !hex_rgb(f[0], t.glowC) || !hex_rgb(f[2], t.coreC)) throw 0;
            t.glowA = std::stof(f[1]); t.coreA = std::stof(f[3]); t.glowW = std::stof(f[4]); t.glowSigma = std::stof(f[5]);
            t.coreW = std::stof(f[6]);
            if (f.size() == 9) { t.mapGlowA = std::stof(f[7]); t.mapCoreA = std::stof(f[8]); }
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
    const float k = S / 4096.f;                                   // the style's px are of a 4096 map
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
                   const std::string& fog, int size, const std::string& colour, double gamma) -> std::string
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
    int cw = 0, ch = 0, cn = 0;
    std::unique_ptr<unsigned char, void (*)(void*)> col(nullptr, stbi_image_free);
    if (!colour.empty())
    {
        col.reset(stbi_load(colour.c_str(), &cw, &ch, &cn, 4));
        if (!col) return "could not read " + colour + ": " + stbi_failure_reason();
    }
    unsigned char lut[256];
    for (int i = 0; i < 256; ++i) lut[i] = static_cast<unsigned char>(std::lround(255.0 * std::pow(i / 255.0, gamma)));
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
    const float glowSd = t.glowW * 0.4f;                          // the glow across the border (4 px at the default 10)
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
            const int lab = R ? R : G;
            const char st = lab ? t.state[lab] : 0;
            const bool closed = R && (t.state[R] == 'l' || t.state[R] == 's');
            // The walls' colour on the map picture: the closed side's own colour, lighter, like a see-through version
            // of the area's border, where the fog picture keeps the cream.
            const int wallArea = closed ? R : G;
            float mapCore[3], mapGlow[3];
            for (int k2 = 0; k2 < 3; ++k2)
            {
                mapGlow[k2] = t.colour[wallArea][k2];
                mapCore[k2] = t.colour[wallArea][k2] * 0.6f + 0.4f;
            }
            const float up = std::min(1.f, std::max(0.f, 1.f - std::max(segd[i] - d - 4.f, 0.f) / 4.f));
            // One look over (c, a): fill and rim (an area's own pixels; the open sea's next to an area take its look over
            // the last part of a pixel, the field's smoothed distance, so the coast's edge is a curve, not the label map's
            // stairs), then the walls (a glow and a core across the border, where a standing piece is near, fading out past
            // its end; free pieces where they stand). map: the map picture's look (no fill on closed areas: they are
            // greyscale; the walls in the area's colour), else the fog's.
            auto paint = [&](float* c, float& a, bool map) {
                auto over = [&](const float* cl, float al) {
                    if (al <= 0.f) return;
                    const float ao = al + a * (1 - al);
                    for (int k2 = 0; k2 < 3; ++k2) c[k2] = ao > 0 ? (cl[k2] * al + c[k2] * a * (1 - al)) / ao : 0.f;
                    a = ao;
                };
                if (st)
                {
                    float fill = 0, rimA = 0;
                    state_alpha(st, fill, rimA);
                    if (col)                                      // (the duotone look: rims, no fills)
                    {
                        fill = 0.f;
                        rimA = st == 'v' ? 0.35f : st == 's' ? 0.65f : 0.80f;
                    }
                    const float cover = R ? 1.f : std::min(1.f, std::max(0.f, 1.f - d));
                    const float rim = std::exp(-std::max(d - 2.f, 0.f) / 7.f);
                    over(t.colour[lab], std::min(1.f, std::max(0.f, fill + rim * rimA)) * cover);
                }
                const float* gc = map ? mapGlow : t.glowC;
                const float* cc = map ? mapCore : t.coreC;
                const float ga = map ? t.mapGlowA : t.glowA, ca = map ? t.mapCoreA : t.coreA;
                if (up > 0.f)
                {
                    over(gc, ga * up * std::exp(-d * d / (2.f * glowSd * glowSd)));
                    over(cc, ca * up * std::min(1.f, std::max(0.f, t.coreW / 2.f + 0.5f - d)));
                }
                if (!freed.empty() && freed[i] < reach)
                {
                    const float e = freed[i];
                    over(t.glowC, ga * std::exp(-e * e / (2.f * glowSd * glowSd)));   // (out at sea, no area's: cream)
                    over(t.coreC, ca * std::min(1.f, std::max(0.f, t.coreW / 2.f + 0.5f - e)));
                }
            };
            auto byte = [](float v) { return static_cast<unsigned char>(std::lround(255.f * std::min(1.f, std::max(0.f, v)))); };
            if (col)
            {
                // The map picture: the player's own map (gamma to light), greyscale where the area is closed, the look over it.
                const int cx = std::min(cw - 1, (2 * x + 1) * cw / (2 * S)), cy = std::min(ch - 1, (2 * y + 1) * ch / (2 * S));
                const unsigned char* m = col.get() + (static_cast<size_t>(cy) * cw + cx) * 4;
                float c[3] = {lut[m[0]] / 255.f, lut[m[1]] / 255.f, lut[m[2]] / 255.f}, a = 1.f;
                if (closed)
                {
                    const float yv = 0.2126f * c[0] + 0.7152f * c[1] + 0.0722f * c[2];
                    c[0] = c[1] = c[2] = yv;
                }
                paint(c, a, true);
                for (int k2 = 0; k2 < 3; ++k2) o[i * 4 + k2] = byte(c[k2]);
                o[i * 4 + 3] = 255;
            }
            // The fog's look. With the colour map, the duotone: the open sea the map's brightness over the fog colour;
            // an area its own colour, dark to light with the map's brightness, dimmer while locked or sealed; then the
            // rims and the cream walls. Without it, the fills and rims over the fog colour, and that is also the
            // overlay (drawn over the game's map).
            float c[3] = {0, 0, 0}, a = 0;
            if (col && !f.empty())
            {
                const int cx = std::min(cw - 1, (2 * x + 1) * cw / (2 * S)), cy = std::min(ch - 1, (2 * y + 1) * ch / (2 * S));
                const unsigned char* m = col.get() + (static_cast<size_t>(cy) * cw + cx) * 4;
                const float lum = 0.30f * lut[m[0]] / 255.f + 0.55f * lut[m[1]] / 255.f + 0.15f * lut[m[2]] / 255.f;
                const char own = R ? t.state[R] : 0;
                if (!own)
                    for (int k2 = 0; k2 < 3; ++k2) c[k2] = lum * 0.42f + t.fogC[k2] * 0.58f;
                else
                {
                    const float tt = std::pow(std::min(1.f, std::max(0.f, (lum - 0.12f) / 0.60f)), 0.9f);
                    const float kk = own == 'l' ? 0.62f : own == 's' ? 0.55f : 0.85f;
                    for (int k2 = 0; k2 < 3; ++k2)
                    {
                        const float dark = t.fogC[k2] * 0.70f + t.colour[R][k2] * 0.22f;
                        const float light = (t.colour[R][k2] * 0.80f + 0.20f) * kk;
                        c[k2] = dark + (light - dark) * tt;
                    }
                }
                a = 1.f;
                paint(c, a, false);
                for (int k2 = 0; k2 < 3; ++k2) f[i * 3 + k2] = byte(c[k2]);
                continue;
            }
            if (!col || !f.empty()) paint(c, a, false);
            if (!col)
            {
                for (int k2 = 0; k2 < 3; ++k2) o[i * 4 + k2] = byte(c[k2]);
                o[i * 4 + 3] = byte(a);
            }
            if (!f.empty())
                for (int k2 = 0; k2 < 3; ++k2) f[i * 3 + k2] = byte(c[k2] * a + t.fogC[k2] * (1 - a));
        }
    fld.reset();
    col.reset();
    Plane().swap(segd);
    Plane().swap(freed);
    stbi_write_png_compression_level = 1;
    if (!stbi_write_png(out.c_str(), S, S, 4, o.data(), S * 4)) return "could not write " + out;
    if (!f.empty() && !stbi_write_png(fogart.c_str(), S, S, 3, f.data(), S * 3)) return "could not write " + fogart;
    return "";
}
