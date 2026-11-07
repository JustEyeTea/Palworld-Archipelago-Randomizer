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
    if (!fogOk) return 1;

    // sample_png: the mask above reads 255 red on its right half, 0 on its left; a missing file is an error.
    const auto right = sample_png("/tmp/fog_mask.png", 0.9, 0.5), left = sample_png("/tmp/fog_mask.png", 0.1, 0.5);
    const bool sampleOk = right == "255,0,0,255" && left == "0,0,0,255" && sample_png("/tmp/no_such.png", 0, 0).rfind("error:", 0) == 0;
    std::printf("%s sample: right %s, left %s\n", sampleOk ? "ok" : "FAIL", right.c_str(), left.c_str());
    if (!sampleOk) return 1;

    // compose_fog with a stamp: a pure blue 32x32 stamp at the middle of the unexplored half is drawn over the chart.
    std::vector<unsigned char> stp(32 * 32 * 4);
    for (int i = 0; i < 32 * 32; ++i) { stp[i * 4 + 2] = 255; stp[i * 4 + 3] = 255; }
    stbi_write_png("/tmp/fog_stamp.png", 32, 32, 4, stp.data(), 32 * 4);
    const auto serr = compose_fog("/tmp/chart_out.png", "/tmp/fog_mask.png", "", "r+", "/tmp/fog_stamped.png", 256,
                                  "/tmp/fog_stamp.png|0.25|0.5|256;");
    unsigned char* g = serr.empty() ? stbi_load("/tmp/fog_stamped.png", &w, &h, &n, 4) : nullptr;
    auto gp = [&](int x, int y) { return g + (y * 256 + x) * 4; };
    const bool stampOk = g && gp(64, 128)[2] == 255 && gp(64, 128)[0] == 0 && gp(64, 128)[3] == 255 && gp(20, 20)[2] < 255;
    std::printf("%s fog stamp: %s, at the stamp %d,%d,%d\n", stampOk ? "ok" : "FAIL", serr.empty() ? "written" : serr.c_str(),
                g ? gp(64, 128)[0] : -1, g ? gp(64, 128)[1] : -1, g ? gp(64, 128)[2] : -1);
    if (!stampOk) return 1;

    // compose_fog with regions: labels (64x64) area 1 on x 0-15, area 2 (locked) on x 16-31, 0 (no area) beyond; a red
    // ink. A solid border where 1 meets 2 (chart x 64), none where 2 meets 0 (x 128, the coast); a hatch on area 2 only.
    std::vector<unsigned char> lb(64 * 64);
    for (int i = 0; i < 64 * 64; ++i) { const int x = i % 64; lb[i] = x < 16 ? 1 : (x < 32 ? 2 : 0); }
    stbi_write_png("/tmp/fog_labels.png", 64, 64, 1, lb.data(), 64);
    const auto rerr = compose_fog("/tmp/chart_out.png", "/tmp/fog_mask.png", "", "r+", "/tmp/fog_regions.png", 256, "",
                                  "/tmp/fog_labels.png|2||255,0,0,255|2|0|0|0.5");
    unsigned char* rg = rerr.empty() ? stbi_load("/tmp/fog_regions.png", &w, &h, &n, 4) : nullptr;
    auto rp = [&](int x, int y) { return rg + (y * 256 + x) * 4; };
    auto redness = [&](int x, int y) { return rg ? rp(x, y)[0] - (rp(x, y)[1] + rp(x, y)[2]) / 2 : -999; };
    const bool border = rg && rp(63, 128)[0] == 255 && rp(63, 128)[1] == 0;                   // area 1 | area 2
    const bool noCoast = rg && redness(127, 128) < 120;                                     // area 2 | no area: none
    const bool hatch = rg && redness(96, 128) > redness(100, 128) + 40;                     // a hatch line in area 2
    const bool noHatch = rg && std::abs(redness(30, 130) - redness(34, 130)) < 40;          // area 1: plain chart
    int on = 0;                                                                              // dashes 4 on, 4 off
    const auto derr = compose_fog("/tmp/chart_out.png", "/tmp/fog_mask.png", "", "r+", "/tmp/fog_dashed.png", 256, "",
                                  "/tmp/fog_labels.png|||255,0,0,255|1|4|4|0");
    unsigned char* dg = derr.empty() ? stbi_load("/tmp/fog_dashed.png", &w, &h, &n, 4) : nullptr;
    for (int y = 40; y < 216 && dg; ++y)          // (a softened 1 px line: red over the paper, not pure red)
    {
        const unsigned char* q = &dg[(y * 256 + 63) * 4];
        if (q[0] - (q[1] + q[2]) / 2 > 60) ++on;
    }
    const bool dashed = dg && on > 60 && on < 120;
    const bool badSpec = compose_fog("/tmp/chart_out.png", "/tmp/fog_mask.png", "", "r+", "/tmp/fog_bad2.png", 256, "",
                                     "/tmp/fog_labels.png|2") != "";
    const bool regionsOk = border && noCoast && hatch && noHatch && dashed && badSpec;
    std::printf("%s fog regions: %s / %s, border %d, coast %d, hatch %d vs %d, area 1 %d vs %d, dashed %d of 176\n",
                regionsOk ? "ok" : "FAIL", rerr.empty() ? "written" : rerr.c_str(), derr.empty() ? "written" : derr.c_str(),
                rg ? rp(63, 128)[0] : -1, redness(127, 128), redness(96, 128), redness(100, 128), redness(30, 130),
                redness(34, 130), on);
    if (!regionsOk) return 1;

    // Land only (the user, dev.30 test: borders and hatch ran out over the sea): a colour map with land (tan) on x 0-23
    // of 64 and sea (teal) beyond. Area 2 (x 16-31) is land on 16-23 and sea on 24-31: the hatch only on its land part;
    // the border between areas 1 and 2 (both land) still drawn.
    std::vector<unsigned char> lm(64 * 64 * 4);
    for (int i = 0; i < 64 * 64; ++i)
    {
        const bool landPx = (i % 64) < 24;
        lm[i * 4] = landPx ? 204 : 26; lm[i * 4 + 1] = landPx ? 178 : 102; lm[i * 4 + 2] = landPx ? 128 : 128; lm[i * 4 + 3] = 255;
    }
    stbi_write_png("/tmp/fog_colour.png", 64, 64, 4, lm.data(), 64 * 4);
    const auto lerr = compose_fog("/tmp/chart_out.png", "/tmp/fog_mask.png", "", "r+", "/tmp/fog_land.png", 256, "",
                                  "/tmp/fog_labels.png|2||255,0,0,255|2|0|0|0.5|/tmp/fog_colour.png|1.0");
    unsigned char* lg = lerr.empty() ? stbi_load("/tmp/fog_land.png", &w, &h, &n, 4) : nullptr;
    auto lred = [&](int x, int y) { return lg ? lg[(y * 256 + x) * 4] - (lg[(y * 256 + x) * 4 + 1] + lg[(y * 256 + x) * 4 + 2]) / 2 : -999; };
    const bool landBorder = lg && lg[(128 * 256 + 63) * 4] > 200 && lg[(128 * 256 + 63) * 4 + 1] < 60;
    const bool landHatch = lred(68, 128) > lred(71, 128) + 40 && lred(82, 128) > lred(85, 128) + 40;   // lines on land (x+y = 0 mod 14)
    int seaHatch = 0;
    for (int x = 104; x < 124; ++x) if (lred(x, 128) - lred(x + 1, 128) > 40) ++seaHatch;           // none on the sea
    const bool landOk = landBorder && landHatch && seaHatch == 0;
    std::printf("%s fog regions on land: %s, border %d, hatch lines on the sea %d\n", landOk ? "ok" : "FAIL",
                lerr.empty() ? "written" : lerr.c_str(), lg ? lg[(128 * 256 + 63) * 4] : -1, seaHatch);
    if (!landOk) return 1;

    // compose_territories (the user's direction 1): labels 64x64, area 1 (locked, red) on the left half, area 2 (visited,
    // green) on the right, sea (0) on the bottom eighth; one standing wall between them at u 0.5, v 0.1-0.8.
    std::vector<unsigned char> tl(64 * 64);
    for (int i = 0; i < 64 * 64; ++i) { const int x = i % 64, y = i / 64; tl[i] = y >= 56 ? 0 : (x < 32 ? 1 : 2); }
    stbi_write_png("/tmp/terr_labels.png", 64, 64, 1, tl.data(), 64);
    const auto terr = compose_territories("/tmp/terr_labels.png", "1:l:FF0000,2:v:00FF00", "0.5,0.1,0.5,0.8;",
                                          "FFE9B0,0.55,FFF4DC,1,160,48,80",       // (wide: 10/5 px at this 256 size)
                                          "/tmp/terr_out.png", "/tmp/terr_fog.png", "102030", 256);
    unsigned char* tg = terr.empty() ? stbi_load("/tmp/terr_out.png", &w, &h, &n, 4) : nullptr;
    unsigned char* tf = terr.empty() ? stbi_load("/tmp/terr_fog.png", &w, &h, &n, 3) : nullptr;
    auto tp = [&](int x, int y) { return tg + (y * 256 + x) * 4; };
    const bool lockedFill = tg && tp(40, 100)[0] > 200 && tp(40, 100)[1] < 40 && tp(40, 100)[3] > 70 && tp(40, 100)[3] < 110;  // ~0.34
    const bool rimNearEdge = tg && tp(40, 223)[3] > tp(40, 100)[3] + 80;           // the rim, on area 1's edge with the sea
    const bool visitedClear = tg && tp(200, 100)[3] < 10;                          // visited, deep inside: nothing
    const bool wallCore = tg && tp(128, 100)[3] == 255 && tp(128, 100)[0] == 255 && tp(128, 100)[2] > 200;  // cream
    const bool seaClear = tg && tp(60, 245)[3] == 0;                                // the sea: no fill
    const bool fogBase = tf && tf[(100 * 256 + 200) * 3] == 0x10 && tf[(100 * 256 + 200) * 3 + 2] == 0x30;   // fog colour
    const bool badState = compose_territories("/tmp/terr_labels.png", "1:x:FF0000", "", "", "/tmp/terr_bad.png", "", "", 64) != "";
    const bool terrOk = lockedFill && rimNearEdge && visitedClear && wallCore && seaClear && fogBase && badState;
    std::printf("%s territories: %s, locked %d/a%d, rim a%d, visited a%d, wall %d,%d,%d a%d, sea a%d\n", terrOk ? "ok" : "FAIL",
                terr.empty() ? "written" : terr.c_str(), tg ? tp(40, 100)[0] : -1, tg ? tp(40, 100)[3] : -1, tg ? tp(40, 223)[3] : -1,
                tg ? tp(200, 100)[3] : -1, tg ? tp(128, 100)[0] : -1, tg ? tp(128, 100)[1] : -1, tg ? tp(128, 100)[2] : -1,
                tg ? tp(128, 100)[3] : -1, tg ? tp(60, 245)[3] : -1);
    return terrOk ? 0 : 1;
}
