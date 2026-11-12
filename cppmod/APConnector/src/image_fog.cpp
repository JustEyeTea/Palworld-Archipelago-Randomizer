// The fog picture: the chart where the player hasn't explored and see-through where they have, with the areas'
// borders, a hatch over locked areas and the locks' stamps (compose_fog in image_tools.hpp, which defines the
// arguments' text).
#include "image_tools.hpp"
#include "image_basics.hpp"
#include "image_land_sea.hpp"
#include "lua_text.hpp"

#include <algorithm>
#include <cmath>
#include <sstream>
#include <vector>

using namespace image_basics;

namespace
{
// The largest fog picture: a guard against a size Lua got wrong (it asks for 2048 or the Territories' 4096).
constexpr int MAX_FOG_PX = 8192;

// The borders' look, compose_fog's `regions` argument read by field (image_tools.hpp lists them in this order).
struct BorderSpec
{
    std::string labels_file;                  // the area label PNG
    bool locked[AREA_LABELS] = {};            // the areas hatched
    std::string hatch_file;                   // the hatch's tile PNG ("" for a plain diagonal hatch in the ink)
    float ink[4] = {CHART_INK[0], CHART_INK[1], CHART_INK[2], 0.8f};   // 0..1; Lua may give r,g,b without alpha
    float width_px = 0, dash_px = 0, gap_px = 0;
    float hatch_opacity = 0;                  // 0..1
    std::string land_colour_file;             // the map, to keep the borders on land ("" or absent: everywhere)
    double land_gamma = 1.0;
};
constexpr size_t BORDER_FIELDS = 8, BORDER_FIELDS_WITH_LAND = 10;

// The plain hatch: diagonal lines this far apart and this wide, in pixels of the fog picture.
constexpr float PLAIN_HATCH_SPACING_PX = 14.f, PLAIN_HATCH_LINE_PX = 1.6f;
// The softened land at or above this counts as land for a border.
constexpr float BORDER_ON_LAND = 0.5f;
// The borders are softened by this blur so they show no stair steps when the map is zoomed in; COVER_GAIN keeps the
// softened line's middle at full ink.
constexpr int BORDER_SOFTEN_PX = 1;
constexpr float COVER_GAIN = 1.5f;
// dist_along's marks for a pixel: not on a border, or on one but not reached yet by the walk.
constexpr int NOT_BORDER = -1, NOT_WALKED = -2;

// The `regions` text split at '|', a trailing '|' keeping its empty last field.
auto border_fields(const std::string& regions) -> std::vector<std::string>
{
    std::vector<std::string> fields;
    std::stringstream parts(regions);
    for (std::string field; std::getline(parts, field, '|');)
    {
        fields.push_back(field);
    }
    if (!regions.empty() && regions.back() == '|')
    {
        fields.push_back("");
    }
    return fields;
}

// Reads `regions` into spec; "" or what was wrong with it.
auto read_border_spec(const std::string& regions, BorderSpec& spec) -> std::string
{
    const std::vector<std::string> f = border_fields(regions);
    if (f.size() != BORDER_FIELDS && f.size() != BORDER_FIELDS_WITH_LAND)
    {
        return "regions '" + regions + "': want 8 or 10 fields";
    }
    spec.labels_file = f[0];
    const std::string badLocked = read_locked_areas(f[1], spec.locked);
    if (!badLocked.empty()) return "regions: " + badLocked;
    spec.hatch_file = f[2];
    std::vector<float> ink;
    if (!lua_text::parse_floats(f[3], ',', ink) || ink.size() > 4)
    {
        return "regions '" + regions + "': ink '" + f[3] + "' (want r,g,b or r,g,b,a, 0-255)";
    }
    for (size_t c = 0; c < ink.size(); ++c)
    {
        spec.ink[c] = ink[c] / 255.f;
    }
    using lua_text::read_float;
    if (!(read_float(f[4], spec.width_px) && read_float(f[5], spec.dash_px) && read_float(f[6], spec.gap_px) &&
          read_float(f[7], spec.hatch_opacity)))
    {
        return "regions '" + regions + "': a number would not read";
    }
    if (f.size() == BORDER_FIELDS_WITH_LAND)
    {
        spec.land_colour_file = f[8];
        if (!spec.land_colour_file.empty() && !lua_text::read_double(f[9], spec.land_gamma))
        {
            return "regions: gamma '" + f[9] + "'";
        }
    }
    return "";
}

// How much of pixel i is land (0..1): `land` from land_mask, or everywhere when it is empty.
auto on_land(const Plane& land, size_t i) -> float
{
    return land.empty() ? 1.f : land[i];
}

// Lays colour c over the art's pixel i at alpha a (the art is opaque).
void ink_pixel(Rgba& art, size_t i, const float* c, float a)
{
    float* d = &art.px[i * 4];
    for (int k = 0; k < 3; ++k)
    {
        d[k] = d[k] * (1 - a) + c[k] * a;
    }
}

// The hatch over the locked areas' land: the hatch tile repeated, or plain diagonal lines in the ink.
void draw_hatch(Rgba& art, const std::vector<unsigned char>& labels, const Plane& land, const BorderSpec& spec,
                const StbPixels& tile, int tw, int th)
{
    const int size = art.s;
    for (int y = 0; y < size; ++y)
    {
        for (int x = 0; x < size; ++x)
        {
            const size_t i = static_cast<size_t>(y) * size + x;
            if (!labels[i] || !spec.locked[labels[i]]) continue;
            const float l = on_land(land, i);
            if (l <= 0.f) continue;
            if (tile)
            {
                const unsigned char* t = tile.get() + (static_cast<size_t>(y % th) * tw + (x % tw)) * 4;
                const float c[3] = {t[0] / 255.f, t[1] / 255.f, t[2] / 255.f};
                ink_pixel(art, i, c, t[3] / 255.f * spec.hatch_opacity * l);
            }
            else if (std::fmod(static_cast<float>(x + y), PLAIN_HATCH_SPACING_PX) < PLAIN_HATCH_LINE_PX)
            {
                ink_pixel(art, i, spec.ink, spec.hatch_opacity * l);
            }
        }
    }
}

// The border pixels: an area pixel on land whose right or lower neighbour is another area, also on land. Label 0
// (no area) has no border: its edge is the coast, which the chart already inks.
auto border_pixels(const std::vector<unsigned char>& labels, const Plane& land, int size) -> std::vector<size_t>
{
    std::vector<size_t> border;
    auto other = [&](size_t i, size_t j) {
        return labels[j] && labels[j] != labels[i] && on_land(land, j) >= BORDER_ON_LAND;
    };
    for (int y = 0; y + 1 < size; ++y)
    {
        for (int x = 0; x + 1 < size; ++x)
        {
            const size_t i = static_cast<size_t>(y) * size + x;
            const bool here = labels[i] && on_land(land, i) >= BORDER_ON_LAND;
            if (here && (other(i, i + 1) || other(i, i + size)))
            {
                border.push_back(i);
            }
        }
    }
    return border;
}

// Walks the border pixels joined to `start` (8-connected, breadth first), numbering each by its distance from start.
// `queue` is scratch space, kept by the caller so each walk need not allocate.
void walk_border(size_t start, std::vector<int>& dist, int size, std::vector<size_t>& queue)
{
    dist[start] = 0;
    queue.assign(1, start);
    for (size_t q = 0; q < queue.size(); ++q)
    {
        const size_t i = queue[q];
        const int x = static_cast<int>(i % size), y = static_cast<int>(i / size);
        for (int dy = -1; dy <= 1; ++dy)
        {
            for (int dx = -1; dx <= 1; ++dx)
            {
                const int nx = x + dx, ny = y + dy;
                if ((!dx && !dy) || nx < 0 || ny < 0 || nx >= size || ny >= size) continue;
                const size_t j = static_cast<size_t>(ny) * size + nx;
                if (dist[j] != NOT_WALKED) continue;
                dist[j] = dist[i] + 1;
                queue.push_back(j);
            }
        }
    }
}

// Each border pixel's distance along its border from where a walk over it began, for the dashes: measured along the
// border, they stay even round curves. NOT_BORDER elsewhere.
auto dist_along(const std::vector<size_t>& border, int size) -> std::vector<int>
{
    std::vector<int> dist(static_cast<size_t>(size) * size, NOT_BORDER);
    for (size_t i : border)
    {
        dist[i] = NOT_WALKED;
    }
    std::vector<size_t> queue;
    for (size_t start : border)
    {
        if (dist[start] == NOT_WALKED)
        {
            walk_border(start, dist, size, queue);
        }
    }
    return dist;
}

// Inks the borders: each border pixel in a dash (or every one, for a solid line) as a small disc of the line's
// width, softened, then laid over the art in the ink.
void ink_borders(Rgba& art, const std::vector<size_t>& border, const std::vector<int>& dist, const BorderSpec& spec)
{
    const int size = art.s;
    const float period = spec.dash_px + spec.gap_px;
    const int r = std::max(0, static_cast<int>(std::lround(spec.width_px / 2.f - 0.5f)));
    Plane cover(static_cast<size_t>(size) * size, 0.f);
    for (size_t i : border)
    {
        const bool dashed = spec.dash_px > 0.f && period > 0.f;
        if (dashed && std::fmod(static_cast<float>(dist[i]), period) >= spec.dash_px) continue;   // in a gap
        const int x = static_cast<int>(i % size), y = static_cast<int>(i / size);
        for (int dy = -r; dy <= r; ++dy)
        {
            for (int dx = -r; dx <= r; ++dx)
            {
                const int nx = x + dx, ny = y + dy;
                const bool inDisc = dx * dx + dy * dy <= r * r + r;   // (+ r: rounder at small radii)
                if (nx < 0 || ny < 0 || nx >= size || ny >= size || !inDisc) continue;
                cover[static_cast<size_t>(ny) * size + nx] = 1.f;
            }
        }
    }
    blur(cover, size, size, BORDER_SOFTEN_PX);
    for (size_t i = 0; i < cover.size(); ++i)
    {
        if (cover[i] > 0.f)
        {
            ink_pixel(art, i, spec.ink, spec.ink[3] * std::min(1.f, cover[i] * COVER_GAIN));
        }
    }
}

// The regions on the chart (compose_fog's `regions`): a hatch over locked areas, then the borders between areas.
auto draw_regions(Rgba& art, const std::string& regions) -> std::string
{
    if (regions.empty()) return "";
    BorderSpec spec;
    const std::string bad = read_border_spec(regions, spec);
    if (!bad.empty()) return bad;
    int lw = 0, lh = 0, tw = 0, th = 0;
    const StbPixels lab = read_png(spec.labels_file, 1, lw, lh);
    if (!lab) return read_failure(spec.labels_file);
    StbPixels tile = no_pixels();
    if (!spec.hatch_file.empty())
    {
        tile = read_png(spec.hatch_file, 4, tw, th);
        if (!tile) return read_failure(spec.hatch_file);
    }
    Plane land;
    if (!spec.land_colour_file.empty())
    {
        std::string err;
        land = land_mask(spec.land_colour_file, art.s, spec.land_gamma, err);
        if (!err.empty()) return err;
    }
    const std::vector<unsigned char> labels = labels_at_size(lab.get(), lw, lh, art.s);
    draw_hatch(art, labels, land, spec, tile, tw, th);
    const std::vector<size_t> border = border_pixels(labels, land, art.s);
    ink_borders(art, border, dist_along(border, art.s), spec);
    return "";
}

// The explored mask, softened as the game softens its fog's edge.
constexpr int FOG_EDGE_SOFTEN_DIVISOR = 400, FOG_EDGE_SOFTEN_MIN_PX = 1;   // (10 px at 4096)
// Along the fog's edge an ink wash: full where the explored mask goes from 0 to 1 within 1/WASH_FULL_ACROSS of the
// picture's width; there it inks the chart WASH_INK and keeps the fog at least WASH_ALPHA.
constexpr float WASH_FULL_ACROSS = 50.f;
constexpr float WASH_INK = 0.35f, WASH_ALPHA = 0.5f;
// A stamp is never drawn smaller than this, so it still shows on a small picture.
constexpr int MIN_STAMP_PX = 4;

// compose_fog's `spec` ("r+": the channel and which way round) read into channel 0..3 and explored_high; "" or why
// not.
auto read_mask_spec(const std::string& spec, int& channel, bool& explored_high) -> std::string
{
    const std::string channels = "rgba";
    if (spec.size() != 2 || channels.find(spec[0]) == std::string::npos || (spec[1] != '+' && spec[1] != '-'))
    {
        return "mask spec '" + spec + "' (want a channel r/g/b/a and + or -)";
    }
    channel = static_cast<int>(channels.find(spec[0]));
    explored_high = spec[1] == '+';
    return "";
}

// Where the player has explored (0..1, softened): the game's mask, and the always-uncovered one if given.
auto explored_mask(const std::string& mask, const std::string& default_mask, int size, int channel, bool high,
                   std::string& err) -> Plane
{
    Plane explored = load_channel(mask, size, channel, err);
    if (!err.empty()) return {};
    if (!high)
    {
        for (auto& e : explored)
        {
            e = 1.f - e;
        }
    }
    if (!default_mask.empty())
    {
        const Plane d = load_channel(default_mask, size, channel, err);
        if (!err.empty()) return {};
        for (size_t i = 0; i < explored.size(); ++i)
        {
            explored[i] = std::max(explored[i], high ? d[i] : 1.f - d[i]);
        }
    }
    blur(explored, size, size, std::max(FOG_EDGE_SOFTEN_MIN_PX, size / FOG_EDGE_SOFTEN_DIVISOR));
    return explored;
}

// The fog over the art (`art_at(i, c)` 0..1): opaque where unexplored, see-through where explored, with the wash.
template <typename ArtAt>
auto fog_over(const Plane& explored, int size, ArtAt art_at) -> std::vector<unsigned char>
{
    std::vector<unsigned char> img(static_cast<size_t>(size) * size * 4);
    auto e = [&](int x, int y) {
        return explored[static_cast<size_t>(std::clamp(y, 0, size - 1)) * size + std::clamp(x, 0, size - 1)];
    };
    for (int y = 0; y < size; ++y)
    {
        for (int x = 0; x < size; ++x)
        {
            const size_t i = static_cast<size_t>(y) * size + x;
            const float gx = (e(x + 1, y) - e(x - 1, y)) * 0.5f, gy = (e(x, y + 1) - e(x, y - 1)) * 0.5f;
            const float wash = std::min(1.f, std::sqrt(gx * gx + gy * gy) * size / WASH_FULL_ACROSS);
            const float alpha = std::min(1.f, std::max(1.f - explored[i], WASH_ALPHA * wash));
            for (int c = 0; c < 3; ++c)
            {
                img[i * 4 + c] = to_byte(art_at(i, c) * (1 - WASH_INK * wash) + CHART_INK[c] * WASH_INK * wash);
            }
            img[i * 4 + 3] = static_cast<unsigned char>(std::lround(255.f * alpha));
        }
    }
    return img;
}

// One stamp (`stamp` at sp x sp, its middle at pixel x0 + sp/2, y0 + sp/2) over the fog only, as much as the fog
// covers the map there: on explored land the map's own picture has the stamps.
void stamp_over_fog(std::vector<unsigned char>& img, int size, const Rgba& stamp, int x0, int y0)
{
    for (int y = 0; y < stamp.s; ++y)
    {
        for (int x = 0; x < stamp.s; ++x)
        {
            const int px = x0 + x, py = y0 + y;
            if (px < 0 || py < 0 || px >= size || py >= size) continue;
            unsigned char* d = &img[(static_cast<size_t>(py) * size + px) * 4];
            const float fog = d[3] / 255.f;
            const float* q = stamp.at(x, y);
            const float a = q[3] * fog;
            for (int c = 0; c < 3; ++c)
            {
                d[c] = static_cast<unsigned char>(std::lround(d[c] * (1 - a) + 255.f * q[c] * a));
            }
        }
    }
}

// compose_fog's `stamps` ("path|u|v|px;...") drawn over the fog; "" or what went wrong.
auto draw_stamps(std::vector<unsigned char>& img, int size, const std::string& stamps) -> std::string
{
    std::stringstream list(stamps);
    for (std::string item; std::getline(list, item, ';');)
    {
        if (item.empty()) continue;
        std::stringstream parts(item);
        std::string path, su, sv, spx;
        std::getline(parts, path, '|');
        std::getline(parts, su, '|');
        std::getline(parts, sv, '|');
        std::getline(parts, spx, '|');
        double u = 0, v = 0, px = 0;
        using lua_text::read_double;
        if (!(read_double(su, u) && read_double(sv, v) && read_double(spx, px))) return "stamp '" + item + "'";
        const int sp = std::max(MIN_STAMP_PX, static_cast<int>(std::lround(px * size / double(REFERENCE_MAP_PX))));
        std::string err;
        const Rgba stamp = load_rgba(path, sp, err);
        if (!err.empty()) return err;
        const int x0 = static_cast<int>(std::lround(u * size - sp / 2.0));
        const int y0 = static_cast<int>(std::lround(v * size - sp / 2.0));
        stamp_over_fog(img, size, stamp, x0, y0);
    }
    return "";
}
} // namespace

