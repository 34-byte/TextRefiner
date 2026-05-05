#!/bin/bash
#
# build.sh — Compiles TextRefiner and packages it into a macOS .app bundle.
#
# Usage:
#   ./build.sh             Build for development (ad-hoc sign, TCC reset, dev bundle ID)
#   ./build.sh dev         Same as above
#   ./build.sh diagnostic  Same as dev, but compiles with -DDEBUG so every `#if DEBUG`
#                          print statement is included. Use when reproducing bugs that
#                          need Terminal log output (e.g. TypingMonitor AX diagnostics).
#   ./build.sh release     Build for distribution (ad-hoc sign, no TCC reset, prod bundle ID,
#                          creates .zip + Sparkle EdDSA signature for appcast)
#
# Dev mode:
#   - Uses Info-Dev.plist (bundle ID: com.textrefiner.app.dev, no Sparkle appcast)
#   - Ad-hoc signed, TCC reset after build (new binary hash each time)
#   - App skips onboarding in DEBUG builds — just re-grant Accessibility when prompted
#   - For local development only
#
# Release mode:
#   - Uses Info.plist (bundle ID: com.textrefiner.app, Sparkle appcast configured)
#   - Ad-hoc signed, NO TCC reset (end-user machine)
#   - Creates a .zip for Sparkle distribution
#   - Signs the .zip with Sparkle's EdDSA tool and prints signature for appcast.xml

set -e

MODE="${1:-dev}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="TextRefiner"
BUILD_DIR="$SCRIPT_DIR/.build"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

SIGN_ID="-"

echo "==> Building $APP_NAME (mode: $MODE)..."
cd "$SCRIPT_DIR"

# Use Xcode's Swift toolchain if available (required for mlx-swift-lm >= 2.31.3
# which needs Swift Tools 6.1+; Command Line Tools ships an older toolchain).
if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

if [ "$MODE" = "diagnostic" ]; then
    # Inject DEBUG flag into release-configured build so `#if DEBUG` print
    # statements compile in. Still builds in release configuration so the
    # rest of the bundling pipeline (paths under .build/release) works unchanged.
    swift build -c release -Xswiftc -D -Xswiftc DEBUG 2>&1
else
    swift build -c release 2>&1
fi

# Find the built binary
BINARY="$BUILD_DIR/release/$APP_NAME"
if [ ! -f "$BINARY" ]; then
    # Try the platform-specific path
    BINARY=$(find "$BUILD_DIR" -name "$APP_NAME" -type f -path "*/release/*" | head -1)
fi

if [ ! -f "$BINARY" ]; then
    echo "ERROR: Could not find built binary"
    exit 1
fi

echo "==> Creating app bundle..."

# Clean previous bundle
rm -rf "$APP_BUNDLE"

# Create bundle structure
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Copy binary and fix rpath so it finds frameworks in Contents/Frameworks/
cp "$BINARY" "$MACOS_DIR/$APP_NAME"
install_name_tool -add_rpath @executable_path/../Frameworks "$MACOS_DIR/$APP_NAME" 2>/dev/null || true

# Copy the appropriate Info.plist based on build mode
if [ "$MODE" = "release" ]; then
    cp "$SCRIPT_DIR/Resources/Info.plist" "$CONTENTS/Info.plist"
else
    # Dev and diagnostic modes: use Info-Dev.plist if it exists, otherwise fall back to Info.plist
    if [ -f "$SCRIPT_DIR/Resources/Info-Dev.plist" ]; then
        cp "$SCRIPT_DIR/Resources/Info-Dev.plist" "$CONTENTS/Info.plist"
    else
        cp "$SCRIPT_DIR/Resources/Info.plist" "$CONTENTS/Info.plist"
    fi
fi

# Copy entitlements (not into bundle, but we need it for signing)
ENTITLEMENTS="$SCRIPT_DIR/Resources/TextRefiner.entitlements"

# --- Icon ---
# Convert Resources/AppIcon.png → AppIcon.icns using sips + iconutil
# (both ship with macOS — no Homebrew needed)
SOURCE_ICON="$SCRIPT_DIR/Resources/AppIcon.png"
ICONSET_DIR="$SCRIPT_DIR/.build/AppIcon.iconset"
ICNS_OUT="$RESOURCES_DIR/AppIcon.icns"

