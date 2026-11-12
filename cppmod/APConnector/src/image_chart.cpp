// The explorer's-chart picture of the map (compose_chart in image_tools.hpp): paper, land and sea told apart and
// inked like a hand-drawn chart. Every look below was tuned by eye; each number is named in the block it belongs to.
#include "image_tools.hpp"
#include "image_basics.hpp"
#include "image_land_sea.hpp"

#include <algorithm>
#include <cmath>
#include <vector>

using namespace image_basics;

namespace
{
// The largest chart: a guard against a size Lua got wrong (it asks for 2048). The chart's float planes take about
// 1 GB at 4096 and 4 GB at 8192.
constexpr int MAX_CHART_PX = 8192;

// A blur radius for a chart of `size` px: the size divided by `divisor` (pixels at a 4096 chart in the comments
// below), never below `min_px`.
auto radius(int size, int divisor, int min_px) -> int
{
    return std::max(min_px, size / divisor);
}

// The lines: each where a softened plane crosses a level, about this many pixels wide.
constexpr float COAST_LEVEL = 0.5f, COAST_WIDTH_PX = 1.2f;            // land_soft
constexpr float FRAME_LEVEL = 0.5f, FRAME_WIDTH_PX = 1.4f;            // the world's edge, softened
constexpr float OUTER_FRAME_LEVEL = 0.06f, OUTER_FRAME_WIDTH_PX = 0.8f;
constexpr int OUTER_FRAME_DIVISOR = 120, OUTER_FRAME_MIN_PX = 3;      // (34) the outer rule's blur
constexpr float OUTER_FRAME_INK = 0.6f;                               // a thinner, lighter second rule
// Coastal ripple rings: over the sea, where the land blurred wide crosses these levels.
constexpr int RIPPLE_DIVISOR = 160, RIPPLE_MIN_PX = 2;                // (25)
constexpr float RIPPLE_LEVELS[] = {0.30f, 0.12f, 0.04f};
constexpr float RIPPLE_WIDTH = 0.012f;                                // in the blurred land's 0..1
constexpr float RIPPLE_INK = 0.45f;
// Land: contour lines between bands of brightness, and relief where it is darker than its surroundings.
constexpr int BANDS_DIVISOR = 400, BANDS_MIN_PX = 1;                  // (10) smooths the bands' edges
constexpr float BRIGHTNESS_BANDS = 7.f;
constexpr float CONTOUR_INK = 0.35f;
constexpr int RELIEF_DIVISOR = 250, RELIEF_MIN_PX = 2;                // (16) the surroundings
constexpr float RELIEF_GAIN = 2.5f, RELIEF_INK = 0.22f;
// Beyond the frame: cross-hatching, two diagonals this many pixels apart.
constexpr float HATCH_BEYOND = 0.5f;                                  // outside_soft above this
constexpr int HATCH_SPACING_PX = 9;
constexpr float HATCH_INK = 0.22f;
// The sea marks tile, on open sea only: not near the edge, nor within this blur of the land.
constexpr int NEAR_LAND_DIVISOR = 100, NEAR_LAND_MIN_PX = 2;          // (40)
constexpr float NEAR_LAND_ABOVE = 0.02f;
constexpr float SEA_MARK_INK = 0.9f;
// How much of the paper full ink covers.
constexpr float INK_COVER = 0.85f;

// The paper: its tile two across the chart, or plain cream, mottled, with a fine fibre.
constexpr int PAPER_TILES_ACROSS = 2;
constexpr float PAPER_CREAM[3] = {0.918f, 0.859f, 0.706f};
constexpr unsigned MOTTLE_SEED = 7, FIBRE_SEED = 11;                  // any fixed numbers: the same chart each time
constexpr int MOTTLE_DIVISOR = 60, MOTTLE_MIN_PX = 1;                 // (68) blotches this size
constexpr int FIBRE_BLUR_PX = 1;
constexpr float MOTTLE_DEPTH = 0.025f, FIBRE_DEPTH = 0.012f;
// Darker toward the corners: from VIGNETTE_START (from the middle, in chart widths) over VIGNETTE_RAMP, to
// VIGNETTE_DARKEST less light.
constexpr float VIGNETTE_START = 0.35f, VIGNETTE_RAMP = 0.35f, VIGNETTE_DARKEST = 0.18f;
// The paper's tint over land, sea and beyond the edge.
constexpr float LAND_TINT[3] = {1.03f, 1.02f, 0.98f};
constexpr float SEA_TINT[3] = {0.90f, 0.95f, 1.00f};
constexpr float BEYOND_TINT[3] = {0.80f, 0.76f, 0.70f};
// The sea marks tile's size (never below SEA_TILE_MIN_PX), and the compass's size and its top-left corner, in the
// hatched corner beyond the frame's top-left; all as fractions of the chart's width.
constexpr int SEA_TILE_DIVISOR = 4, SEA_TILE_MIN_PX = 128;
constexpr int COMPASS_DIVISOR = 5;
constexpr float COMPASS_LEFT = 0.07f, COMPASS_TOP = 0.08f;

// A line about `width` pixels wide where a soft mask crosses `level` (from its gradient), 0..1.
auto contour_line(const Plane& m, int s, float level, float width) -> Plane
{
    constexpr float FULL_WITHIN = 1.5f;     // line widths from the crossing at which the line is still full
    constexpr float FLAT = 1e-6f;           // keeps a flat mask (no gradient) from dividing by zero
    Plane out(m.size(), 0.f);
    auto v = [&](int x, int y) {
        return m[static_cast<size_t>(std::clamp(y, 0, s - 1)) * s + std::clamp(x, 0, s - 1)];
    };
    for (int y = 0; y < s; ++y)
    {
        for (int x = 0; x < s; ++x)
        {
            const float gx = (v(x + 1, y) - v(x - 1, y)) * 0.5f, gy = (v(x, y + 1) - v(x, y - 1)) * 0.5f;
            const float g = std::sqrt(gx * gx + gy * gy) + FLAT;
            const float line = FULL_WITHIN - std::fabs(v(x, y) - level) / (g * width);
            out[static_cast<size_t>(y) * s + x] = std::min(1.f, std::max(0.f, line));
        }
    }
    return out;
}

// Noise 0..1, the same for the same seed: a linear congruential generator with Knuth's MMIX constants, seeded
// through Knuth's multiplicative hash; the top 24 bits of each step make a float.
auto noise_plane(int s, unsigned seed) -> Plane
{
    constexpr unsigned long long HASH = 2654435761ULL, MULTIPLIER = 6364136223846793005ULL;
    constexpr unsigned long long INCREMENT = 1442695040888963407ULL;
    constexpr int SHIFT = 40;
    constexpr unsigned long long BITS_24 = 0xFFFFFF;
    constexpr float RANGE_24 = 16777216.f;
    Plane p(static_cast<size_t>(s) * s);
    unsigned long long state = seed * HASH + 1;
    for (auto& v : p)
    {
        state = state * MULTIPLIER + INCREMENT;
        v = static_cast<float>((state >> SHIFT) & BITS_24) / RANGE_24;
    }
    return p;
}

// Scales a plane to mean 0 and standard deviation 1.
void normalise(Plane& p)
{
    constexpr float FLAT = 1e-6f;           // keeps a flat plane from dividing by zero
    double mean = 0, sq = 0;
    for (float v : p) mean += v;
    mean /= p.size();
    for (float v : p) sq += (v - mean) * (v - mean);
    const float sd = static_cast<float>(std::sqrt(sq / p.size())) + FLAT;
    for (auto& v : p) v = static_cast<float>((v - mean) / sd);
}

// Everything the chart's ink is drawn from, each the chart's size.
struct ChartPlanes
{
    LandAndSea map;          // beyond the edge, land, and both softened (image_land_sea.hpp)
    Plane brightness;        // the map's
    Plane bands;             // brightness, blurred a little: its bands give the contour lines
    Plane surroundings;      // brightness, blurred more: relief where a pixel is darker than this
    Plane coast, frame, outer_frame;
    Plane ripples;           // land blurred wide: its levels give the ripple rings
    Plane near_land;         // land blurred: keeps the sea marks off the coast
};

// The chart's planes from the map (as load_rgba gives it; gamma as compose_map's).
auto chart_planes(const Rgba& map, double gamma) -> ChartPlanes
{
    const int size = map.s;
    ChartPlanes p;
    p.map = classify_map(map, gamma, &p.brightness);
    p.coast = contour_line(p.map.land_soft, size, COAST_LEVEL, COAST_WIDTH_PX);
    Plane outsideWide = p.map.outside;
    blur(outsideWide, size, size, radius(size, OUTER_FRAME_DIVISOR, OUTER_FRAME_MIN_PX));
    p.frame = contour_line(p.map.outside_soft, size, FRAME_LEVEL, FRAME_WIDTH_PX);
    p.outer_frame = contour_line(outsideWide, size, OUTER_FRAME_LEVEL, OUTER_FRAME_WIDTH_PX);
    p.ripples = p.map.land;
    blur(p.ripples, size, size, radius(size, RIPPLE_DIVISOR, RIPPLE_MIN_PX));
    p.bands = p.brightness;
    blur(p.bands, size, size, radius(size, BANDS_DIVISOR, BANDS_MIN_PX));
    p.surroundings = p.brightness;
    blur(p.surroundings, size, size, radius(size, RELIEF_DIVISOR, RELIEF_MIN_PX));
    p.near_land = p.map.land;
    blur(p.near_land, size, size, radius(size, NEAR_LAND_DIVISOR, NEAR_LAND_MIN_PX));
    return p;
}

// The chart's art from Lua (each "" for none) and, without a paper tile, the plain paper's mottle and fibre.
struct ChartArt
{
    Rgba paper, sea_marks, compass;
    Plane mottle, fibre;
};

// Loads the art at the sizes the chart uses; "" or what went wrong.
auto load_chart_art(const std::string& paper, const std::string& sea, const std::string& compass, int size,
                    ChartArt& art) -> std::string
{
    std::string err;
    if (!paper.empty()) art.paper = load_rgba(paper, size / PAPER_TILES_ACROSS, err);
    if (!err.empty()) return err;
    if (!sea.empty()) art.sea_marks = load_rgba(sea, std::max(SEA_TILE_MIN_PX, size / SEA_TILE_DIVISOR), err);
    if (!err.empty()) return err;
    if (!compass.empty()) art.compass = load_rgba(compass, size / COMPASS_DIVISOR, err);
    if (!err.empty()) return err;
    if (art.paper.s == 0)
    {
        art.mottle = noise_plane(size, MOTTLE_SEED);
        blur(art.mottle, size, size, radius(size, MOTTLE_DIVISOR, MOTTLE_MIN_PX));
        normalise(art.mottle);
        art.fibre = noise_plane(size, FIBRE_SEED);
        blur(art.fibre, size, size, FIBRE_BLUR_PX);
        normalise(art.fibre);
    }
    return "";
}

// The paper's colour at (x, y), before the tint and the ink.
void paper_at(const ChartArt& art, int size, int x, int y, float (&colour)[3])
{
    const size_t i = static_cast<size_t>(y) * size + x;
    const float fx = static_cast<float>(x) / size, fy = static_cast<float>(y) / size;
    const float corner = (std::hypot(fx - 0.5f, fy - 0.5f) - VIGNETTE_START) / VIGNETTE_RAMP;
    const float vig = 1.f - VIGNETTE_DARKEST * std::min(1.f, std::max(0.f, corner));
    if (art.paper.s)
    {
        const float* t = art.paper.at(x % art.paper.s, y % art.paper.s);
        for (int c = 0; c < 3; ++c) colour[c] = t[c] * vig;
        return;
    }
    const float k = (1.f + MOTTLE_DEPTH * art.mottle[i] + FIBRE_DEPTH * art.fibre[i]) * vig;
    for (int c = 0; c < 3; ++c) colour[c] = PAPER_CREAM[c] * k;
}

// How much ink (0..1) covers (x, y): the strongest of the coast, the frame, the ripples, the land's contours and
// relief, the hatching beyond the edge and the sea marks.
auto ink_at(const ChartPlanes& p, const ChartArt& art, int size, int x, int y) -> float
{
    const size_t i = static_cast<size_t>(y) * size + x;
    const bool land = p.map.land[i] != 0.f;
    const bool nearEdge = p.map.outside_soft[i] > NEAR_EDGE_ABOVE;
    float ink = 0;
    ink = std::max(ink, p.coast[i]);
    ink = std::max(ink, std::max(p.frame[i], OUTER_FRAME_INK * p.outer_frame[i]));
    if (!land && !nearEdge)
    {
        for (float level : RIPPLE_LEVELS)
        {
            const float ring = std::min(1.f, std::max(0.f, 1.f - std::fabs(p.ripples[i] - level) / RIPPLE_WIDTH));
            ink = std::max(ink, ring * RIPPLE_INK);
        }
    }
    if (land)
    {
        auto band = [&](int bx, int by) {
            return std::floor(p.bands[static_cast<size_t>(by) * size + bx] * BRIGHTNESS_BANDS);
        };
        const bool right = x + 1 < size && band(x, y) != band(x + 1, y);
        const bool below = y + 1 < size && band(x, y) != band(x, y + 1);
        if (right || below) ink = std::max(ink, CONTOUR_INK);
        const float relief = (p.brightness[i] - p.surroundings[i]) * -RELIEF_GAIN;
        ink = std::max(ink, std::min(1.f, std::max(0.f, relief)) * RELIEF_INK);
    }
    const bool downHatch = (x + y) % HATCH_SPACING_PX == 0;
    const bool upHatch = ((x - y) % HATCH_SPACING_PX + HATCH_SPACING_PX) % HATCH_SPACING_PX == 0;
    const bool onHatch = downHatch || upHatch;
    if (p.map.outside_soft[i] > HATCH_BEYOND && onHatch) ink = std::max(ink, HATCH_INK);
    if (art.sea_marks.s && !land && !nearEdge && p.near_land[i] < NEAR_LAND_ABOVE)
    {
        ink = std::max(ink, art.sea_marks.at(x % art.sea_marks.s, y % art.sea_marks.s)[3] * SEA_MARK_INK);
    }
    return ink;
}

// The compass laid over `colour` at (x, y), where it is.
void compass_at(const Rgba& compass, int size, int x, int y, float (&colour)[3])
{
    const int cx = x - static_cast<int>(size * COMPASS_LEFT), cy = y - static_cast<int>(size * COMPASS_TOP);
    if (cx < 0 || cy < 0 || cx >= compass.s || cy >= compass.s) return;
    const float* a = compass.at(cx, cy);
    for (int c = 0; c < 3; ++c) colour[c] = colour[c] * (1 - a[3]) + a[c] * a[3];
}
} // namespace

