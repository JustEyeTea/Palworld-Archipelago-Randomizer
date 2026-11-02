// Small image helpers for the Lua mod, independent of UE4SS (tested on Linux by test/image_test.cpp).
#pragma once

#include <string>

// Reads a PNG, writes it in greyscale (Rec. 709 luminance, alpha kept). gamma != 1 also brightens or darkens it
// (value^gamma): the game exports render targets in linear light, which looks dark once loaded back as a picture.
// Returns "" on success, else what went wrong.
auto greyscale_png(const std::string& in, const std::string& out, double gamma) -> std::string;

// Composes the world map with locked areas in greyscale: colour where an area is open, greyscale where it is locked,
// with a soft (blurred) boundary and a gentle inner shadow along a locked area's edge. labels: a greyscale PNG the
// size of the colour map, each pixel the index of its area; locked: "3,7,12". gamma as in greyscale_png, applied to
// the colour map. Returns "" on success, else what went wrong.
auto compose_map(const std::string& colour, const std::string& labels, const std::string& locked, const std::string& out,
                 double gamma) -> std::string;

// compose_map on a background thread: start returns "" (started), "busy" or an error; status returns "busy", "done"
// (the last job finished well; then "" until the next), or "error: ...".
auto compose_map_start(const std::string& colour, const std::string& labels, const std::string& locked,
                       const std::string& out, double gamma) -> std::string;
auto compose_map_status() -> std::string;