if [ -f "$SOURCE_ICON" ]; then
    echo "==> Generating AppIcon.icns from AppIcon.png..."
    rm -rf "$ICONSET_DIR"
    mkdir -p "$ICONSET_DIR"

    # macOS requires these exact filenames inside the .iconset folder.
    # sips resizes the source PNG to each required dimension.
    sips -z 16   16   "$SOURCE_ICON" --out "$ICONSET_DIR/icon_16x16.png"       > /dev/null 2>&1
    sips -z 32   32   "$SOURCE_ICON" --out "$ICONSET_DIR/icon_16x16@2x.png"    > /dev/null 2>&1
    sips -z 32   32   "$SOURCE_ICON" --out "$ICONSET_DIR/icon_32x32.png"       > /dev/null 2>&1
    sips -z 64   64   "$SOURCE_ICON" --out "$ICONSET_DIR/icon_32x32@2x.png"    > /dev/null 2>&1
    sips -z 128  128  "$SOURCE_ICON" --out "$ICONSET_DIR/icon_128x128.png"     > /dev/null 2>&1
    sips -z 256  256  "$SOURCE_ICON" --out "$ICONSET_DIR/icon_128x128@2x.png"  > /dev/null 2>&1
    sips -z 256  256  "$SOURCE_ICON" --out "$ICONSET_DIR/icon_256x256.png"     > /dev/null 2>&1
    sips -z 512  512  "$SOURCE_ICON" --out "$ICONSET_DIR/icon_256x256@2x.png"  > /dev/null 2>&1
    sips -z 512  512  "$SOURCE_ICON" --out "$ICONSET_DIR/icon_512x512.png"     > /dev/null 2>&1
    sips -z 1024 1024 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_512x512@2x.png"  > /dev/null 2>&1

    # iconutil compiles the folder into a proper .icns file
    iconutil -c icns "$ICONSET_DIR" -o "$ICNS_OUT"
    rm -rf "$ICONSET_DIR"
    echo "    icon_ok"
else
    echo "    (skipped — Resources/AppIcon.png not found)"
fi

# --- Compile MLX Metal shaders into default.metallib ---
# SPM cannot compile .metal files — we must do it manually.
# MLX looks for mlx.metallib colocated with the binary at runtime.
METAL_SRC_DIR="$BUILD_DIR/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
AIR_DIR="$BUILD_DIR/mlx_air"
METALLIB_OUT="$MACOS_DIR/mlx.metallib"

