#!/usr/bin/env python3
"""Generate a Homebrew cask from a validated, final release DMG and the release-info.txt beside it."""

import argparse
import hashlib
import pathlib
import re
import subprocess
import sys

RELEASE_CHANNEL = "early-development"


def read_release_info(path):
    info = {}
    for line in path.read_text().splitlines():
        key, sep, value = line.partition("=")
        if sep and key not in info:
            info[key] = value
    return info


def cask_text(repository, version, sha256, channel):
    words = channel.replace("-", " ")
    return f'''cask "openhuman-mail" do
  version "{version}"
  sha256 "{sha256}"

  url "https://github.com/{repository}/releases/download/v#{{version}}/OpenHuman-Mail-#{{version}}.dmg"
  name "OpenHuman Mail"
  desc "Keyboard-first Gmail client ({words} build)"
  homepage "https://github.com/{repository}"

  depends_on arch: :arm64
  depends_on macos: :golden_gate

  app "OpenHuman Mail.app"

  caveats <<~EOS
    OpenHuman Mail is an {words} build. Expect rough edges, and please send feedback:
      https://github.com/{repository}/issues
  EOS
end
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True, help="Public GitHub owner/repository")
    parser.add_argument("--version", required=True)
    parser.add_argument("--dmg", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+", args.repository):
        parser.error("repository must be a GitHub owner/repository")
    if not re.fullmatch(r"\d+\.\d+\.\d+", args.version):
        parser.error("version must have three numeric components")
    if args.dmg.name != f"OpenHuman-Mail-{args.version}.dmg" or not args.dmg.is_file():
        parser.error("DMG must exist and match OpenHuman-Mail-<version>.dmg")
    if args.output.exists():
        parser.error("output already exists. Review and move it before regenerating")
    record = args.dmg.with_name("release-info.txt")
    if not record.is_file():
        parser.error("release-info.txt from make-dmg.sh must be next to the DMG")
    info = read_release_info(record)
    if info.get("version") != args.version:
        parser.error(f"release-info.txt is for version {info.get('version')}, not {args.version}")
    if info.get("channel") != RELEASE_CHANNEL or info.get("prerelease") != "yes":
        parser.error("release-info.txt must mark the release as an early development pre-release "
                     f"(channel={RELEASE_CHANNEL}, prerelease=yes)")
    if info.get("notarized") != "yes":
        parser.error("casks are made from signed, notarized releases only (release-info.txt says "
                     f"notarized={info.get('notarized')})")
    check = pathlib.Path(__file__).with_name("check-release.sh")
    subprocess.run([str(check), str(args.dmg.resolve()), str(record.resolve())], check=True)
    checksum = hashlib.sha256()
    with args.dmg.open("rb") as dmg:
        for chunk in iter(lambda: dmg.read(1024 * 1024), b""):
            checksum.update(chunk)
    cask = cask_text(args.repository, args.version, checksum.hexdigest(), info["channel"])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x") as output:
        output.write(cask)
    print("Wrote " + str(args.output))
    return 0


if __name__ == "__main__":
    sys.exit(main())
