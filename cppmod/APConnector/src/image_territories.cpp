// The Territories pictures: every lock tinted by its state, with a rim inside its edge, and the standing walls as a
// glow and a core. compose_territories draws them from the lock label map, compose_field from a distance field
// (smooth curves); image_tools.hpp defines the text each takes. The looks were tuned by eye; each number is named in
// the block it belongs to.
#include "image_tools.hpp"
#include "image_basics.hpp"
#include "lua_text.hpp"

#include <algorithm>
#include <cmath>
#include <sstream>
#include <vector>

using namespace image_basics;
using lua_text::parse_hex_rgb;
using lua_text::read_float;

namespace
{
// The largest Territories picture: Lua asks for 2048, or 4096 for the distance field; the float picture alone takes
// 256 MB at 4096.
constexpr int MAX_TERRITORIES_PX = 4096;

// How each lock state looks: the fill all over the lock and the rim along its edge (0..1), the rim in the duotone
// (which has no fills), and the lock's brightness in the duotone fog picture. `closed` locks are greyscale on the
// map picture.
struct StateLook
{
    char letter;            // as the `locks` text gives it
    bool closed;
    float fill;
    float rim;
    float duotone_rim;
    float duotone_brightness;
};
constexpr StateLook STATE_LOOKS[] = {
    {'v', false, 0.00f, 0.35f, 0.35f, 0.85f},   // visited
    {'u', false, 0.14f, 0.95f, 0.80f, 0.85f},   // unlocked, not visited yet
    {'l', true, 0.34f, 0.95f, 0.80f, 0.62f},    // locked
    {'s', true, 0.50f, 0.80f, 0.65f, 0.55f},    // sealed
};

// The look of the state with this letter, or null when there is none.
auto state_look(char letter) -> const StateLook*
{
    for (const StateLook& look : STATE_LOOKS)
    {
        if (look.letter == letter) return &look;
    }
    return nullptr;
}

// The Territories' look, shared by compose_territories and compose_field: each lock's state and colour, the walls'
// style and the fog colour, as image_tools.hpp's `locks`, `style` and `fog` give them. The defaults are the cream
// walls (style "" in image_tools.hpp).
struct TerritoryLook
{
    const StateLook* state[LOCK_LABELS] = {};    // by lock index; null: not listed, left clear
    float colour[LOCK_LABELS][3] = {};
    float glow_colour[3] = {1.f, 0.914f, 0.690f};
    float core_colour[3] = {1.f, 0.957f, 0.863f};
    float glow_alpha = 0.55f, core_alpha = 1.f;
    float glow_width = 10.f, glow_sigma = 3.f, core_width = 5.f;     // px of the reference map
    float map_glow_alpha = 0.3f, map_core_alpha = 0.5f;             // compose_field's map picture
    float fog_colour[3] = {0.055f, 0.102f, 0.141f};
};
constexpr size_t STYLE_FIELDS = 7, STYLE_FIELDS_WITH_MAP = 9;

// The `locks` text ("index:state:RRGGBB,...") into look; "" or the item that was wrong. The error texts keep their
// words ("areas"): see image_tools.hpp's opening comment.
auto read_locks(const std::string& locks, TerritoryLook& look) -> std::string
{
    for (const auto& item : lua_text::split_csv(locks))
    {
        const size_t a = item.find(':'), b = item.find(':', a + 1);
        if (a == std::string::npos || b == std::string::npos || b != a + 2) return "areas item '" + item + "'";
        const int index = lua_text::int_or(item.substr(0, a), -1);
        if (index < 0 || index >= LOCK_LABELS) return "areas index in '" + item + "'";
        const StateLook* state = state_look(item[a + 1]);
        if (!state) return "areas state in '" + item + "'";
        if (!parse_hex_rgb(item.substr(b + 1), look.colour[index])) return "areas colour in '" + item + "'";
        look.state[index] = state;
    }
    return "";
}

// The `style`, `fog` and `locks` texts into look; "" or what was wrong.
auto read_look(const std::string& locks, const std::string& style, const std::string& fog, TerritoryLook& look)
    -> std::string
{
    const std::string badLocks = read_locks(locks, look);
    if (!badLocks.empty()) return badLocks;
    if (!style.empty())
    {
        std::vector<std::string> f;
        std::stringstream parts(style);
        for (std::string part; std::getline(parts, part, ',');)
        {
            f.push_back(part);
        }
        bool read = (f.size() == STYLE_FIELDS || f.size() == STYLE_FIELDS_WITH_MAP) &&
                    parse_hex_rgb(f[0], look.glow_colour) && read_float(f[1], look.glow_alpha) &&
                    parse_hex_rgb(f[2], look.core_colour) && read_float(f[3], look.core_alpha) &&
                    read_float(f[4], look.glow_width) && read_float(f[5], look.glow_sigma) &&
                    read_float(f[6], look.core_width);
        if (read && f.size() == STYLE_FIELDS_WITH_MAP)
        {
            read = read_float(f[7], look.map_glow_alpha) && read_float(f[8], look.map_core_alpha);
        }
        if (!read) return "style '" + style + "'";
    }
    if (!fog.empty() && !parse_hex_rgb(fog, look.fog_colour)) return "fog colour '" + fog + "'";
    return "";
}

// A standing wall piece: its two ends, in pixels of the picture.
struct WallPiece
{
    float x1, y1, x2, y2;
};

// The `walls` text ("u1,v1,u2,v2;...", 0..1 of the map square) as pieces in pixels of a `size` picture; "" or the
// item that was wrong.
auto read_walls(const std::string& walls, int size, std::vector<WallPiece>& pieces) -> std::string
{
    const float scale = static_cast<float>(size);
    std::stringstream items(walls);
    for (std::string item; std::getline(items, item, ';');)
    {
        if (item.empty()) continue;
        std::vector<float> ends;
        if (!lua_text::parse_floats(item, ',', ends) || ends.size() != 4) return "walls item '" + item + "'";
        pieces.push_back({ends[0] * scale, ends[1] * scale, ends[2] * scale, ends[3] * scale});
    }
    return "";
}

// How strong a lock's rim is at d px (of the reference map) inside its edge: full for RIM_FULL_PX, then fading by a
// factor of e every RIM_FADE_PX.
constexpr float RIM_FULL_PX = 2.f;
constexpr float RIM_FADE_PX = 7.f;
auto rim_strength(float d) -> float
{
    return std::exp(-std::max(d - RIM_FULL_PX, 0.f) / RIM_FADE_PX);
}

// A value clamped to 0..1.
auto unit(float v) -> float
{
    return std::min(1.f, std::max(0.f, v));
}

// --- compose_territories: from the lock label map ---

// The distance from each lock pixel to its lock's edge, by a 3-4 chamfer. Edge pixels (a lock pixel with another
// label, sea included, among its 8 neighbours) start at 0, the rest at FAR. A pass from the top-left gives each
// pixel the least of its left and three upper neighbours plus a step; a pass back from the bottom-right does the same
// with the other four. A step to a side neighbour costs STRAIGHT_STEP, to a corner one DIAGONAL_STEP: about 3 times 1
// and 3 times the square root of 2 (4.24), so a distance divided by STRAIGHT_STEP is in pixels, up to 6% short on a
// diagonal. Example: 2 pixels right and 2 down from the nearest edge pixel is 4 + 4 = 8, 8 / 3 = 2.7 px (truly 2.8).
// The rim's width is set in those pixels by rim_strength.
constexpr int STRAIGHT_STEP = 3, DIAGONAL_STEP = 4;
constexpr int FAR = 1 << 28;   // further than any picture is wide, with room to add a step

// Each lock pixel 0 on its lock's edge, FAR elsewhere.
auto lock_edges(const std::vector<unsigned char>& labels, int size) -> std::vector<int>
{
    std::vector<int> dist(labels.size(), FAR);
    for (int y = 0; y < size; ++y)
    {
        for (int x = 0; x < size; ++x)
        {
            const size_t i = static_cast<size_t>(y) * size + x;
            if (!labels[i]) continue;
            bool edge = false;
            for (int dy = -1; dy <= 1 && !edge; ++dy)
            {
                for (int dx = -1; dx <= 1 && !edge; ++dx)
                {
                    const int nx = x + dx, ny = y + dy;
                    if (nx < 0 || ny < 0 || nx >= size || ny >= size) continue;
                    if (labels[static_cast<size_t>(ny) * size + nx] != labels[i])
                    {
                        edge = true;
                    }
                }
            }
            if (edge)
            {
                dist[i] = 0;
            }
        }
    }
    return dist;
}

// The chamfer's pass from the top-left over lock_edges' start: each pixel's least of its left and three upper
// neighbours plus a step (see STRAIGHT_STEP).
void chamfer_forward(std::vector<int>& dist, int size)
{
    auto at = [&](int x, int y) -> int& { return dist[static_cast<size_t>(y) * size + x]; };
    for (int y = 0; y < size; ++y)
    {
        for (int x = 0; x < size; ++x)
        {
            int& d = at(x, y);
            if (x > 0)
            {
                d = std::min(d, at(x - 1, y) + STRAIGHT_STEP);
            }
            if (y == 0) continue;
            d = std::min(d, at(x, y - 1) + STRAIGHT_STEP);
            if (x > 0)
            {
                d = std::min(d, at(x - 1, y - 1) + DIAGONAL_STEP);
            }
            if (x + 1 < size)
            {
                d = std::min(d, at(x + 1, y - 1) + DIAGONAL_STEP);
            }
        }
    }
}

// The chamfer's pass back from the bottom-right: the same with the other four neighbours.
void chamfer_back(std::vector<int>& dist, int size)
{
    auto at = [&](int x, int y) -> int& { return dist[static_cast<size_t>(y) * size + x]; };
    for (int y = size - 1; y >= 0; --y)
    {
        for (int x = size - 1; x >= 0; --x)
        {
            int& d = at(x, y);
            if (x + 1 < size)
            {
                d = std::min(d, at(x + 1, y) + STRAIGHT_STEP);
            }
            if (y + 1 == size) continue;
            d = std::min(d, at(x, y + 1) + STRAIGHT_STEP);
            if (x + 1 < size)
            {
                d = std::min(d, at(x + 1, y + 1) + DIAGONAL_STEP);
            }
            if (x > 0)
            {
                d = std::min(d, at(x - 1, y + 1) + DIAGONAL_STEP);
            }
        }
    }
}

// The overlay being drawn: RGBA floats, straight alpha.
using Overlay = std::vector<float>;

// Lays colour c at alpha a over the overlay's pixel i.
void overlay_over(Overlay& img, size_t i, const float* c, float a)
{
    blend_over(&img[i * 4], img[i * 4 + 3], c, a);
}

// Each listed lock's fill, and its rim by its distance to the edge (`dist` from the chamfer; `scale`: this picture's
// pixels per pixel of the reference map).
void fill_and_rim(Overlay& img, const std::vector<unsigned char>& labels, const std::vector<int>& dist,
                  const TerritoryLook& look, float scale)
{
    for (size_t i = 0; i < labels.size(); ++i)
    {
        const unsigned char lockIndex = labels[i];
        if (!lockIndex || !look.state[lockIndex]) continue;
        const StateLook& state = *look.state[lockIndex];
        const float d = dist[i] / static_cast<float>(STRAIGHT_STEP) / scale;     // in px of the reference map
        overlay_over(img, i, look.colour[lockIndex], unit(state.fill + rim_strength(d) * state.rim));
    }
}

// A wall piece's coverage drawn into cov: hard (1 within half_width of the piece) or anti-aliased (fading over the
// last pixel).
void draw_piece(Plane& cov, int size, const WallPiece& piece, float half_width, bool anti_aliased)
{
    constexpr float MARGIN_PX = 2.f;     // the box looked at reaches this far past the line's edge
    const float x1 = piece.x1, y1 = piece.y1, x2 = piece.x2, y2 = piece.y2;
    const int x0 = std::max(0, static_cast<int>(std::floor(std::min(x1, x2) - half_width - MARGIN_PX)));
    const int xe = std::min(size - 1, static_cast<int>(std::ceil(std::max(x1, x2) + half_width + MARGIN_PX)));
    const int y0 = std::max(0, static_cast<int>(std::floor(std::min(y1, y2) - half_width - MARGIN_PX)));
    const int ye = std::min(size - 1, static_cast<int>(std::ceil(std::max(y1, y2) + half_width + MARGIN_PX)));
    const float dx = x2 - x1, dy = y2 - y1, len2 = dx * dx + dy * dy;
    for (int y = y0; y <= ye; ++y)
    {
        for (int x = x0; x <= xe; ++x)
        {
            const float px = x + 0.5f, py = y + 0.5f;
            const float t = unit(len2 > 0 ? ((px - x1) * dx + (py - y1) * dy) / len2 : 0.f);
            const float qx = x1 + t * dx - px, qy = y1 + t * dy - py;
            const float d = std::sqrt(qx * qx + qy * qy);
            const float c = anti_aliased ? unit(half_width + 0.5f - d) : (d <= half_width ? 1.f : 0.f);
            float& v = cov[static_cast<size_t>(y) * size + x];
            v = std::max(v, c);
        }
    }
}

// The radius of the box blur whose GAUSSIAN_BOX_PASSES passes spread like a Gaussian of this standard deviation:
// three passes of radius r spread with a standard deviation of sqrt(r * (r + 1)).
auto box_radius_for(float sigma) -> int
{
    return std::max(1, static_cast<int>(std::lround(std::sqrt(sigma * sigma + 0.25f) - 0.5f)));
}

// The walls over the overlay: a soft glow, then an anti-aliased core.
void draw_walls(Overlay& img, const std::vector<WallPiece>& pieces, const TerritoryLook& look, int size, float scale)
{
    if (pieces.empty()) return;
    const size_t count = static_cast<size_t>(size) * size;
    Plane glow(count, 0.f), core(count, 0.f);
    for (const WallPiece& piece : pieces)
    {
        draw_piece(glow, size, piece, look.glow_width * scale / 2.f, false);
        draw_piece(core, size, piece, look.core_width * scale / 2.f, true);
    }
    blur(glow, size, size, box_radius_for(look.glow_sigma * scale));
    for (size_t i = 0; i < count; ++i)
    {
        overlay_over(img, i, look.glow_colour, look.glow_alpha * std::min(1.f, glow[i]));
        overlay_over(img, i, look.core_colour, look.core_alpha * core[i]);
    }
}

// Writes the overlay (RGBA) to `out` and, if `fogart` is not "", the same over the opaque fog colour (RGB).
auto write_overlay(const Overlay& img, int size, const TerritoryLook& look, const std::string& out,
                   const std::string& fogart) -> std::string
{
    const size_t count = static_cast<size_t>(size) * size;
    std::vector<unsigned char> overlay(count * 4);
    for (size_t i = 0; i < count * 4; ++i)
    {
        overlay[i] = to_byte(img[i]);
    }
    if (!write_png_fast(out, size, size, 4, overlay.data())) return "could not write " + out;
    if (fogart.empty()) return "";
    std::vector<unsigned char> fogPicture(count * 3);
    for (size_t i = 0; i < count; ++i)
    {
        const float a = img[i * 4 + 3];
        for (int c = 0; c < 3; ++c)
        {
            fogPicture[i * 3 + c] = to_byte(img[i * 4 + c] * a + look.fog_colour[c] * (1 - a));
        }
    }
    return write_png_fast(fogart, size, size, 3, fogPicture.data()) ? "" : "could not write " + fogart;
}

// --- compose_field: from the distance field ---

// The field's blue channel is the distance to the nearest border in 1/FIELD_DISTANCE_STEPS px of the field.
constexpr float FIELD_DISTANCE_STEPS = 8.f;
// The glow across a border is a Gaussian with this standard deviation per px of glow_width (4 px at the default 10).
constexpr float GLOW_SD_PER_WIDTH = 0.4f;
// Pixels this far from a piece (px of the reference map) are touched by its walls: REACH_GLOW_SDS glow deviations
// and REACH_EXTRA_PX more.
constexpr float REACH_GLOW_SDS = 3.f, REACH_EXTRA_PX = 10.f;
// A piece whose field distance, averaged at ALONG_SAMPLES points along it, is over FREE_PIECE_PX stands away from
// every border (a few stand out at sea, as the box round an island): it is drawn where it stands.
constexpr int ALONG_SAMPLES = 5;
constexpr float FREE_PIECE_PX = 6.f;
// Along a border the walls show at full strength up to WALL_FADE_PX past the nearest piece's end, then fade out
// over WALL_FADE_PX more.
constexpr float WALL_FADE_PX = 4.f;
// No piece near (px).
constexpr float NO_PIECE = 1e9f;
// On the map picture the walls take the closed side's colour; the core keeps MAP_CORE_KEEP of it and adds
// MAP_CORE_LIFT of white.
constexpr float MAP_CORE_KEEP = 0.6f, MAP_CORE_LIFT = 0.4f;
// The duotone fog picture: the map's brightness from these weights (less green than Rec. 709's luminance; tuned by
// eye for the duotone, not meant to match it), the open sea DUOTONE_SEA_MAP of it over the fog colour, and a lock's
// colour from dark to light as the brightness goes from DUOTONE_DARKEST over DUOTONE_RANGE, on a curve of
// DUOTONE_CURVE.
constexpr float DUOTONE_LUMA_RED = 0.30f, DUOTONE_LUMA_GREEN = 0.55f, DUOTONE_LUMA_BLUE = 0.15f;
constexpr float DUOTONE_SEA_MAP = 0.42f, DUOTONE_SEA_FOG = 0.58f;
constexpr float DUOTONE_DARKEST = 0.12f, DUOTONE_RANGE = 0.60f, DUOTONE_CURVE = 0.9f;
// The dark end: mostly the fog colour with a little of the lock's; the light end: the lock's colour lightened.
constexpr float DUOTONE_DARK_FOG = 0.70f, DUOTONE_DARK_LOCK = 0.22f;
constexpr float DUOTONE_LIGHT_LOCK = 0.80f, DUOTONE_LIGHT_LIFT = 0.20f;

// The distance field, read: R the pixel's own lock, G the lock across the nearest border (for the open sea: the
// nearest lock), B that distance.
struct Field
{
    StbPixels px = no_pixels();
    int w = 0, h = 0;
    float to_reference = 1.f;                 // field px to px of the reference map
    // The field's distance (px of the reference map) nearest to (x, y) in px of a `size` picture.
    auto distance_at(float x, float y, int size) const -> float
    {
        const int fx = std::min(w - 1, std::max(0, static_cast<int>(x / size * w)));
        const int fy = std::min(h - 1, std::max(0, static_cast<int>(y / size * h)));
        return px.get()[(static_cast<size_t>(fy) * w + fx) * 3 + 2] / FIELD_DISTANCE_STEPS * to_reference;
    }
};

// How far each pixel is from the nearest standing piece (px of the reference map; NO_PIECE beyond `reach`): pieces
// along a border in `near_border`, pieces away from every border in `free`. Walls are drawn along the field's
// borders only where a piece stands, since some borders have none in the game.
struct PieceDistances
{
    Plane near_border;
    Plane free;                               // empty when no piece is free
};

// Each pixel's distance to `piece` taken into `into`, within `reach` of it.
void distance_to_piece(Plane& into, const WallPiece& piece, int size, float reach, float scale)
{
    const float r = reach * scale;
    const int x0 = std::max(0, static_cast<int>(std::floor(std::min(piece.x1, piece.x2) - r)));
    const int xe = std::min(size - 1, static_cast<int>(std::ceil(std::max(piece.x1, piece.x2) + r)));
    const int y0 = std::max(0, static_cast<int>(std::floor(std::min(piece.y1, piece.y2) - r)));
    const int ye = std::min(size - 1, static_cast<int>(std::ceil(std::max(piece.y1, piece.y2) + r)));
    const float dx = piece.x2 - piece.x1, dy = piece.y2 - piece.y1, len2 = dx * dx + dy * dy;
    for (int y = y0; y <= ye; ++y)
    {
        for (int x = x0; x <= xe; ++x)
        {
            const float px = x + 0.5f, py = y + 0.5f;
            const float u = unit(len2 > 0 ? ((px - piece.x1) * dx + (py - piece.y1) * dy) / len2 : 0.f);
            const float qx = piece.x1 + u * dx - px, qy = piece.y1 + u * dy - py;
            float& v = into[static_cast<size_t>(y) * size + x];
            v = std::min(v, std::sqrt(qx * qx + qy * qy) / scale);
        }
    }
}

// The pieces' distances (see PieceDistances).
auto piece_distances(const std::vector<WallPiece>& pieces, const Field& field, int size, float reach, float scale)
    -> PieceDistances
{
    const size_t count = static_cast<size_t>(size) * size;
    PieceDistances out;
    out.near_border.assign(count, NO_PIECE);
    for (const WallPiece& piece : pieces)
    {
        float along = 0;
        constexpr float LAST_SAMPLE = ALONG_SAMPLES - 1;
        for (int q = 0; q < ALONG_SAMPLES; ++q)
        {
            const float x = piece.x1 + (piece.x2 - piece.x1) * q / LAST_SAMPLE;
            const float y = piece.y1 + (piece.y2 - piece.y1) * q / LAST_SAMPLE;
            along += field.distance_at(x, y, size) / static_cast<float>(ALONG_SAMPLES);
        }
        const bool free = along > FREE_PIECE_PX;
        if (free && out.free.empty())
        {
            out.free.assign(count, NO_PIECE);
        }
        distance_to_piece(free ? out.free : out.near_border, piece, size, reach, scale);
    }
    return out;
}

// What compose_field knows about one pixel.
struct FieldPixel
{
    size_t i;
    int own;                       // the field's R: the pixel's own lock (0: the open sea)
    int across;                    // G: the lock across the nearest border
    float d;                       // B: the distance to that border, px of the reference map
    const StateLook* state;        // the look of lock_shown
    int lock_shown;                // the lock whose look the pixel takes: its own, or for the sea the nearest
    bool closed;                   // its own lock is locked or sealed
    float wall;                    // how strongly the walls show here (0..1): near a standing piece
    float free_d;                  // the distance to a free piece (NO_PIECE if none)
};

// The field's pixel at (x, y) of a `size` picture.
auto field_pixel(const Field& field, const TerritoryLook& look, const PieceDistances& pieces, int size, int x, int y)
    -> FieldPixel
{
    FieldPixel p{};
    p.i = static_cast<size_t>(y) * size + x;
    const int fx = nearest_pixel(x, size, field.w), fy = nearest_pixel(y, size, field.h);
    const unsigned char* q = field.px.get() + (static_cast<size_t>(fy) * field.w + fx) * 3;
    p.own = q[0];
    p.across = q[1];
    p.d = q[2] / FIELD_DISTANCE_STEPS * field.to_reference;
    p.lock_shown = p.own ? p.own : p.across;
    p.state = p.lock_shown ? look.state[p.lock_shown] : nullptr;
    p.closed = p.own && look.state[p.own] && look.state[p.own]->closed;
    p.wall = unit(1.f - std::max(pieces.near_border[p.i] - p.d - WALL_FADE_PX, 0.f) / WALL_FADE_PX);
    p.free_d = pieces.free.empty() ? NO_PIECE : pieces.free[p.i];
    return p;
}

// How compose_field paints: the walls' spread and reach, and which picture and look it is painting.
struct FieldPaint
{
    const TerritoryLook& look;
    float glow_sd;
    float reach;
    bool duotone;                  // with the player's map: rims and no fills
    bool map_picture;              // the map picture's look (walls in the closed side's colour), else the fog's
};

// One look over (c, a) for pixel p: the fill and rim, then the walls. The open sea next to a lock takes its look
// over the last part of a pixel (the field's smoothed distance), so the coast's edge is a curve, not the label map's
// stairs. The walls: a glow and a core across the border where a standing piece is near, fading out past its end;
// free pieces in cream where they stand. On the map picture closed locks have no fill (they are greyscale) and the
// walls take the closed side's colour, lighter, where the fog picture keeps the cream.
void paint_field(const FieldPaint& how, const FieldPixel& p, float* c, float& a)
{
    const TerritoryLook& look = how.look;
    if (p.state)
    {
        const float fill = how.duotone ? 0.f : p.state->fill;
        const float rim = how.duotone ? p.state->duotone_rim : p.state->rim;
        const float cover = p.own ? 1.f : unit(1.f - p.d);
        blend_over(c, a, look.colour[p.lock_shown], unit(fill + rim_strength(p.d) * rim) * cover);
    }
    const int wallLock = p.closed ? p.own : p.across;
    float mapGlow[3], mapCore[3];
    for (int k = 0; k < 3; ++k)
    {
        mapGlow[k] = look.colour[wallLock][k];
        mapCore[k] = look.colour[wallLock][k] * MAP_CORE_KEEP + MAP_CORE_LIFT;
    }
    const float* glowColour = how.map_picture ? mapGlow : look.glow_colour;
    const float* coreColour = how.map_picture ? mapCore : look.core_colour;
    const float glowAlpha = how.map_picture ? look.map_glow_alpha : look.glow_alpha;
    const float coreAlpha = how.map_picture ? look.map_core_alpha : look.core_alpha;
    const float spread = 2.f * how.glow_sd * how.glow_sd;
    if (p.wall > 0.f)
    {
        blend_over(c, a, glowColour, glowAlpha * p.wall * std::exp(-p.d * p.d / spread));
        blend_over(c, a, coreColour, coreAlpha * p.wall * unit(look.core_width / 2.f + 0.5f - p.d));
    }
    if (p.free_d < how.reach)
    {
        const float e = p.free_d;
        blend_over(c, a, look.glow_colour, glowAlpha * std::exp(-e * e / spread));   // (out at sea, no lock's: cream)
        blend_over(c, a, look.core_colour, coreAlpha * unit(look.core_width / 2.f + 0.5f - e));
    }
}

// The map picture's pixel (RGBA into `out`): the player's map (gamma applied with lut), greyscale where the pixel's
// own lock is closed, the look painted over it.
void map_picture_pixel(const FieldPaint& how, const FieldPixel& p, const unsigned char* map, const GammaTable& lut,
                       unsigned char* out)
{
    float c[3] = {lut[map[0]] / 255.f, lut[map[1]] / 255.f, lut[map[2]] / 255.f}, a = 1.f;
    if (p.closed)
    {
        const float grey = luminance(c[0], c[1], c[2]);
        c[0] = c[1] = c[2] = grey;
    }
    paint_field(how, p, c, a);
    for (int k = 0; k < 3; ++k)
    {
        out[k] = to_byte(c[k]);
    }
    out[3] = 255;
}

// The duotone fog picture's pixel (RGB into `out`): the open sea the map's brightness over the fog colour; a lock
// its own colour from dark to light with the map's brightness, dimmer while locked or sealed; then the rims and the
// cream walls.
void duotone_fog_pixel(const FieldPaint& how, const FieldPixel& p, const unsigned char* map, const GammaTable& lut,
                       unsigned char* out)
{
    const TerritoryLook& look = how.look;
    const float lum = DUOTONE_LUMA_RED * lut[map[0]] / 255.f + DUOTONE_LUMA_GREEN * lut[map[1]] / 255.f +
                      DUOTONE_LUMA_BLUE * lut[map[2]] / 255.f;
    const StateLook* own = p.own ? look.state[p.own] : nullptr;
    float c[3] = {0, 0, 0}, a = 1.f;
    if (!own)
    {
        for (int k = 0; k < 3; ++k)
        {
            c[k] = lum * DUOTONE_SEA_MAP + look.fog_colour[k] * DUOTONE_SEA_FOG;
        }
    }
    else
    {
        const float t = std::pow(unit((lum - DUOTONE_DARKEST) / DUOTONE_RANGE), DUOTONE_CURVE);
        for (int k = 0; k < 3; ++k)
        {
            const float dark = look.fog_colour[k] * DUOTONE_DARK_FOG + look.colour[p.own][k] * DUOTONE_DARK_LOCK;
            const float light = (look.colour[p.own][k] * DUOTONE_LIGHT_LOCK + DUOTONE_LIGHT_LIFT) *
                                own->duotone_brightness;
            c[k] = dark + (light - dark) * t;
        }
    }
    paint_field(how, p, c, a);
    for (int k = 0; k < 3; ++k)
    {
        out[k] = to_byte(c[k]);
    }
}

// Without the player's map: the overlay's pixel (RGBA into `overlay`) and, if `fog` is given, the same over the fog
// colour (RGB).
void overlay_pixel(const FieldPaint& how, const FieldPixel& p, unsigned char* overlay, unsigned char* fog)
{
    float c[3] = {0, 0, 0}, a = 0;
    paint_field(how, p, c, a);
    for (int k = 0; k < 3; ++k)
    {
        overlay[k] = to_byte(c[k]);
    }
    overlay[3] = to_byte(a);
    if (!fog) return;
    for (int k = 0; k < 3; ++k)
    {
        fog[k] = to_byte(c[k] * a + how.look.fog_colour[k] * (1 - a));
    }
}

// Reads the distance field into `field`; "" or what went wrong.
auto read_field(const std::string& path, Field& field) -> std::string
{
    field.px = read_png(path, 3, field.w, field.h);
    if (!field.px) return read_failure(path);
    if (field.w != field.h) return "field " + path + " is not square";
    field.to_reference = static_cast<float>(REFERENCE_MAP_PX) / field.w;
    return "";
}
// The player's saved map, if compose_field was given it: RGBA bytes, and the gamma to apply.
struct PlayerMap
{
    StbPixels px = no_pixels();
    int w = 0, h = 0;
    GammaTable lut{};
    // The map's pixel nearest to (x, y) of a `size` picture.
    auto at(int x, int y, int size) const -> const unsigned char*
    {
        return px.get() + (static_cast<size_t>(nearest_pixel(y, size, h)) * w + nearest_pixel(x, size, w)) * 4;
    }
};

// compose_field's two pictures, every pixel: with the player's map, the map picture and the duotone fog picture;
// without it, the overlay and the fills and rims over the fog colour. `fog_picture` is empty when none is wanted.
void field_pictures(const Field& field, const PlayerMap& map, const PieceDistances& pieces, const FieldPaint& onMap,
                    const FieldPaint& onFog, int size, std::vector<unsigned char>& picture,
                    std::vector<unsigned char>& fog_picture)
{
    const bool withMap = static_cast<bool>(map.px);
    for (int y = 0; y < size; ++y)
    {
        for (int x = 0; x < size; ++x)
        {
            const FieldPixel p = field_pixel(field, onFog.look, pieces, size, x, y);
            unsigned char* fogOut = fog_picture.empty() ? nullptr : &fog_picture[p.i * 3];
            if (!withMap)
            {
                overlay_pixel(onFog, p, &picture[p.i * 4], fogOut);
                continue;
            }
            const unsigned char* m = map.at(x, y, size);
            map_picture_pixel(onMap, p, m, map.lut, &picture[p.i * 4]);
            if (fogOut)
            {
                duotone_fog_pixel(onFog, p, m, map.lut, fogOut);
            }
        }
    }
}

} // namespace

