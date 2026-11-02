#include "image_tools.hpp"

#include <cmath>

#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

auto greyscale_png(const std::string& in, const std::string& out, double gamma) -> std::string
{
    int w = 0, h = 0, n = 0;
    unsigned char* px = stbi_load(in.c_str(), &w, &h, &n, 4);
    if (!px) return std::string("could not read ") + in + ": " + stbi_failure_reason();
    unsigned char lut[256];
    for (int i = 0; i < 256; ++i)
        lut[i] = static_cast<unsigned char>(std::lround(255.0 * std::pow(i / 255.0, gamma)));
    for (long i = 0, count = static_cast<long>(w) * h; i < count; ++i)
    {
        unsigned char* p = px + i * 4;
        const double y = 0.2126 * lut[p[0]] + 0.7152 * lut[p[1]] + 0.0722 * lut[p[2]];
        p[0] = p[1] = p[2] = static_cast<unsigned char>(std::lround(y));
    }
    const int ok = stbi_write_png(out.c_str(), w, h, 4, px, w * 4);
    stbi_image_free(px);
    return ok ? "" : "could not write " + out;
}
