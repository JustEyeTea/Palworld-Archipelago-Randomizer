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
    if (!(st == "done" && grey && colour && soft)) return 1;

    // compose_chart: a 256x256 map: a grey band beyond the world's edge on the left, teal sea, a green island in the
    // middle. Land comes out as warm paper, the sea cooler, the coast inked dark, beyond the edge darker paper.
    std::vector<unsigned char> cm(256 * 256 * 4);
    for (int y = 0; y < 256; ++y)
        for (int x = 0; x < 256; ++x)
        {
            unsigned char* q = &cm[(y * 256 + x) * 4];
            const bool beyond = x < 40, island = x >= 110 && x < 190 && y >= 90 && y < 170;
            const unsigned char c[3] = {static_cast<unsigned char>(beyond ? 28 : island ? 90 : 0),
                                        static_cast<unsigned char>(beyond ? 28 : island ? 140 : 38),
                                        static_cast<unsigned char>(beyond ? 28 : island ? 60 : 58)};
            q[0] = c[0]; q[1] = c[1]; q[2] = c[2]; q[3] = 255;
        }
    stbi_write_png("/tmp/chart_map.png", 256, 256, 4, cm.data(), 256 * 4);
    const auto cerr = compose_chart("/tmp/chart_map.png", "", "", "", "/tmp/chart_out.png", 256, 1.0);
    unsigned char* c = cerr.empty() ? stbi_load("/tmp/chart_out.png", &w, &h, &n, 3) : nullptr;
    auto cpx = [&](int x, int y) { return c + (y * 256 + x) * 3; };
    auto lum = [&](int x, int y) { const unsigned char* q = cpx(x, y); return 0.2126 * q[0] + 0.7152 * q[1] + 0.0722 * q[2]; };
    const bool paperLand = c && cpx(150, 130)[0] > cpx(150, 130)[2] + 30 && lum(150, 130) > 170;         // warm, light
    const bool coolSea = c && (cpx(80, 130)[2] - cpx(80, 130)[0]) > (cpx(150, 130)[2] - cpx(150, 130)[0]); // bluer than land
    const bool coast = c && lum(110, 130) < lum(150, 130) - 40;                                      // inked edge
    const bool beyondDark = c && lum(10, 130) < lum(80, 130) - 10;                                   // darker past the frame
    const bool chartOk = cerr.empty() && w == 256 && paperLand && coolSea && coast && beyondDark;
    std::printf("%s chart: %s land %.0f, sea %.0f, coast %.0f, beyond %.0f\n", chartOk ? "ok" : "FAIL",
                cerr.empty() ? "written" : cerr.c_str(), c ? lum(150, 130) : -1.0, c ? lum(80, 130) : -1.0,
                c ? lum(110, 130) : -1.0, c ? lum(10, 130) : -1.0);
    if (!chartOk) return 1;

    // compose_fog: the chart above, a mask explored (red high) on the right half only: see-through on the right, the
    // chart on the left, inked and partly shown along the edge. The fog slot runs it in the background.
    std::vector<unsigned char> mk(64 * 64 * 4);
    for (int i = 0; i < 64 * 64; ++i) { mk[i * 4] = (i % 64) >= 32 ? 255 : 0; mk[i * 4 + 3] = 255; }
    stbi_write_png("/tmp/fog_mask.png", 64, 64, 4, mk.data(), 64 * 4);
    if (fog_jobs().start([] { return compose_fog("/tmp/chart_out.png", "/tmp/fog_mask.png", "", "r+", "/tmp/fog_out.png", 256); }) != "")
        { std::printf("FAIL fog could not start\n"); return 1; }
    std::string fst;
    while ((fst = fog_jobs().status()) == "busy") {}
    unsigned char* f = fst == "done" ? stbi_load("/tmp/fog_out.png", &w, &h, &n, 4) : nullptr;
    auto fa = [&](int x, int y) { return f ? f[(y * 256 + x) * 4 + 3] : -1; };
    const bool fogOk = f && fa(20, 128) == 255 && fa(240, 128) == 0 && fa(128, 128) > 0 && fa(128, 128) < 255
                       && compose_fog("/tmp/chart_out.png", "/tmp/fog_mask.png", "", "x+", "/tmp/fog_bad.png", 256) != "";
    std::printf("%s fog: %s, alpha unexplored %d, explored %d, edge %d\n", fogOk ? "ok" : "FAIL", fst.c_str(),
                fa(20, 128), fa(240, 128), fa(128, 128));
    return fogOk ? 0 : 1;
}
