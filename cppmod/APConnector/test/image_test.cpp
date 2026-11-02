// Linux check of image_tools: a 2x1 PNG (pure red, pure green) comes back grey with the expected luminance.
//   g++ -std=c++17 -Isrc -Ithird_party/stb test/image_test.cpp src/image_tools.cpp -o /tmp/image_test && /tmp/image_test
#include <cstdio>
#include "image_tools.hpp"
#include "stb_image.h"
#include "stb_image_write.h"

int main()
{
    const unsigned char src[8] = {255, 0, 0, 255, 0, 255, 0, 128};
    stbi_write_png("/tmp/image_test_in.png", 2, 1, 4, src, 8);
    const auto err = greyscale_png("/tmp/image_test_in.png", "/tmp/image_test_out.png", 1.0);
    if (!err.empty()) { std::printf("FAIL %s\n", err.c_str()); return 1; }
    int w, h, n;
    unsigned char* px = stbi_load("/tmp/image_test_out.png", &w, &h, &n, 4);
    const bool ok = px && w == 2 && px[0] == 54 && px[1] == 54 && px[2] == 54 && px[4] == 182 && px[6] == 182 && px[7] == 128;
    std::printf("%s red -> %d, green -> %d, alpha %d\n", ok ? "ok" : "FAIL", px ? px[0] : -1, px ? px[4] : -1, px ? px[7] : -1);
    return ok ? 0 : 1;
}
