# Builds the C++ part of the mod against the exact UE4SS the game runs: Okaetsu's Palworld build, at the commit
# UE4SS_COMMIT in .github/workflows/ci.yml, cloned into cppmod/RE-UE4SS by the CI job (its Unreal headers come from a
# private, Epic-linked repository, so the clone is never committed here). See ci.yml for the full recipe.
cmake_minimum_required(VERSION 3.22)
project(PalworldArchipelagoMods)

add_subdirectory(RE-UE4SS)
add_subdirectory(APConnector)
