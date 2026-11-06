#!/bin/bash
# 下载经过固定摘要校验的 Sparkle 分发包，输出框架与发布工具所在目录。
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
version=2.10.1
digest=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
root="$repo_dir/.build/dependencies"
archive="$root/Sparkle-$version.tar.xz"
distribution="$root/Sparkle-$version"
mkdir -p "$root"
if [ ! -f "$archive" ]; then
    curl --fail --location --retry 2 --connect-timeout 20 \
        "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" \
        -o "$archive.download"
    mv "$archive.download" "$archive"
fi
printf '%s  %s\n' "$digest" "$archive" | shasum -a 256 --check >&2
if [ ! -f "$distribution/Sparkle.framework/Versions/B/Sparkle" ]; then
    mkdir -p "$distribution"
    tar -xJf "$archive" -C "$distribution"
fi
codesign --verify --strict "$distribution/Sparkle.framework"
printf '%s\n' "$distribution"
