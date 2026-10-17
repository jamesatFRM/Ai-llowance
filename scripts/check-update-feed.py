#!/usr/bin/env python3
"""Bind an update feed to the complete published release; never modify signed XML."""
import argparse
import base64
import hashlib
import pathlib
import re
import sys
import xml.etree.ElementTree as ET

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
RELEASE_URL = "https://github.com/jamesatFRM/Ai-llowance/releases/download/"


def feed_items(path):
    items = ET.parse(path).getroot().findall("./channel/item")
    if not items:
        raise ValueError("Update feed has no release items.")
    result = []
    for item in items:
        build = item.findtext(SPARKLE + "version", "")
        enclosure = item.find("enclosure")
        if not re.fullmatch(r"[0-9]+", build) or enclosure is None:
            raise ValueError("Update feed has invalid release metadata.")
        result.append((int(build), item, enclosure.attrib))
    return result


def validate(feed, assets, tag, previous=None):
    match = re.fullmatch(r"v([0-9]+\.[0-9]+\.[0-9]+)-build([0-9]+)", tag)
    if not match:
        raise ValueError("Expected a versioned release tag.")
    version, build = match.groups()
    items = feed_items(feed)
    if len(items) != 1:
        raise ValueError("Expected exactly one update release.")
    actual_build, item, enclosure = items[0]
    if actual_build != int(build) or item.findtext(SPARKLE + "shortVersionString") != version:
        raise ValueError("Update version does not match its release tag.")
    prefix = RELEASE_URL + tag + "/"
    url = enclosure.get("url", "")
    name = url.removeprefix(prefix)
    expected_name = rf"Ai-llowance-{re.escape(version)}-build{build}-macOS-(?:universal|arm64|x86_64)\.dmg"
    if not url.startswith(prefix) or not re.fullmatch(expected_name, name):
        raise ValueError("Update download does not match its release tag and archive.")
    signature = enclosure.get(SPARKLE + "edSignature", "")
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Update archive signature is missing or invalid.")

    # A release can exist after an interrupted upload. Its checksum manifest alone
    # is not evidence that the files users will download are present and intact.
    expected_files = {name, name.removesuffix(".dmg") + ".zip"}
    manifest = {}
    for line in (assets / "SHA256SUMS").read_text().splitlines():
        entry = re.fullmatch(r"([a-fA-F0-9]{64}) [ *](.+)", line)
        if not entry or entry[2] in manifest:
            raise ValueError("Release checksum manifest is invalid.")
        manifest[entry[2]] = entry[1].lower()
    if set(manifest) != expected_files:
        raise ValueError("Release checksum manifest does not match the update archives.")
    for filename, expected_hash in manifest.items():
        path = assets / filename
        if not path.is_file() or path.is_symlink():
            raise ValueError("A required release archive is missing.")
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != expected_hash:
            raise ValueError("A release archive does not match its checksum.")
    if enclosure.get("length") != str((assets / name).stat().st_size):
        raise ValueError("Update download length does not match the published archive.")

    if previous is not None:
        for old_build, _, old_enclosure in feed_items(previous):
            if old_build > actual_build:
                raise ValueError("Refusing to replace a newer update feed with an older build.")
            if old_build == actual_build:
                identity = ("url", "length", SPARKLE + "edSignature")
                if any(old_enclosure.get(key) != enclosure.get(key) for key in identity):
                    raise ValueError("Refusing to change an already published update build.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("feed", type=pathlib.Path)
    parser.add_argument("assets", type=pathlib.Path)
    parser.add_argument("tag")
    parser.add_argument("--previous", type=pathlib.Path)
    args = parser.parse_args()
    try:
        validate(args.feed, args.assets, args.tag, args.previous)
    except (ValueError, OSError, ET.ParseError) as error:
        # Missing paths can include local account names; keep failures generic.
        if isinstance(error, (OSError, ET.ParseError)):
            print("Update verification failed: required release files are missing or unreadable.", file=sys.stderr)
        else:
            print("Update verification failed: " + str(error), file=sys.stderr)
        return 1
    print("Update feed matches verified release archives and does not roll back publication.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
