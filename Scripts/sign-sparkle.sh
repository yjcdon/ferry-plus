#!/bin/bash
# 使用宿主身份从内向外签名更新辅助程序，确保跨版本钥匙串身份稳定。
set -euo pipefail
framework="$1"
identity="$2"
codesign --force --sign "$identity" --timestamp=none "$framework/Versions/B/Autoupdate"
for service in "$framework/Versions/B/XPCServices/"*.xpc; do
    codesign --force --sign "$identity" --timestamp=none "$service"
done
codesign --force --sign "$identity" --timestamp=none "$framework/Versions/B/Updater.app"
codesign --force --sign "$identity" --timestamp=none "$framework"
codesign --verify --deep --strict "$framework"
