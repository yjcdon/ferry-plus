#!/bin/bash
# 将已构建的 arm64 App 打包为 ZIP，并生成可直接校验的 SHA-256 文件。
set -euo pipefail

if [ "$#" -gt 1 ]; then
    printf '%s\n' '用法：bash Scripts/package-app.sh [App 路径]' >&2
    exit 64
fi

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="${1:-$repo_dir/.build/Ferry Plus.app}"
plist="$app_dir/Contents/Info.plist"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")"

if [ "$bundle_id" != io.github.yjcdon.FerryPlus ]; then
    printf '%s\n' '所选 App 不是 Ferry Plus。' >&2
    exit 1
fi
case "$version" in
    ''|*[!0-9A-Za-z.+-]*)
        printf '%s\n' 'App 版本号不能用于产物文件名。' >&2
        exit 1
        ;;
esac
if [ "$(lipo -archs "$app_dir/Contents/MacOS/$executable")" != arm64 ]; then
    printf '%s\n' '交付 App 必须仅包含 arm64 架构。' >&2
    exit 1
fi
codesign --verify --strict "$app_dir"

output_dir="$repo_dir/.build/dist"
archive_name="Ferry-Plus-$version-arm64.zip"
mkdir -p "$output_dir"
ditto -c -k --keepParent "$app_dir" "$output_dir/$archive_name.tmp"
mv -f "$output_dir/$archive_name.tmp" "$output_dir/$archive_name"
(
    cd "$output_dir"
    shasum -a 256 "$archive_name" > "$archive_name.sha256"
)
printf '%s\n' "$output_dir/$archive_name" "$output_dir/$archive_name.sha256"
