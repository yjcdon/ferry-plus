#!/bin/bash
# 用本机 Swift 工具链生成可直接运行的 arm64 App；不依赖完整 Xcode。
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
package_dir="$repo_dir/Packages/FerryKit"
build_dir="$repo_dir/.build"
app_dir="$build_dir/Ferry Plus.app"
# 本项目本机使用 Command Line Tools + 26.5 SDK；完整 Xcode 环境可显式指定其他 SDK。
sdk_dir="$(xcrun --sdk "${FERRY_MACOS_SDK:-macosx26.5}" --show-sdk-path)"

swift build --package-path "$package_dir" --build-system native --sdk "$sdk_dir" --configuration debug --jobs 4
package_bin="$(swift build --package-path "$package_dir" --build-system native --sdk "$sdk_dir" --configuration debug --show-bin-path)"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"

objects=()
for module in BaiduKit QuarkKit DownloadKit FerryCore; do
    for object in "$package_bin/$module.build/"*.swift.o; do
        objects+=("$object")
    done
done

swiftc -swift-version 6 -parse-as-library -D DEBUG \
    -default-isolation MainActor \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -enable-upcoming-feature InferIsolatedConformances \
    -target arm64-apple-macos14.0 -sdk "$sdk_dir" \
    -I "$package_bin/Modules" \
    "$repo_dir/BaiduPCS-Swift/"*.swift "${objects[@]}" \
    -o "$app_dir/Contents/MacOS/Ferry Plus"

cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>io.github.yjcdon.FerryPlus</string>
    <key>CFBundleName</key><string>Ferry Plus</string>
    <key>CFBundleDisplayName</key><string>Ferry Plus</string>
    <key>CFBundleExecutable</key><string>Ferry Plus</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST

# 现有各尺寸图标原样打包，无需资源目录编译器。
iconset_dir="$build_dir/AppIcon.iconset"
mkdir -p "$iconset_dir"
icon_source="$repo_dir/BaiduPCS-Swift/Assets.xcassets/AppIcon.appiconset"
for entry in "16:16x16" "32:16x16@2x" "32:32x32" "64:32x32@2x" \
    "128:128x128" "256:128x128@2x" "256:256x256" "512:256x256@2x" \
    "512:512x512" "1024:512x512@2x"; do
    cp "$icon_source/icon_${entry%%:*}.png" "$iconset_dir/icon_${entry#*:}.png"
done
iconutil -c icns "$iconset_dir" -o "$app_dir/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier io.github.yjcdon.FerryPlus \
    --entitlements "$repo_dir/BaiduPCS-Swift/BaiduPCS-Swift.entitlements" "$app_dir"
codesign --verify --strict "$app_dir"
printf '%s\n' "$app_dir"
