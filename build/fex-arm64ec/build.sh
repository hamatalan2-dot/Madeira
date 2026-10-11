#!/bin/bash
set -eu

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

TOOLCHAIN="$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal"
B="$R/FEX/build-arm64ec"

export PATH="$TOOLCHAIN/bin:$PATH"

# Verify the cross-compiler exists.
CC="$TOOLCHAIN/bin/aarch64-w64-mingw32-clang"
CXX="$TOOLCHAIN/bin/aarch64-w64-mingw32-clang++"

test -x "$CC" || {
    echo "ERROR: ARM64 MinGW clang not found: $CC"
    exit 1
}

test -x "$CXX" || {
    echo "ERROR: ARM64 MinGW clang++ not found: $CXX"
    exit 1
}

# Remove the old CMake cache so the corrected compiler settings take effect.
rm -rf "$B"

cmake -S "$R/FEX" -B "$B" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="$R/FEX/Data/CMake/toolchain_mingw.cmake" \
    -DMINGW_TRIPLE=aarch64-w64-mingw32 \
    -DTUNE_CPU=none \
    -DENABLE_FEX_ALLOCATOR=ON \
    -DENABLE_JEMALLOC_GLIBC_ALLOC=ON \
    -DENABLE_OFFLINE_RUNTIME=ON \
    -DBUILD_FEXCONFIG=ON \
    -DENABLE_CLANG_THUNKS=ON \
    -DENABLE_CCACHE=ON \
    -DBUILD_TESTING=OFF \
    -DBUILD_THUNKS=OFF \
    -DENABLE_LTO=OFF \
    -DENABLE_ASSERTIONS=OFF
    

cmake --build "$B" --target arm64ecfex

mkdir -p "$R/app/Madeira/arm64ec-windows"

cp "$B/Bin/libarm64ecfex.dll" \
   "$R/app/Madeira/arm64ec-windows/xtajit64.dll"

ls -lh "$R/app/Madeira/arm64ec-windows/xtajit64.dll"