# Guitar Hero III: Legends of Rock (BLUS30074, Neversoft/Activision) -- PPU boot
# harness on the shared ps3recomp runtime.
#
# Picked over Rock Band 3 on measurement, not taste: RB3 is 32,128 functions
# with 104 SPU markers, because Harmonix runs Sony's MultiStream (cellMS*)
# audio middleware on the SPUs -- and in a rhythm game the audio path is the
# critical path, which is the same shape that has Virtua Fighter 5 and Tokyo
# Jungle stuck. GH3 is 28,987 functions with 7 SPU markers and an 18-library
# import surface the runtime already covers.
#
# Toolchain: clang-cl (the harness uses __builtin_bswap + weak symbols MSVC lacks).
#   cmake -S . -B build -G Ninja -DCMAKE_C_COMPILER=clang-cl -DCMAKE_CXX_COMPILER=clang-cl
#   cmake --build build
#   RSX_LIVE_DRAW=1 ./build/gh3 vfs/PS3_GAME/USRDIR/EBOOT.elf
cmake_minimum_required(VERSION 3.20)

# Default to Release: a recompiled title is ~193 MB of generated C++, and
# CMake+Ninja pick Debug when no type is given (/Od /Ob0 /RTC1). Simpsons
# measured 16 fps that way against 49 fps at /O2, invisibly.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "build type" FORCE)
endif()
message(STATUS "build type: ${CMAKE_BUILD_TYPE}")

project(gh3 CXX C)
# Release must actually optimise: the build cache here holds empty
# CMAKE_{C,CXX}_FLAGS_RELEASE, and clang-cl with no /O flag is /Od, so the
# lifted code ran unoptimised (GH3 gameplay ~13 fps). The runtime's own
# semantics flags come along: lifted code does type-punned guest memory access
# and must not grow FMAs the PPU/SPU did not have.
add_compile_options($<$<CONFIG:Release,RelWithDebInfo>:-O2> -fno-strict-aliasing -ffp-contract=off -msse4.1)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_C_STANDARD 17)

set(PS3RECOMP_DIR "G:/recomp/ps3" CACHE PATH "ps3recomp repo root")
set(PS3RECOMP_RUNTIME_LIB "${PS3RECOMP_DIR}/build-gate/ps3recomp_runtime.lib"
    CACHE FILEPATH "prebuilt runtime library")

# Lifted game code + generated HLE NID table (both git-ignored; tools/relift.sh).
file(GLOB RECOMP_SOURCES "src/recomp/*.cpp")
file(GLOB GEN_SOURCES    "src/gen/*.cpp" "src/gen/*.c")
# The title's five SPU images, lifted. These are ordinary embedded ELFs in the
# EBOOT (extract_spu_images.py finds them), not raw blobs needing an
# SPU_DUMP_MISS capture run -- and GH3 runs them as SPURS *tasks*, which is a
# different path from job-chain dispatch. src/spu_gen/spu_workloads.c registers
# them with the runtime's fingerprint registry from a constructor.
file(GLOB_RECURSE SPU_SOURCES "src/spu_gen/*.c")
if(NOT RECOMP_SOURCES)
    message(FATAL_ERROR "src/recomp/ is empty -- run tools/relift.sh first")
endif()

add_executable(gh3
    "${PS3RECOMP_DIR}/runtime/ppu/tests/boot_main.cpp"   # generic boot harness
    "${PS3RECOMP_DIR}/runtime/ppu/ppu_loader.cpp"        # vm + ELF loader + run
    "${PS3RECOMP_DIR}/runtime/ppu/ppu_hle.cpp"           # NID -> handler dispatch
    "${PS3RECOMP_DIR}/runtime/ppu/ppu_sysprx.cpp"        # boot-critical CRT
    "${PS3RECOMP_DIR}/runtime/ppu/ppu_fs.cpp"            # cellFs VFS
    ${GEN_SOURCES}
    ${SPU_SOURCES}
    ${RECOMP_SOURCES}
)

file(GLOB LIB_INC_DIRS LIST_DIRECTORIES true "${PS3RECOMP_DIR}/libs/*")
target_include_directories(gh3 PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/src/compat"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/recomp"
    "${PS3RECOMP_DIR}/runtime/ppu"
    "${PS3RECOMP_DIR}/runtime/spu"
    "${PS3RECOMP_DIR}/runtime/prx"
    "${PS3RECOMP_DIR}/include"
    ${LIB_INC_DIRS}
)

target_link_libraries(gh3 PRIVATE "${PS3RECOMP_RUNTIME_LIB}")
if(WIN32)
    target_link_libraries(gh3 PRIVATE ws2_32 bcrypt xinput ole32 d3d12 dxgi dxguid d3dcompiler)
    # Every guest call is a host call, so recompiled call chains nest deeply.
    target_link_options(gh3 PRIVATE /STACK:268435456 /MAP:gh3.map)
endif()
