// The game's world map told apart into what lies beyond the world's edge, the sea and land: the explorer's chart
// draws each its own way (image_chart.cpp), and the fog's borders stay on land (image_fog.cpp). The colour tests were
// tuned by eye on Palworld's map; if an update recolours it, they are the constants at the top of image_land_sea.cpp.
#pragma once

#include "image_basics.hpp"

#include <string>

// outside_soft above this is near the world's edge (land there is not counted as land).
constexpr float NEAR_EDGE_ABOVE = 0.02f;

// The map's planes, each the picture's size, 0 or 1 per pixel unless softened (blurred).
struct LandAndSea
{
    image_basics::Plane outside;       // beyond the world's edge, where the map is flat dark grey
    image_basics::Plane outside_soft;  // outside, softened
    image_basics::Plane land;          // not outside, not near the edge, and not sea (teal, deep or shallow)
    image_basics::Plane land_soft;     // land, softened: the coast is where it crosses 0.5
};

// The map (as load_rgba gives it) told apart. gamma is applied to each channel first, as compose_map does (the game
// exports the map in linear light). brightness, if given, gets each pixel's brightness (Rec. 709) after the gamma.
auto classify_map(const image_basics::Rgba& map, double gamma, image_basics::Plane* brightness = nullptr) -> LandAndSea;

// Where the map in the PNG `colour` is land, at S x S: classify_map's land_soft. On failure an empty plane, with the
// reason in err.
auto land_mask(const std::string& colour, int S, double gamma, std::string& err) -> image_basics::Plane;
