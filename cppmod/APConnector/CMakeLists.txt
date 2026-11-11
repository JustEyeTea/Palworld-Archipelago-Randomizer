# APConnector, built inside a UE4SS source tree (see ../CMakeLists.txt). AP_DEPS points at the header-only
# dependencies: apclientpp, wswrap, and asio / websocketpp / json as vendored by ap-soeclient.
cmake_minimum_required(VERSION 3.22)
set(TARGET APConnector)
project(${TARGET})

add_library(${TARGET} SHARED src/dllmain.cpp src/ap_bridge.cpp src/image_tools.cpp src/lua_text.cpp src/pal_gift.cpp
    src/pal_gift_logic.cpp src/map_screen.cpp)
target_include_directories(${TARGET} PRIVATE
    ${AP_DEPS}/apclientpp
    ${AP_DEPS}/wswrap/include
    ${AP_DEPS}/ap-soeclient/subprojects/asio/include
    ${AP_DEPS}/ap-soeclient/subprojects/websocketpp
    ${AP_DEPS}/ap-soeclient/subprojects/json/include
    third_party/stb)
target_compile_definitions(${TARGET} PRIVATE ASIO_STANDALONE AP_NO_SCHEMA _WIN32_WINNT=0x0A00)
# asio and Windows.h only meet in ap_bridge.cpp; apclientpp asks for a lean Windows.h there.
set_source_files_properties(src/ap_bridge.cpp PROPERTIES COMPILE_DEFINITIONS "WIN32_LEAN_AND_MEAN")
target_compile_options(${TARGET} PRIVATE /Zc:__cplusplus /bigobj)

find_package(OpenSSL REQUIRED)
find_package(ZLIB REQUIRED)
target_link_libraries(${TARGET} PUBLIC UE4SS OpenSSL::SSL OpenSSL::Crypto ZLIB::ZLIB crypt32 ws2_32)
