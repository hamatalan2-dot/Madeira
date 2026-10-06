#!/bin/bash
set -e

# Exit on error
error() {
    echo "Error: $1" >&2
    exit 1
}

# Verify required environment variables
[[ -n "$DEVELOPER_DIR" ]] || error "DEVELOPER_DIR not set"
[[ -n "$SDKROOT" ]] || error "SDKROOT not set"

# Print build configuration
echo "Building Madeira IPA..."
echo "DEVELOPER_DIR=$DEVELOPER_DIR"
echo "SDKROOT=$SDKROOT"
echo "MADEIRA_BUILD_I386=$MADEIRA_BUILD_I386"

# 1. Build GnuTLS iOS
echo "=== Building GnuTLS iOS ==="
bash build/gnutls-ios/build.sh

# 2. Build FFmpeg iOS
echo "=== Building FFmpeg iOS ==="
bash build/ffmpeg/build.sh

# 3. Build FEX iOS
echo "=== Building FEX iOS ==="
bash build/fex-ios/build.sh

# 4. Build FEX ARM64EC (for WoW64 if needed)
if [[ "$MADEIRA_BUILD_I386" == "1" ]]; then
    echo "=== Building FEX ARM64EC ==="
    bash build/fex-arm64ec/build.sh
fi

# 5. Build Wine unix side
echo "=== Building Wine unix libraries ==="
bash build/ntdll-unix/build.sh
bash build/wineserver/build.sh
bash build/win32u-unix/build.sh

# 6. Build Wine PE (ARM64EC)
echo "=== Building Wine PE (ARM64EC) ==="
bash build/wine-pe/build-ntdll.sh

# 7. Build DXMT unix side
echo "=== Building DXMT unix side ==="
bash build/dxmt-ios/build.sh

# 8. Build DXMT PE side
echo "=== Building DXMT PE side ==="
cd dxmt
meson setup build-arm64ec -Dbuildtype=release -Dwine_build_path=../../wine/build-arm64ec --cross-file=build-arm64ec-win.txt || true
ninja -C build-arm64ec src/win32/dxmt.dll.p/d3d11.c.o 2>&1 | head -20 || true
cd ..

# 9. Build madeira-d3d12 (D3D12 runtime)
echo "=== Building madeira-d3d12 ==="
bash build/madeira-d3d12/build-pe.sh

# 10. Build Wine i386 (32-bit WoW64) if enabled
if [[ "$MADEIRA_BUILD_I386" == "1" ]]; then
    echo "=== Building Wine i386 ==="
    bash build/wine-i386/build.sh
    
    echo "=== Building FEX WoW64 ==="
    bash build/fex-wow64/build.sh
fi

# 11. Build the Xcode app
echo "=== Building Madeira iOS app ==="
xcodebuild -project app/Madeira.xcodeproj -scheme Madeira \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build

echo "Build complete!"
