#!/usr/bin/env python3
"""将共享更新配置写入构建产物，测试源覆盖仅在显式测试模式下开放。"""
import os
import plistlib
import re
import sys
from pathlib import Path
from urllib.parse import urlparse

root = Path(__file__).resolve().parent.parent
values = {}
for line in (root / "Config/Updates.xcconfig").read_text().splitlines():
    match = re.fullmatch(r"\s*(SU_FEED_URL|SU_PUBLIC_ED_KEY)\s*=\s*(\S+)\s*", line)
    if match:
        if match[1] in values:
            raise SystemExit(f"重复更新配置 {match[1]}")
        values[match[1]] = match[2].replace("$()", "")
testing = os.environ.get("FERRY_UPDATE_TESTING") == "1"
for key, env in (("SU_FEED_URL", "FERRY_UPDATE_FEED_URL"),
                 ("SU_PUBLIC_ED_KEY", "FERRY_UPDATE_PUBLIC_KEY")):
    if env in os.environ:
        if not testing:
            raise SystemExit(f"{env} 仅供显式更新测试使用")
        values[key] = os.environ[env]
if set(values) != {"SU_FEED_URL", "SU_PUBLIC_ED_KEY"}:
    raise SystemExit("Updates.xcconfig 需要 SU_FEED_URL 和 SU_PUBLIC_ED_KEY")
url = urlparse(values["SU_FEED_URL"])
if url.scheme != "https" or not url.netloc or url.username or url.password:
    raise SystemExit("更新源需要有效的 HTTPS 地址")
import base64
try:
    key_bytes = base64.b64decode(values["SU_PUBLIC_ED_KEY"], validate=True)
except ValueError as error:
    raise SystemExit("更新公钥需要有效的 Base64") from error
if len(key_bytes) != 32:
    raise SystemExit("更新公钥需要 32 字节")
path = Path(sys.argv[1])
with path.open("rb") as stream:
    plist = plistlib.load(stream)
plist.update(SUFeedURL=values["SU_FEED_URL"], SUPublicEDKey=values["SU_PUBLIC_ED_KEY"],
             SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True,
             SUEnableAutomaticChecks=True, SUAutomaticallyUpdate=False,
             SUAllowsAutomaticUpdates=False, SUScheduledCheckInterval=86400)
with path.open("wb") as stream:
    plistlib.dump(plist, stream)
