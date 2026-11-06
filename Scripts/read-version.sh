#!/bin/bash
# 读取共享展示版本或内部构建号，缺失、重复或格式错误时终止构建。
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
case "${1-}" in
    "") key=MARKETING_VERSION; pattern='^[0-9]+\.[0-9]+(\.[0-9]+)?$' ;;
    --build-number) key=CURRENT_PROJECT_VERSION; pattern='^[1-9][0-9]*$' ;;
    *) printf '%s\n' '用法：read-version.sh [--build-number]' >&2; exit 64 ;;
esac
version="$(awk -v key="$key" '$0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
    sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "")
    sub(/[[:space:]]*$/, "")
    print
}' "$repo_dir/Config/Version.xcconfig")"
if [[ ! "$version" =~ $pattern ]]; then
    printf 'Config/Version.xcconfig 必须且只能定义一个有效的 %s。\n' "$key" >&2
    exit 1
fi
printf '%s\n' "$version"
