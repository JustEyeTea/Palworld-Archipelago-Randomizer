// Small image helpers for the Lua mod, independent of UE4SS (tested on Linux by test/image_test.cpp).
#pragma once

#include <functional>
#include <mutex>
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

// The explorer's-chart picture of the map (the user, 2026-11-06: unexplored areas drawn like an explorer's chart instead
// of the black fog, so the locked-area stamps show there too). size x size, opaque: paper, with land and sea told apart
// by colour; inked coastlines, coastal ripple rings, light contours and relief on land, a double-ruled frame along the
// world's edge and cross-hatching beyond it. colour: the map as compose_map reads it (gamma as there). paper / sea /
// compass: the Art lane's ap-chart-*.png ("" for each: plain procedural paper, no sea marks, no compass). Returns "" on
// success, else what went wrong. Look worked out in a numpy prototype against the real map (2026-11-06).
auto compose_chart(const std::string& colour, const std::string& paper, const std::string& sea, const std::string& compass,
                   const std::string& out, int size, double gamma) -> std::string;

// A PNG's colour at (u, v) in 0..1 (the 3x3 pixels around it averaged): "r,g,b,a" in 0..255, or "error: ...". Lua
// reads the game's explored mask with it (which channel, which way round).
auto sample_png(const std::string& path, double u, double v) -> std::string;

// The fog picture: the chart where the player hasn't explored, see-through where they have, with a soft inked edge
// between (size x size RGBA). mask: the explored mask exported from the game (fog-mask.png); default_mask: the map's
// always-uncovered mask (fog-default-mask.png, "" for none); explored where either says so. spec says how to read
// them, as the in-game probe shows: a channel and which way round, "r+" (explored where red is high), "r-", "a+", ...
// stamps: the locked areas' stamps drawn on top wherever the fog is ("path|u|v|px;..." with u, v in 0..1 and px their
// width on a 4096 map; "" for none), so they show on the chart. Returns "" on success, else what went wrong.
// regions (the user, 2026-11-07: "should the regions on the unexplored map have better boundaries?"): borders between
// neighbouring areas and a hatch over locked ones, drawn on the chart before the explored parts are cut out.
// "labels|locked|hatch|r,g,b,a|width|dash|gap|hatchop": labels the area label PNG (as compose_map), locked "3,7,12",
// hatch a tile PNG ("" for a plain diagonal hatch in the ink), ink 0-255, width/dash/gap in px at this size (dash 0: a
// solid line; dashes are measured along the border, so they stay even round curves), hatchop 0..1. "" for none.
auto compose_fog(const std::string& chart, const std::string& mask, const std::string& default_mask,
                 const std::string& spec, const std::string& out, int size, const std::string& stamps = "",
                 const std::string& regions = "") -> std::string;

// One background job at a time per slot (the map, the chart, the fog each have their own), as compose_map_start:
// start returns "" (started), "busy" or an error; status "busy", "done" (once), "error: ..." or "".
class JobSlot
{
  public:
    auto start(std::function<std::string()> job) -> std::string;
    auto status() -> std::string;

  private:
    std::mutex m_lock;
    std::string m_state;                            // "busy", "done", "error: ..." or ""
};
auto chart_jobs() -> JobSlot&;
auto fog_jobs() -> JobSlot&;
