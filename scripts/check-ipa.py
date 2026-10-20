#!/usr/bin/env python3
"""Verify a built Windoz IPA: bundle layout, the JIT helper, the version it
claims, and the strings that prove the feature subsystems are inside.

Usage:
    check-ipa.py <path-to.ipa> [--require VERSION] [--min-build N]

Exit 0 when every required check passes; non-zero with each failure named.

This is the check the keeper process used to run by hand, now a real CLI, so
CI gates on it (build-ipa runs it right after assembling the IPA) and the
release workflow can record what it found.
"""
import argparse
import json
import plistlib
import re
import sys
import textwrap
import zipfile
from pathlib import Path

# Subsystem strings that must be inside the app's main executable: Steam
# depot chunk formats, Doz Dock, Steam auth, Epic downloader, runtime
# manager, the built-in JIT helper hook, the pairing library, and the
# LiveContainer helpers.
FIXED_MARKERS = [
    b"ChunksV4", b"ChunksV5", b"windoz-dock", b"launch.auth", b"[epic-dl]",
    b"windoz-runtimes", b"WindozJITHelper", b"windoz_rppairing",
    b"localdevvpn", b"stikdebug",
]

# A desktop session is explorer.exe from the native ARM64 farm. 0.9.0
# shipped only arm64ec-windows, so Explorer, dockhost.exe and Steam's batch
# could not resolve their system DLLs. Gate the files that make that path
# real, not just the folder name.
NATIVE_DESKTOP_FILES = [
    "aarch64-windows/explorer.exe",
    "aarch64-windows/cmd.exe",
    "aarch64-windows/conhost.exe",
    "aarch64-windows/services.exe",
    "aarch64-windows/rpcss.exe",
]

MANIFEST_PATH = "Payload/Windoz.app/runtime-manifest.json"
SOURCE_MANIFEST = Path(__file__).resolve().parent.parent / "app-windoz/Sources/Engine/RuntimeCatalog.swift"


def built_in_manifest(source: Path):
    """The raw-string JSON compiled into RuntimeCatalog.swift.

    It is the fallback when a host hides the bundled manifest. If it drifts
    from Resources/runtime-manifest.json, a device with the bundle path bug
    silently shows a different component list than the release notes claim.
    """
    text = source.read_text(encoding="utf-8")
    match = re.search(r'private static let builtInManifest = #"""(.*?)"""#', text, re.S)
    if not match:
        raise ValueError("builtInManifest raw string not found in RuntimeCatalog.swift")
    return json.loads(textwrap.dedent(match.group(1)))


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify a Windoz IPA")
    parser.add_argument("ipa")
    parser.add_argument("--require", metavar="VERSION",
                        help="fail unless the app claims this CFBundleShortVersionString")
    parser.add_argument("--min-build", type=int, metavar="N",
                        help="fail when CFBundleVersion is below N")
    args = parser.parse_args()

    failures = []
    z = zipfile.ZipFile(args.ipa)
    names = z.namelist()

    info_name = "Payload/Windoz.app/Info.plist"
    if info_name not in names:
        print("MISSING", info_name)
        return 1
    info = plistlib.loads(z.read(info_name))
    version = info.get("CFBundleShortVersionString")
    build = info.get("CFBundleVersion")
    print("app version:", version, "build:", build)
    print("app MinimumOSVersion:", info.get("MinimumOSVersion"))
    print("app CFBundleIdentifier:", info.get("CFBundleIdentifier"))

    if args.require and version != args.require:
        failures.append(f"app version is {version!r}, required {args.require!r}")
    if args.min_build is not None:
        try:
            if int(build) < args.min_build:
                failures.append(f"app build is {build!r}, required at least {args.min_build}")
        except (TypeError, ValueError):
            failures.append(f"app build is not a number: {build!r}")

    # The built-in JIT helper must be inside the app bundle.
    helper_bin = "Payload/Windoz.app/PlugIns/WindozJITHelper.appex/WindozJITHelper"
    if helper_bin not in names:
        failures.append("the built-in JIT helper binary is not inside the app")
    helper_info_name = "Payload/Windoz.app/PlugIns/WindozJITHelper.appex/Info.plist"
    if helper_info_name in names:
        hinfo = plistlib.loads(z.read(helper_info_name))
        print("helper version:", hinfo.get("CFBundleShortVersionString"),
              "build:", hinfo.get("CFBundleVersion"))
        print("helper NSExtension keys:", list((hinfo.get("NSExtension") or {}).keys()))

    exe_name = info.get("CFBundleExecutable")
    if not exe_name:
        print("MISSING", "CFBundleExecutable")
        return 1
    main_exe = "Payload/Windoz.app/" + exe_name
    if main_exe not in names:
        print("MISSING", main_exe)
        return 1
    data = z.read(main_exe)
    print("main executable:", main_exe, f"({len(data)} bytes)")

    for marker in FIXED_MARKERS:
        found = marker in data
        print("FOUND  " if found else "MISSING", marker.decode())
        if not found:
            failures.append(f"marker {marker.decode()} not in the executable")

    # The native ARM64 Windows farm is the difference between a desktop and a
    # desktop whose client cannot start. Check the actual executables, not a
    # build log line.
    for relative in NATIVE_DESKTOP_FILES:
        entry = "Payload/Windoz.app/" + relative
        found = entry in names
        print("FOUND  " if found else "MISSING", relative)
        if not found:
            failures.append(f"{relative} is missing from the app bundle")

    # The editable resource and the compiled-in fallback must say the same
    # thing. check-ipa runs in the checkout during CI, so the Swift source is
    # available even though it is not packaged into the IPA.
    if MANIFEST_PATH not in names:
        failures.append("runtime-manifest.json is missing from the app bundle")
    else:
        try:
            packaged = json.loads(z.read(MANIFEST_PATH))
        except Exception as exc:
            failures.append(f"packaged runtime-manifest.json is invalid: {exc}")
        else:
            print("runtime manifest:", len(packaged.get("components", [])), "components")
            if SOURCE_MANIFEST.exists():
                try:
                    built_in = built_in_manifest(SOURCE_MANIFEST)
                except Exception as exc:
                    failures.append(f"built-in runtime manifest could not be read: {exc}")
                else:
                    if built_in != packaged:
                        failures.append("the compiled-in runtime manifest differs from "
                                        "Resources/runtime-manifest.json")
                    else:
                        print("FOUND   compiled-in manifest matches the packaged copy")
            else:
                print("SKIP    compiled-in manifest comparison (source checkout not found)")

    # The version the app claims must also be compiled in somewhere
    # (AppContainer.displayVersion feeds every log header, so a mismatch
    # between it and Info.plist is a real release bug).
    if isinstance(version, str):
        if version.encode() in data:
            print("FOUND   version string", version)
        else:
            failures.append(f"the executable does not carry the version string {version} "
                            "(AppContainer.displayVersion out of sync with project.yml?)")

    if failures:
        print("\nFAILURES:")
        for failure in failures:
            print(" -", failure)
        return 1
    print("\nALL CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
