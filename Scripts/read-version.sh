#!/bin/bash
# 读取唯一产品版本；缺失、重复或不符合 App 版本格式时终止构建。
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
version="$(awk '/^[[:space:]]*MARKETING_VERSION[[:space:]]*=/ {
    sub(/^[[:space:]]*MARKETING_VERSION[[:space:]]*=[[:space:]]*/, "")
    sub(/[[:space:]]*$/, "")
    print
}' "$repo_dir/Config/Version.xcconfig")"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    printf '%s\n' 'Config/Version.xcconfig 必须且只能定义一个有效的 MARKETING_VERSION。' >&2
    exit 1
fi
printf '%s\n' "$version"
