#!/usr/bin/env python3
"""Prepare a signed Sparkle feed and Cask from the exact release archive."""
import argparse
import base64
import email.utils
import pathlib
import plistlib
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parent.parent
NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", NS)


def run(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True).strip()


def verify_archive(archive):
    """Read release metadata from the verified app inside the actual ZIP."""
    import zipfile
    with zipfile.ZipFile(archive) as package:
        for entry in package.infolist():
            path = pathlib.PurePosixPath(entry.filename)
            if path.is_absolute() or ".." in path.parts or path.parts[0] not in ("Ferry Plus.app", "__MACOSX"):
                raise ValueError("Archive must contain only Ferry Plus.app and archive metadata")
    directory = pathlib.Path(tempfile.mkdtemp(prefix="ferry-update-verify."))
    try:
        run("ditto", "-x", "-k", archive, directory)
        app = directory / "Ferry Plus.app"
        run("codesign", "--verify", "--deep", "--strict", app)
        signature = subprocess.run(["codesign", "-dv", str(app)], capture_output=True, text=True, check=True)
        if "Signature=adhoc" in signature.stderr:
            raise ValueError("Release archive requires fixed certificate signing")
        with (app / "Contents/Info.plist").open("rb") as source:
            return plistlib.load(source)
    finally:
        run("/usr/bin/trash", directory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=pathlib.Path)
    parser.add_argument("archive", type=pathlib.Path)
    parser.add_argument("--tools", required=True, type=pathlib.Path)
    parser.add_argument("--account", required=True, help="Sparkle Keychain signing account")
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--download-url", help="HTTPS archive URL, used for isolated update tests")
    parser.add_argument("--previous-feed", type=pathlib.Path)
    args = parser.parse_args()
    with (args.app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    archived_info = verify_archive(args.archive)
    if archived_info != info:
        raise ValueError("Archive metadata differs from the provided app")
    info = archived_info
    version = info["CFBundleShortVersionString"]
    build = info["CFBundleVersion"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not re.fullmatch(r"[1-9]\d*", build):
        raise ValueError("Release requires a three-part version and positive integer build number")
    if info["CFBundleIdentifier"] != "io.github.yjcdon.FerryPlus":
        raise ValueError("Expected Ferry Plus bundle identifier")
    key = run(args.tools / "generate_keys", "--account", args.account, "-p")
    if key != info["SUPublicEDKey"] or len(base64.b64decode(key, validate=True)) != 32:
        raise ValueError("Signing account does not match the app's update public key")
    run("codesign", "--verify", "--deep", "--strict", args.app)
    if args.previous_feed:
        previous = ET.parse(args.previous_feed)
        previous_builds = [int(item.text) for item in previous.iter(f"{{{NS}}}version")]
        if previous_builds and int(build) <= max(previous_builds):
            raise ValueError("Release build number must exceed the previous feed")
    notes = (ROOT / "CHANGELOG.md").read_text()
    match = re.search(r"^## " + re.escape(version) + r"(?:[^\n]*)\n(.*?)(?=^## |\Z)", notes, re.M | re.S)
    if not match or not match.group(1).strip():
        raise ValueError("CHANGELOG.md needs nonempty release notes for this version")
    notes = match.group(1).strip() + "\n"
    url = args.download_url or f"https://github.com/yjcdon/ferry-plus/releases/download/v{version}/{args.archive.name}"
    if not url.startswith("https://"):
        raise ValueError("Update downloads require HTTPS")
    signature = run(args.tools / "sign_update", "--account", args.account, "-p", args.archive)
    run(args.tools / "sign_update", "--account", args.account, "--verify", args.archive, signature)
    rss = ET.Element("rss", version="2.0")
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Ferry Plus"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"Ferry Plus {version}"
    ET.SubElement(item, f"{{{NS}}}version").text = build
    ET.SubElement(item, f"{{{NS}}}shortVersionString").text = version
    minimum = info["LSMinimumSystemVersion"].split(".")
    ET.SubElement(item, f"{{{NS}}}minimumSystemVersion").text = ".".join(minimum + ["0"] * (3 - len(minimum)))
    ET.SubElement(item, f"{{{NS}}}hardwareRequirements").text = "arm64"
    ET.SubElement(item, "pubDate").text = email.utils.formatdate(usegmt=True)
    ET.SubElement(item, "description", {f"{{{NS}}}format": "markdown"}).text = notes
    ET.SubElement(item, "enclosure", {"url": url, "length": str(args.archive.stat().st_size),
        "type": "application/octet-stream", f"{{{NS}}}edSignature": signature})
    args.output.mkdir(parents=True, exist_ok=True)
    feed = args.output / "appcast.xml"
    ET.ElementTree(rss).write(feed, encoding="utf-8", xml_declaration=True)
    run(args.tools / "sign_update", "--account", args.account, feed)
    run(args.tools / "sign_update", "--account", args.account, "--verify", feed)
    (args.output / "notes.md").write_text(notes)
    digest = run("shasum", "-a", "256", args.archive).split()[0]
    cask = (ROOT / "Casks/ferry-plus.rb").read_text()
    cask = re.sub(r'  version "[^"]+"', f'  version "{version}"', cask)
    cask = re.sub(r'  sha256 "[^"]+"', f'  sha256 "{digest}"', cask)
    (args.output / "ferry-plus.rb").write_text(cask)
    print(feed)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, ET.ParseError, subprocess.CalledProcessError) as error:
        sys.exit(f"Update preparation failed: {error}")
