#!/usr/bin/env python3
"""Read a build setting from app-windoz/project.yml.

Usage:
    read-version.py            -> prints "version=0.6.0 build=6"
    read-version.py version    -> prints just "0.6.0"
    read-version.py build      -> prints just "6"

Anchored to indented settings lines (`MARKETING_VERSION: "..."`). The bare
names also appear in comments and as Info.plist references, and an
unanchored grep picked up a comment in build-ipa run #19 and fed the IPA
check gate a garbage "required" version. This script is the single place
that reads them, testable locally, and both workflows use it.
"""
import re
import sys

PATH = "app-windoz/project.yml"


def setting(name: str) -> str:
    text = open(PATH, encoding="utf-8").read()
    match = re.search(r'^[ \t]+%s:[ \t]*"([^"]+)"' % re.escape(name), text, re.M)
    if not match:
        print(f"could not read {name} from {PATH}", file=sys.stderr)
        sys.exit(1)
    return match.group(1)


def main() -> int:
    version = setting("MARKETING_VERSION")
    build = setting("CURRENT_PROJECT_VERSION")
    what = sys.argv[1] if len(sys.argv) > 1 else "both"
    if what == "version":
        print(version)
    elif what == "build":
        print(build)
    else:
        print(f"version={version} build={build}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
