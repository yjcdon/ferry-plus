#!/bin/bash
# 发布已签名且经过验收的产物，再原子提交正式更新目录与 Cask。
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
if [ "$#" != 2 ]; then
    printf '%s\n' '用法：bash Scripts/publish-update.sh ZIP路径 更新准备目录' >&2
    exit 64
fi
repo=yjcdon/ferry-plus
archive="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
prepared="$(cd "$2" && pwd)"
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
tools="$(bash "$repo_dir/Scripts/setup-sparkle.sh")/bin"
account=io.github.yjcdon.FerryPlus.updates
version="$(bash "$repo_dir/Scripts/read-version.sh")"
tag="v$version"
for file in appcast.xml ferry-plus.rb notes.md; do test -s "$prepared/$file"; done
(cd "$(dirname "$archive")" && shasum -a 256 -c "$(basename "$archive").sha256")
expected_url="https://github.com/$repo/releases/download/$tag/$(basename "$archive")"
"$tools/sign_update" --account "$account" --verify "$prepared/appcast.xml"
python3 - "$prepared/appcast.xml" "$expected_url" "$archive" "$prepared/ferry-plus.rb" "$version" "$repo_dir/Scripts" "$tools" "$account" <<'PY'
import hashlib, pathlib, re, sys, xml.etree.ElementTree as ET
sys.path.insert(0, sys.argv[6])
import importlib.util
spec = importlib.util.spec_from_file_location('prepare_update', sys.argv[6] + '/prepare-update.py')
preparation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preparation)
metadata = preparation.verify_archive(pathlib.Path(sys.argv[3]))
assert metadata['CFBundleShortVersionString'] == sys.argv[5]
assert metadata['SUFeedURL'] == 'https://raw.githubusercontent.com/yjcdon/ferry-plus/main/updates/appcast.xml'
assert metadata['SURequireSignedFeed'] and metadata['SUVerifyUpdateBeforeExtraction']
assert metadata['SUPublicEDKey'] == preparation.run(pathlib.Path(sys.argv[7]) / 'generate_keys', '--account', sys.argv[8], '-p')
feed = ET.parse(sys.argv[1])
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
assert feed.find('.//' + ns + 'version').text == metadata['CFBundleVersion']
preparation.run(pathlib.Path(sys.argv[7]) / 'sign_update', '--account', sys.argv[8], '--verify', sys.argv[3], feed.find('.//enclosure').get(ns + 'edSignature'))
assert feed.find('.//enclosure').get('url') == sys.argv[2], 'Production feed must use this release archive'
archive = pathlib.Path(sys.argv[3])
assert int(feed.find('.//enclosure').get('length')) == archive.stat().st_size
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
cask = pathlib.Path(sys.argv[4]).read_text()
assert re.search(r'  sha256 \"' + digest + r'\"', cask), 'Cask must match archive SHA-256'
assert re.search(r'  version \"' + re.escape(sys.argv[5]) + r'\"', cask), 'Cask must match release version'
PY
work="$(mktemp -d "${TMPDIR:-/tmp}/ferry-publish.XXXXXX")"
trap '/usr/bin/trash "$work"' EXIT
# Use an isolated checkout so the caller's working tree and active branch are preserved.
git clone --quiet --depth 1 --branch main "https://github.com/$repo.git" "$work/repository"
cd "$work/repository"
if [ -f updates/appcast.xml ]; then
    "$tools/sign_update" --account "$account" --verify updates/appcast.xml
    status="$(python3 - updates/appcast.xml "$prepared/appcast.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
old_feed, new_feed = ET.parse(sys.argv[1]), ET.parse(sys.argv[2])
def versions(feed):
    return [int(x.text) for x in feed.iter(ns + 'version')]
old, new = max(versions(old_feed), default=0), max(versions(new_feed))
assert new >= old, 'Feed publication cannot lower the current build number'
if new == old:
    old_archive = old_feed.find('.//enclosure').attrib
    new_archive = new_feed.find('.//enclosure').attrib
    assert old_archive == new_archive, 'Same build already points to different archive content'
    print('already-published')
else:
    print('new-build')
PY
)"
    if [ "$status" = already-published ]; then
        cmp Casks/ferry-plus.rb "$prepared/ferry-plus.rb"
        cp updates/appcast.xml "$prepared/appcast.xml"
    fi
fi
cd "$repo_dir"
# Existing releases are checked rather than overwritten, allowing interrupted publication to resume.
if ! gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    gh release create "$tag" "$archive" "$archive.sha256" --repo "$repo" --verify-tag \
        --title "Ferry Plus $version" --notes-file "$prepared/notes.md" --latest=false
fi
test "$(gh release view "$tag" --repo "$repo" --json isDraft,isPrerelease --jq '.isDraft or .isPrerelease')" = false
if ! gh release view "$tag" --repo "$repo" --json assets --jq '.assets[].name' | grep -Fxq "$(basename "$archive")"; then
    gh release upload "$tag" "$archive" --repo "$repo"
fi
gh release download "$tag" --repo "$repo" --pattern "$(basename "$archive")" --dir "$work"
cmp "$archive" "$work/$(basename "$archive")"
checksum="$(basename "$archive").sha256"
if gh release view "$tag" --repo "$repo" --json assets --jq '.assets[].name' | grep -Fxq "$checksum"; then
    gh release download "$tag" --repo "$repo" --pattern "$checksum" --dir "$work"
    cmp "$archive.sha256" "$work/$checksum"
else
    gh release upload "$tag" "$archive.sha256" --repo "$repo"
fi
cd "$work/repository"
mkdir -p updates
cp "$prepared/appcast.xml" updates/appcast.xml
cp "$prepared/ferry-plus.rb" Casks/ferry-plus.rb
git add -- updates/appcast.xml Casks/ferry-plus.rb
if ! git diff --cached --quiet; then
    git commit -m "chore(release): 发布 $version 更新目录" -m 'AI: codex'
    git push origin HEAD:main
fi

gh release edit "$tag" --repo "$repo" --latest