auto compose_territories(const std::string& labels, const std::string& locks, const std::string& walls,
                         const std::string& style, const std::string& out, const std::string& fogart,
                         const std::string& fog, int size) -> std::string
{
    if (size < MIN_PICTURE_PX || size > MAX_TERRITORIES_PX) return "territories size " + std::to_string(size);
    const float scale = size / static_cast<float>(REFERENCE_MAP_PX);   // the style's px are of the reference map
    int lw = 0, lh = 0;
    const StbPixels lab = read_png(labels, 1, lw, lh);
    if (!lab) return read_failure(labels);
    TerritoryLook look;
    const std::string bad = read_look(locks, style, fog, look);
    if (!bad.empty()) return bad;
    std::vector<WallPiece> pieces;
    const std::string badWalls = read_walls(walls, size, pieces);
    if (!badWalls.empty()) return badWalls;
    const std::vector<unsigned char> lockAt = labels_at_size(lab.get(), lw, lh, size);
    std::vector<int> dist = lock_edges(lockAt, size);
    chamfer_forward(dist, size);
    chamfer_back(dist, size);
    Overlay img(static_cast<size_t>(size) * size * 4, 0.f);
    fill_and_rim(img, lockAt, dist, look, scale);
    draw_walls(img, pieces, look, size, scale);
    return write_overlay(img, size, look, out, fogart);
}

