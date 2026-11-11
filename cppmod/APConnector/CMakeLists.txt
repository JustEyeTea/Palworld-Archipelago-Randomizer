# APConnector, built inside a UE4SS source tree (see ../CMakeLists.txt). AP_DEPS points at the header-only
# dependencies: apclientpp, wswrap, and asio / websocketpp / json as vendored by ap-soeclient.
cmake_minimum_required(VERSION 3.22)
set(TARGET APConnector)
project(${TARGET})

add_library(${TARGET} SHARED src/dllmain.cpp src/ap_bridge.cpp src/event_lines.cpp src/image_tools.cpp src/lua_text.cpp
    src/pal_gift.cpp src/pal_gift_logic.cpp src/map_screen.cpp)
# The same defines and include paths are in tools/bridge_test.sh (its Linux build of the bridge); change both.
target_include_directories(${TARGET} PRIVATE
    ${AP_DEPS}/apclientpp
    ${AP_DEPS}/wswrap/include
    ${AP_DEPS}/ap-soeclient/subprojects/asio/include
    ${AP_DEPS}/ap-soeclient/subprojects/websocketpp
    ${AP_DEPS}/ap-soeclient/subprojects/json/include
    third_party/stb)
# ASIO_STANDALONE: asio without Boost, as wswrap and websocketpp use it. AP_NO_SCHEMA: apclientpp skips checking
# the server's packets against its JSON schema, which would need the valijson library too. _WIN32_WINNT=0x0A00: the
# Windows version asio builds for (Windows 10); asio asks for it to be set.
target_compile_definitions(${TARGET} PRIVATE ASIO_STANDALONE AP_NO_SCHEMA _WIN32_WINNT=0x0A00)
# asio and Windows.h only meet in ap_bridge.cpp; apclientpp asks for a lean Windows.h there.
set_source_files_properties(src/ap_bridge.cpp PROPERTIES COMPILE_DEFINITIONS "WIN32_LEAN_AND_MEAN")
# /Zc:__cplusplus: MSVC then reports the real C++ version in __cplusplus (else 199711), which the json and asio
# headers read to choose what to use. /bigobj: ap_bridge.cpp (asio, websocketpp and json in one file) has more
# sections than an object file holds by default.
target_compile_options(${TARGET} PRIVATE /Zc:__cplusplus /bigobj)

find_package(OpenSSL REQUIRED)
find_package(ZLIB REQUIRED)
# crypt32 and ws2_32: a static OpenSSL needs both (Windows' certificate functions and Winsock), and asio's sockets
# need ws2_32.
target_link_libraries(${TARGET} PUBLIC UE4SS OpenSSL::SSL OpenSSL::Crypto ZLIB::ZLIB crypt32 ws2_32)
