#!/usr/bin/env python3
"""Update a pinned cask from a verified, published Headroom release."""

import argparse
import hashlib
import json
import re
from pathlib import Path


VERSION = re.compile(r"v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")


def update(version, checksums, archive, output, metadata):
    match = VERSION.fullmatch(version)
    if not match:
        raise ValueError("Version must be a stable major.minor.patch release")
    numbers = tuple(int(part) for part in match.groups())
    version = ".".join(match.groups())
    release = json.loads(metadata.read_text())
    if (not isinstance(release, dict) or release.get("tagName") != "v" + version
            or release.get("isDraft") is not False or release.get("isPrerelease") is not False):
        raise ValueError("Release must be published, stable, and match the requested version")
    entries = []
    for line in checksums.read_text().splitlines():
        fields = line.split()
        if len(fields) >= 2 and fields[-1].lstrip("*") == "Headroom.zip":
            if len(fields) != 2 or not re.fullmatch(r"[0-9a-fA-F]{64}", fields[0]):
                raise ValueError("Malformed Headroom.zip checksum")
            entries.append(fields[0].lower())
    if len(entries) != 1:
        raise ValueError("Expected exactly one Headroom.zip checksum")
    digest = hashlib.sha256()
    with archive.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    checksum = entries[0]
    if digest.hexdigest() != checksum:
        raise ValueError("Headroom.zip does not match the published checksum")
    if output.exists():
        current = output.read_text()
        versions = re.findall(r'^  version "([^"\n]+)"$', current, re.MULTILINE)
        hashes = re.findall(r'^  sha256 "([0-9a-f]{64})"$', current, re.MULTILINE)
        if len(versions) != 1 or len(hashes) != 1 or not VERSION.fullmatch(versions[0]):
            raise ValueError("Existing cask has an invalid version or checksum")
        previous = tuple(int(part) for part in VERSION.fullmatch(versions[0]).groups())
        if numbers < previous:
            raise ValueError("Refusing to downgrade the Homebrew cask")
        if numbers == previous and hashes[0] != checksum:
            raise ValueError("Published release checksum changed for the same version")
        if numbers == previous:
            return
    content = '''cask "headroom" do
  version "%s"
  sha256 "%s"

  url "https://github.com/DivyanshGolyan/claude-headroom/releases/download/v#{version}/Headroom.zip"
  name "Headroom"
  desc "Claude quota forecasts in the menu bar"
  homepage "https://github.com/DivyanshGolyan/claude-headroom"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "Headroom.app"

  uninstall quit: "com.divyanshgolyan.headroom"
end
''' % (version, checksum)
    if not output.exists() or output.read_text() != content:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(content)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--metadata", type=Path, required=True)
    parser.add_argument("--checksums", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        update(args.version, args.checksums, args.archive, args.output, args.metadata)
    except (OSError, ValueError) as error:
        parser.exit(1, "Cannot update Homebrew cask: %s\n" % error)


if __name__ == "__main__":
    main()
