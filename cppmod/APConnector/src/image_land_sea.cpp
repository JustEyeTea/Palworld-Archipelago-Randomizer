// Land, sea and beyond the world's edge on the game's map (image_land_sea.hpp).
#include "image_land_sea.hpp"

#include <algorithm>
#include <cmath>

using namespace image_basics;

namespace
{
// Beyond the world's edge the map is flat dark grey: channels this close to each other, and darker than this.
constexpr float GREY_CHANNELS_WITHIN = 0.02f;
constexpr float OUTSIDE_DARKER_THAN = 0.16f;
// The sea is teal: blue above red by at least this much, green above red, darker than this, and red below this
// (bluish sand and snow are not sea).
constexpr float SEA_BLUE_OVER_RED = 0.08f;
constexpr float SEA_DARKER_THAN = 0.45f;
constexpr float SEA_RED_BELOW = 0.25f;
// The softened sea above this is sea: a few teal pixels alone on land are not.
constexpr float SEA_ABOVE = 0.5f;
// How far each plane is softened: the blur radius is the picture's width divided by the first number (the pixels at
// a 4096 map in brackets), never below the second.
constexpr int OUTSIDE_SOFTEN_DIVISOR = 250, OUTSIDE_SOFTEN_MIN_PX = 2;   // (16) land this near the edge is not land
constexpr int SEA_SOFTEN_DIVISOR = 1000, SEA_SOFTEN_MIN_PX = 1;         // (4)
constexpr int LAND_SOFTEN_DIVISOR = 700, LAND_SOFTEN_MIN_PX = 1;        // (6) a smooth coast

// The blur radius for a plane of this width (see the constants above).
auto soften_radius(int width, int divisor, int min_px) -> int
{
    return std::max(min_px, width / divisor);
}
} // namespace

auto classify_map(const Rgba& map, double gamma, Plane* brightness) -> LandAndSea
{
    const int S = map.s;
    const size_t N = static_cast<size_t>(S) * S;
    LandAndSea planes;
    planes.outside.assign(N, 0.f);
    Plane sea(N);
    if (brightness)
    {
        brightness->assign(N, 0.f);
    }
    for (size_t i = 0; i < N; ++i)
    {
        const float* p = &map.px[i * 4];
        const float R = static_cast<float>(std::pow(p[0], gamma)), G = static_cast<float>(std::pow(p[1], gamma)),
                    B = static_cast<float>(std::pow(p[2], gamma));
        const float Y = luminance(R, G, B);
        if (brightness)
        {
            (*brightness)[i] = Y;
        }
        const bool grey = std::fabs(R - G) < GREY_CHANNELS_WITHIN && std::fabs(G - B) < GREY_CHANNELS_WITHIN;
        const bool outside = grey && Y < OUTSIDE_DARKER_THAN;
        const bool teal = B > R + SEA_BLUE_OVER_RED && G > R && Y < SEA_DARKER_THAN && R < SEA_RED_BELOW;
        planes.outside[i] = outside ? 1.f : 0.f;
        sea[i] = (!outside && teal) ? 1.f : 0.f;
    }
    planes.outside_soft = planes.outside;
    blur(planes.outside_soft, S, S, soften_radius(S, OUTSIDE_SOFTEN_DIVISOR, OUTSIDE_SOFTEN_MIN_PX));
    blur(sea, S, S, soften_radius(S, SEA_SOFTEN_DIVISOR, SEA_SOFTEN_MIN_PX));
    planes.land.assign(N, 0.f);
    for (size_t i = 0; i < N; ++i)
    {
        const bool away = !planes.outside[i] && planes.outside_soft[i] <= NEAR_EDGE_ABOVE;
        planes.land[i] = (away && sea[i] < SEA_ABOVE) ? 1.f : 0.f;
    }
    Plane().swap(sea);                                  // freed before the next plane: these are 64 MB each at 4096
    planes.land_soft = planes.land;
    blur(planes.land_soft, S, S, soften_radius(S, LAND_SOFTEN_DIVISOR, LAND_SOFTEN_MIN_PX));
    return planes;
}

auto land_mask(const std::string& colour, int S, double gamma, std::string& err) -> Plane
{
    const Rgba map = load_rgba(colour, S, err);
    if (!err.empty()) return {};
    return classify_map(map, gamma).land_soft;
}
