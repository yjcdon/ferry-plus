#!/bin/bash
# 使用宿主身份从内向外签名更新辅助程序，确保跨版本钥匙串身份稳定。
set -euo pipefail
framework="$1"
identity="$2"
# Sparkle 2.10.1 的简体中文资源缺少这几条错误提示，签名前补齐。
python3 - "$framework/Versions/B/Resources/zh_CN.lproj/Sparkle.strings" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
strings = plistlib.loads(path.read_bytes())
translations = {
    "%1$@ %2$@ is available but this update requires a new Apple silicon Mac.":
        "%1$@ %2$@ 已发布，此更新需要搭载 Apple 芯片的 Mac。",
    "An error occurred while downloading the release notes.":
        "更新说明下载失败。",
    "An error occurred while encoding the installer parameters. Please try again later.":
        "安装准备失败，请稍后重试。",
    "The release notes is improperly signed and could not be validated. Please contact the app developer for more information.":
        "更新说明验证失败，请联系应用开发者。",
    "The update feed is improperly signed and could not be validated. Please try again later or contact the app developer.":
        "更新信息验证失败。请稍后重试，或联系应用开发者。",
    "Your Mac is too old": "此 Mac 无法安装更新",
}
for source, translation in translations.items():
    strings.setdefault(source, translation)
strings = {source: translation.replace("App开发者", "应用开发者")
           for source, translation in strings.items()}
path.write_bytes(plistlib.dumps(strings, fmt=plistlib.FMT_BINARY))
PY
codesign --force --sign "$identity" --timestamp=none --options runtime "$framework/Versions/B/Autoupdate"
for service in "$framework/Versions/B/XPCServices/"*.xpc; do
    codesign --force --sign "$identity" --timestamp=none --options runtime "$service"
done
codesign --force --sign "$identity" --timestamp=none --options runtime "$framework/Versions/B/Updater.app"
codesign --force --sign "$identity" --timestamp=none --options runtime "$framework"
codesign --verify --deep --strict "$framework"