if [ -d "$METAL_SRC_DIR" ]; then
    echo "==> Compiling MLX Metal shaders..."
    rm -rf "$AIR_DIR"
    mkdir -p "$AIR_DIR"

    find "$METAL_SRC_DIR" -name "*.metal" -print0 | while IFS= read -r -d '' METAL_FILE; do
        BASENAME=$(basename "$METAL_FILE" .metal)
        xcrun -sdk macosx metal -c "$METAL_FILE" \
            -I "$METAL_SRC_DIR" \
            -I "$METAL_SRC_DIR/steel" \
            -I "$METAL_SRC_DIR/steel/gemm" \
            -I "$METAL_SRC_DIR/steel/attn" \
            -I "$METAL_SRC_DIR/steel/attn/kernels" \
            -I "$METAL_SRC_DIR/steel/conv" \
            -I "$METAL_SRC_DIR/steel/utils" \
            -I "$METAL_SRC_DIR/fft" \
            -std=metal3.1 \
            -mmacosx-version-min=15.0 \
            -o "$AIR_DIR/$BASENAME.air" 2>/dev/null
    done

    xcrun -sdk macosx metallib "$AIR_DIR"/*.air -o "$METALLIB_OUT" 2>/dev/null
    rm -rf "$AIR_DIR"
    echo "    metallib_ok ($(du -h "$METALLIB_OUT" | cut -f1 | xargs))"
else
    echo "WARNING: MLX Metal sources not found — model inference will fail at runtime"
fi

# --- Copy SPM resource bundles (tokenizer configs, etc.) ---
echo "==> Copying resource bundles..."
for BUNDLE_PATH in "$BUILD_DIR/arm64-apple-macosx/release/"*.bundle; do
    if [ -d "$BUNDLE_PATH" ]; then
        BUNDLE_NAME=$(basename "$BUNDLE_PATH")
        cp -a "$BUNDLE_PATH" "$RESOURCES_DIR/$BUNDLE_NAME"
        echo "    $BUNDLE_NAME"
    fi
done

# --- Copy audio feedback files ---
echo "==> Copying audio files..."
cp "$SCRIPT_DIR/Success_Sound.mp3" "$RESOURCES_DIR/"
cp "$SCRIPT_DIR/Fail_sound.mov" "$RESOURCES_DIR/"

# --- Embed Sparkle.framework ---
FRAMEWORKS_DIR="$CONTENTS/Frameworks"
SPARKLE_SOURCE="$BUILD_DIR/arm64-apple-macosx/release/Sparkle.framework"
if [ ! -d "$SPARKLE_SOURCE" ]; then
    # Fallback to xcframework artifact
    SPARKLE_SOURCE="$BUILD_DIR/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
fi

if [ -d "$SPARKLE_SOURCE" ]; then
    echo "==> Embedding Sparkle.framework..."
    mkdir -p "$FRAMEWORKS_DIR"
    cp -a "$SPARKLE_SOURCE" "$FRAMEWORKS_DIR/"
else
    echo "WARNING: Sparkle.framework not found — app will crash on launch if it links Sparkle"
fi

# Strip extended attributes and ensure all files are writable before signing.
# Must happen BEFORE any codesign calls — iCloud Drive adds resource-fork detritus
# (._AppleDouble files + xattrs) that codesign rejects, and read-only SPM bundle
# files block xattr from running.
echo "==> Cleaning bundle attributes..."
chmod -R u+w "$APP_BUNDLE"
# dot_clean merges AppleDouble (._*) fork data and removes the stub files.
dot_clean -m "$APP_BUNDLE"
xattr -cr "$APP_BUNDLE"

echo "==> Signing with ad-hoc signature..."
# Sign sub-components first, then the outer app bundle.
if [ -f "$METALLIB_OUT" ]; then
    codesign --force --sign "$SIGN_ID" "$METALLIB_OUT"
fi
if [ -d "$FRAMEWORKS_DIR/Sparkle.framework" ]; then
    codesign --force --sign "$SIGN_ID" "$FRAMEWORKS_DIR/Sparkle.framework"
    echo "    sparkle_ok"
fi
codesign --force --sign "$SIGN_ID" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"

if [ "$MODE" = "release" ]; then
    # Release mode: create distributable .zip and sign with Sparkle EdDSA
    echo ""
    echo "==> Release build — creating distribution archive..."

    # Read version from Info.plist for the zip filename
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$CONTENTS/Info.plist" 2>/dev/null || echo "unknown")
    ZIP_NAME="${APP_NAME}-${VERSION}.zip"
    ZIP_PATH="$SCRIPT_DIR/$ZIP_NAME"

    # Create zip using ditto (preserves macOS metadata)
    rm -f "$ZIP_PATH"
    ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"
    echo "    Created: $ZIP_NAME"

    # Sign with Sparkle EdDSA if the tool exists
    SIGN_TOOL="$BUILD_DIR/artifacts/sparkle/Sparkle/bin/sign_update"
    if [ -f "$SIGN_TOOL" ]; then
        echo ""
        echo "==> Signing update with Sparkle EdDSA..."
        # Run sign_update in a subshell so a missing keychain key doesn't abort the build.
        SIGNATURE_OUTPUT=$("$SIGN_TOOL" "$ZIP_PATH" 2>&1) && {
            echo "$SIGNATURE_OUTPUT"
            echo ""
            echo "Copy the sparkle:edSignature and length values above into your appcast.xml"
        } || {
            echo "WARNING: EdDSA signing failed — private key not found in Keychain."
            echo "  To sign manually: $SIGN_TOOL $ZIP_PATH"
            echo "  Or import the key first: $BUILD_DIR/artifacts/sparkle/Sparkle/bin/generate_keys"
        }
    else
        echo ""
        echo "NOTE: Sparkle sign_update tool not found at $SIGN_TOOL"
        echo "Run 'swift package resolve' first, then find the tool in .build/artifacts/"
    fi

    echo ""
    echo "==> Release build complete!"
    echo ""
    echo "Next steps:"
    echo "  1. Create a GitHub Release (tag v${VERSION})"
    echo "  2. Upload $ZIP_NAME to the release"
    echo "  3. Update appcast.xml with version, signature, and download URL"
    echo "  4. Push appcast.xml to main"
    echo ""
    echo "IMPORTANT: You are now running the release build (com.textrefiner.app)."
    echo "Run './build.sh' to return to the dev build before continuing development."
else
    # Dev mode: reset TCC (ad-hoc signing = new hash each rebuild)
    #
    # WHY we reset Accessibility on every dev build:
    # Ad-hoc signing (--sign -) creates a unique identity derived from the binary hash.
    # Every rebuild produces a NEW hash → macOS TCC treats it as a completely different app.
    # The old "ON" toggle in System Settings references the previous binary's hash — it looks
    # granted but isn't (the new binary is unknown to TCC). This causes the confusing state
    # the user sees: toggle ON, but app reports "permission denied".
    #
    # Resetting here clears the stale entry. After the app launches, the user sees the toggle
    # as OFF, toggles it ON, and macOS registers the CURRENT binary hash. This is reliable.
    BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$CONTENTS/Info.plist" 2>/dev/null || echo "com.textrefiner.app")
    echo "==> Resetting Accessibility permission (new binary hash after rebuild)..."
    tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
fi

echo ""
echo "==> Done! Built: $APP_BUNDLE"
echo ""
echo "To run:"
echo "  open \"$APP_BUNDLE\""