auto compose_chart(const std::string& colour, const std::string& paper, const std::string& sea,
                   const std::string& compass, const std::string& out, int size, double gamma) -> std::string
{
    if (size < MIN_PICTURE_PX || size > MAX_CHART_PX) return "chart size " + std::to_string(size);
    std::string err;
    const Rgba map = load_rgba(colour, size, err);
    if (!err.empty()) return err;
    const ChartPlanes planes = chart_planes(map, gamma);
    ChartArt art;
    err = load_chart_art(paper, sea, compass, size, art);
    if (!err.empty()) return err;
    std::vector<unsigned char> img(static_cast<size_t>(size) * size * 3);
    for (int y = 0; y < size; ++y)
    {
        for (int x = 0; x < size; ++x)
        {
            const size_t i = static_cast<size_t>(y) * size + x;
            float base[3];
            paper_at(art, size, x, y, base);
            const float* tint = planes.map.land[i] ? LAND_TINT : (planes.map.outside[i] ? BEYOND_TINT : SEA_TINT);
            const float ink = ink_at(planes, art, size, x, y);
            float col[3];
            for (int c = 0; c < 3; ++c)
            {
                col[c] = base[c] * tint[c] * (1 - ink * INK_COVER) + CHART_INK[c] * ink * INK_COVER;
            }
            if (art.compass.s) compass_at(art.compass, size, x, y, col);
            for (int c = 0; c < 3; ++c) img[i * 3 + c] = to_byte(col[c]);
        }
    }
    return write_png_fast(out, size, size, 3, img.data()) ? "" : "could not write " + out;
}
