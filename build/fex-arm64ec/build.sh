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

# Remove the old build directory.
rm -rf "$B"

# Configure FEX for ARM64EC.
cmake -G Ninja -S "$R/FEX" -B "$B" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="$R/FEX/Data/CMake/toolchain_mingw.cmake" \
    -DMINGW_TRIPLE=arm64ec-w64-mingw32 \
    -DTUNE_CPU=none \
    -DENABLE_LTO=OFF \
    -DENABLE_FEX_ALLOCATOR=ON \
    -DENABLE_JEMALLOC_GLIBC_ALLOC=OFF \
    -DENABLE_OFFLINE_RUNTIME=ON \
    -DBUILD_FEXCONFIG=ON \
    -DENABLE_CLANG_THUNKS=ON \
    -DENABLE_CCACHE=ON \
    -DBUILD_TESTING=OFF \
    -DBUILD_THUNKS=OFF \
    -DENABLE_ASSERTIONS=OFF

# Build the default target instead of the nonexistent arm64ecfex target.
cmake --build "$B" --parallel 2

# Inspect the produced DLL before copying it.
find "$B" -type f -name '*.dll' -print

mkdir -p "$R/app/Madeira/arm64ec-windows"

cp "$B/Bin/libarm64ecfex.dll" \
   "$R/app/Madeira/arm64ec-windows/xtajit64.dll"

ls -lh "$R/app/Madeira/arm64ec-windows/xtajit64.dll"