#!/bin/bash
# 在 Mac 上构建 Ferry Drive 5.0 的 arm64 应用 与 Windows x64 安装包。
set -euo pipefail

if [ "$(uname -s)" != Darwin ]; then
    printf '%s\n' '此构建入口需要 macOS 来构建和签名应用。' >&2
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
go tool mygo build -platform darwin/arm64,windows/amd64 -skip-dmg -o "$output_dir" \
    -sign "${FERRY_CODESIGN_IDENTITY:--}"

mac_app="$output_dir/darwin-arm64/Ferry Drive.app"
codesign --verify --deep --strict "$mac_app"
printf '%s\n' "$mac_app"

installer="ferry-drive-setup-$version-amd64.exe"
portable="ferry-drive-$version-windows-amd64-portable.zip"
cd "$output_dir/windows-amd64"
zip -q -X -FS "$portable" 'Ferry Drive.exe'
shasum -a 256 "$installer" > "$installer.sha256"
shasum -a 256 -c "$installer.sha256"
printf '%s\n' "$PWD/$installer" "$PWD/$portable" "$PWD/$installer.sha256"
