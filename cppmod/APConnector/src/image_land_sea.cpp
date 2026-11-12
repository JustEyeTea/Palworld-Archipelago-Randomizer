// land_mask (image_land_sea.hpp).
#include "image_land_sea.hpp"

#include <algorithm>
#include <cmath>

using namespace image_basics;

auto land_mask(const std::string& colour, int S, double gamma, std::string& err) -> Plane
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