auto compose_fog(const std::string& chart, const std::string& mask, const std::string& default_mask,
                 const std::string& spec, const std::string& out, int size, const std::string& stamps,
                 const std::string& regions) -> std::string
{
    if (size < MIN_PICTURE_PX || size > MAX_FOG_PX) return "fog size " + std::to_string(size);
    int channel = 0;
    bool high = true;
    std::string err = read_mask_spec(spec, channel, high);
    if (!err.empty()) return err;
    // The picture: as 8 bits when it is already this size and nothing is drawn on it (the Territories' fog art at
    // 4096: floats would take 256 MB more), else as floats.
    Rgba art;
    StbPixels raw = no_pixels();
    if (regions.empty())
    {
        int w = 0, h = 0;
        raw = read_png(chart, 4, w, h);
        if (!raw) return read_failure(chart);
        if (w != size || h != size)
        {
            raw.reset();
        }
    }
    if (!raw)
    {
        art = load_rgba(chart, size, err);
        if (!err.empty()) return err;
        err = draw_regions(art, regions);
        if (!err.empty()) return err;
    }
    const Plane explored = explored_mask(mask, default_mask, size, channel, high, err);
    if (!err.empty()) return err;
    auto artAt = [&](size_t i, int c) { return raw ? raw.get()[i * 4 + c] / 255.f : art.px[i * 4 + c]; };
    std::vector<unsigned char> img = fog_over(explored, size, artAt);
    err = draw_stamps(img, size, stamps);
    if (!err.empty()) return err;
    return write_png_fast(out, size, size, 4, img.data()) ? "" : "could not write " + out;
}
