// Linux check of image_tools: a 2x1 PNG (pure red, pure green) comes back grey with the expected luminance.
//   g++ -std=c++17 -pthread -Isrc -Ithird_party/stb test/image_test.cpp src/image_tools.cpp -o /tmp/image_test && /tmp/image_test
#include <cstdio>
#include <string>
#include <vector>
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
    if (!ok) return 1;

    // compose_map: a 200x100 map, all red; area 1 on the left half is locked, area 2 on the right is open.
    std::vector<unsigned char> map(200 * 100 * 4), lab(200 * 100);
    for (int i = 0; i < 200 * 100; ++i) { map[i * 4] = 255; map[i * 4 + 3] = 255; lab[i] = (i % 200) < 100 ? 1 : 2; }
    stbi_write_png("/tmp/compose_map.png", 200, 100, 4, map.data(), 800);
    stbi_write_png("/tmp/compose_lab.png", 200, 100, 1, lab.data(), 200);
    if (compose_map_start("/tmp/compose_map.png", "/tmp/compose_lab.png", "1", "/tmp/compose_out.png", 1.0) != "")
        { std::printf("FAIL could not start\n"); return 1; }
    std::string st;
    while ((st = compose_map_status()) == "busy") {}
    unsigned char* o = stbi_load("/tmp/compose_out.png", &w, &h, &n, 4);
    auto at = [&](int x, int y) { return o + (y * 200 + x) * 4; };
    const bool grey = o && at(20, 50)[0] == at(20, 50)[1] && at(20, 50)[0] > 40 && at(20, 50)[0] < 60;   // deep inside: Y(red)=54
    const bool colour = o && at(180, 50)[0] == 255 && at(180, 50)[1] == 0;                             // open: untouched
    const bool soft = o && at(99, 50)[0] > at(20, 50)[0] && at(99, 50)[0] < 255 && at(99, 50)[1] > 0;   // mixed at the edge
    std::printf("%s compose: %s, inside %d, open %d, edge %d/%d\n", st == "done" && grey && colour && soft ? "ok" : "FAIL",
                st.c_str(), o ? at(20, 50)[0] : -1, o ? at(180, 50)[0] : -1, o ? at(99, 50)[0] : -1, o ? at(99, 50)[1] : -1);
    return st == "done" && grey && colour && soft ? 0 : 1;
}
