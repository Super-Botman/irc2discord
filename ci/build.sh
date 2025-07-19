#!/bin/bash

set -e

PROJECT_NAME="irc2discord"
BUILD_DIR="release"
ZIG_VERSION="0.15.0-dev.1092+d772c0627"

echo "Installing Zig"

wget "https://ziglang.org/builds/zig-x86_64-linux-$ZIG_VERSION.tar.xz"
tar xf "zig-x86_64-linux-$ZIG_VERSION.tar.xz"
export PATH="$HOME/zig-x86_64-linux-$ZIG_VERSION:$PATH"

echo "Checking Zig installation"
zig version

echo "Building $PROJECT_NAME"

# Create releases directory
mkdir -p "$BUILD_DIR"

# Define target platforms
declare -A TARGETS=(
    ["linux-x86_64"]="x86_64-linux"
    ["linux-aarch64"]="aarch64-linux"
)

# Build for each target
for platform in "${!TARGETS[@]}"; do
    target="${TARGETS[$platform]}"
    echo "Building for $platform ($target)..."
    
    # Set binary name with platform suffix
    if [[ $platform == *"windows"* ]]; then
        binary_name="${PROJECT_NAME}-${platform}.exe"
    else
        binary_name="${PROJECT_NAME}-${platform}"
    fi
    
    # Build with zig, continue on failure
    if zig build -Dtarget="$target" -Doptimize=ReleaseFast 2>/dev/null; then
        # Copy binary to releases directory with platform-specific name
        if [[ $platform == *"windows"* ]]; then
            cp "zig-out/bin/${PROJECT_NAME}.exe" "$BUILD_DIR/$binary_name" 2>/dev/null || echo "⚠ Failed to copy $binary_name"
        else
            cp "zig-out/bin/$PROJECT_NAME" "$BUILD_DIR/$binary_name" 2>/dev/null || echo "⚠ Failed to copy $binary_name"
        fi
        echo "✓ Built $binary_name"
    else
        echo "✗ Failed to build $binary_name (dependency/cross-compilation issues)"
    fi
    
    # Clean build directory for next target
    rm -rf zig-out 2>/dev/null || true
done

echo ""
echo "Build summary - Binaries in the '$BUILD_DIR' directory:"
ls -la "$BUILD_DIR" 2>/dev/null || echo "No successful builds"
