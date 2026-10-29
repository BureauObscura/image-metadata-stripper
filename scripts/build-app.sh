#!/bin/bash

set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
OUTPUT_PATH="${1:-$PROJECT_DIRECTORY/dist/Image Metadata Stripper.app}"
BUNDLE_IDENTIFIER="com.nicholaszaggy.image-metadata-stripper"

if [[ "$OUTPUT_PATH" != *.app ]]; then
    echo "The output path must end in .app." >&2
    exit 2
fi

OUTPUT_PARENT="$(dirname "$OUTPUT_PATH")"
mkdir -p "$OUTPUT_PARENT"

if [[ -L "$OUTPUT_PATH" ]]; then
    echo "Refusing to replace an app symlink: $OUTPUT_PATH" >&2
    exit 1
fi
if [[ -e "$OUTPUT_PATH" ]]; then
    if [[ ! -d "$OUTPUT_PATH" ]]; then
        echo "Refusing to replace a non-directory: $OUTPUT_PATH" >&2
        exit 1
    fi
    EXISTING_IDENTIFIER="$(plutil -extract CFBundleIdentifier raw "$OUTPUT_PATH/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$EXISTING_IDENTIFIER" != "$BUNDLE_IDENTIFIER" ]]; then
        echo "Refusing to replace a different app: $OUTPUT_PATH" >&2
        exit 1
    fi
fi

BUILD_ROOT="$PROJECT_DIRECTORY/.build"
MODULE_CACHE="$BUILD_ROOT/module-cache"
mkdir -p "$MODULE_CACHE"

env \
    CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
    SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" \
    swift build \
        --disable-sandbox \
        --configuration release \
        --package-path "$PROJECT_DIRECTORY" \
        --scratch-path "$BUILD_ROOT"

BIN_DIRECTORY="$(env \
    CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
    SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" \
    swift build \
        --disable-sandbox \
        --configuration release \
        --package-path "$PROJECT_DIRECTORY" \
        --scratch-path "$BUILD_ROOT" \
        --show-bin-path)"

WORK_DIRECTORY="$(mktemp -d "$OUTPUT_PARENT/.image-metadata-stripper-build.XXXXXX")"
trap 'rm -rf "$WORK_DIRECTORY"' EXIT

BUNDLE="$WORK_DIRECTORY/Image Metadata Stripper.app"
CONTENTS="$BUNDLE/Contents"
MACOS_DIRECTORY="$CONTENTS/MacOS"
RESOURCES_DIRECTORY="$CONTENTS/Resources"
mkdir -p "$MACOS_DIRECTORY" "$RESOURCES_DIRECTORY"

cp "$BIN_DIRECTORY/ImageMetadataStripper" "$MACOS_DIRECTORY/ImageMetadataStripper"
cp "$PROJECT_DIRECTORY/Resources/Info.plist" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

ICON_RENDERER="$WORK_DIRECTORY/generate-icon"
xcrun swiftc \
    "$PROJECT_DIRECTORY/scripts/generate-icon.swift" \
    -o "$ICON_RENDERER" \
    -framework AppKit \
    -module-cache-path "$WORK_DIRECTORY/icon-module-cache"
"$ICON_RENDERER" "$RESOURCES_DIRECTORY/AppIcon.icns"

codesign \
    --force \
    --sign - \
    --entitlements "$PROJECT_DIRECTORY/Resources/MetadataStripper.entitlements" \
    "$BUNDLE"
codesign --verify --deep --strict "$BUNDLE"

BACKUP="$WORK_DIRECTORY/previous.app"
if [[ -e "$OUTPUT_PATH" ]]; then
    mv "$OUTPUT_PATH" "$BACKUP"
fi
if ! mv "$BUNDLE" "$OUTPUT_PATH"; then
    if [[ -e "$BACKUP" ]]; then
        mv "$BACKUP" "$OUTPUT_PATH"
    fi
    exit 1
fi

echo "Built $OUTPUT_PATH"
