// Telling land from sea and from beyond the world's edge on the game's map, for the fog's borders.
#pragma once

#include "image_basics.hpp"

#include <string>

// Where the map is land (0..1, softened), as compose_chart tells land from sea and from beyond the world's edge.
auto land_mask(const std::string& colour, int S, double gamma, std::string& err) -> image_basics::Plane;
