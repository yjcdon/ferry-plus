#!/bin/bash
# 在 Mac 上构建 Ferry Drive 5.0 的 arm64 DMG 与 Windows x64 安装包。
set -euo pipefail

if [ "$(uname -s)" != Darwin ]; then
    printf '%s\n' '此构建入口需要 macOS 来生成 DMG。' >&2
    exit 1
fi
if ! command -v makensis >/dev/null; then
    printf '%s\n' '请安装 NSIS（makensis）后构建 Windows 安装包。' >&2
    exit 1
fi

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="$repo_dir/.build/ferry-drive"
cd "$repo_dir/desktop"
version="$(plutil -extract version raw mygo.json)"
go tool mygo build -platform darwin/arm64,windows/amd64 -o "$output_dir" \
    -sign "${FERRY_CODESIGN_IDENTITY:--}"

codesign --verify --deep --strict "$output_dir/darwin-arm64/Ferry Drive.app"
for artifact in \
    "darwin-arm64/ferry-drive-$version-arm64.dmg" \
    "windows-amd64/ferry-drive-setup-$version-amd64.exe"; do
    artifact_dir="$output_dir/${artifact%/*}"
    filename="${artifact##*/}"
    (
        cd "$artifact_dir"
        shasum -a 256 "$filename" > "$filename.sha256"
        shasum -a 256 -c "$filename.sha256"
    )
    printf '%s\n' "$output_dir/$artifact" "$output_dir/$artifact.sha256"
done
