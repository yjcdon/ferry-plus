#!/bin/bash
# 在当前 Command Line Tools 环境运行仓库现有 Swift Testing 套件。
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
developer_dir="$(xcode-select -p)"
sdk_dir="$(xcrun --sdk "${FERRY_MACOS_SDK:-macosx26.5}" --show-sdk-path)"
frameworks="$developer_dir/Library/Developer/Frameworks"
plugin="$developer_dir/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
swift test --package-path "$repo_dir/Packages/FerryKit" --build-system native --sdk "$sdk_dir" \
    --jobs 4 --disable-xctest \
    -Xswiftc -F -Xswiftc "$frameworks" \
    -Xswiftc -load-plugin-library -Xswiftc "$plugin" \
    -Xlinker -rpath -Xlinker "$frameworks" "$@"