auto compose_field(const std::string& field, const std::string& locks, const std::string& walls,
                   const std::string& style, const std::string& out, const std::string& fogart,
                   const std::string& fog, int size, const std::string& colour, double gamma) -> std::string
{
    if (size < MIN_PICTURE_PX || size > MAX_TERRITORIES_PX) return "field size " + std::to_string(size);
    TerritoryLook look;
    std::string err = read_look(locks, style, fog, look);
    if (!err.empty()) return err;
    Field distances;
    err = read_field(field, distances);
    if (!err.empty()) return err;
    PlayerMap map;
    if (!colour.empty())
    {
        map.px = read_png(colour, 4, map.w, map.h);
        if (!map.px) return read_failure(colour);
    }
    map.lut = gamma_table(gamma);
    std::vector<WallPiece> pieces;
    err = read_walls(walls, size, pieces);
    if (!err.empty()) return err;
    const float scale = size / static_cast<float>(REFERENCE_MAP_PX);   // the look's px are of the reference map
    const float glowSd = look.glow_width * GLOW_SD_PER_WIDTH;
    const float reach = REACH_GLOW_SDS * glowSd + REACH_EXTRA_PX;
    PieceDistances near = piece_distances(pieces, distances, size, reach, scale);
    const bool withMap = static_cast<bool>(map.px);
    const FieldPaint onMap{look, glowSd, reach, withMap, true}, onFog{look, glowSd, reach, withMap, false};
    const size_t count = static_cast<size_t>(size) * size;
    std::vector<unsigned char> picture(count * 4), fogPicture(fogart.empty() ? 0 : count * 3);
    field_pictures(distances, map, near, onMap, onFog, size, picture, fogPicture);
    distances.px.reset();      // the inputs freed before the PNGs are compressed
    map.px.reset();
    near = PieceDistances{};
    if (!write_png_fast(out, size, size, 4, picture.data())) return "could not write " + out;
    if (fogPicture.empty()) return "";
    return write_png_fast(fogart, size, size, 3, fogPicture.data()) ? "" : "could not write " + fogart;
}
