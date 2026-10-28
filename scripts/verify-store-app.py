#!/usr/bin/env python3
"""Check the local sandbox candidate, not App Store acceptance or distribution signing."""

import argparse
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import sys


MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}
HELPER_ENTITLEMENTS = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.inherit": True,
}
_signature_spec = importlib.util.spec_from_file_location(
    "travel_signature_verifier", Path(__file__).with_name("verify-app-signature.py"))
_signature_verifier = importlib.util.module_from_spec(_signature_spec)
_signature_spec.loader.exec_module(_signature_verifier)
developer_identity = _signature_verifier.identity
DEVELOPER_ID_REQUIREMENT = _signature_verifier.DEVELOPER_ID_REQUIREMENT


def codesign(*arguments):
    result = subprocess.run(["/usr/bin/codesign", *map(str, arguments)], capture_output=True)
    if result.returncode:
        raise ValueError(result.stderr.decode(errors="replace").strip())
    return result.stdout


def entitlements(path):
    raw = codesign("--display", "--entitlements", ":-", path)
    return plistlib.loads(raw) if raw.strip() else {}


def macho_files(app):
    binaries = []
    for path in app.rglob("*"):
        if path.is_symlink():
            target = path.resolve(strict=True)
            if not target.is_relative_to(app):
                raise ValueError(f"Symbolic link leaves the app: {path}")
        elif path.is_file():
            with path.open("rb") as stream:
                if stream.read(4) in MACHO_MAGICS:
                    binaries.append(path)
    return sorted(binaries)


def verify(app, expected):
    for required in (
        "com.apple.security.app-sandbox",
        "com.apple.security.files.user-selected.read-write",
        "com.apple.security.network.client",
    ):
        if expected.get(required) is not True:
            raise ValueError(f"Missing required main entitlement: {required}")
    if "com.apple.security.inherit" in expected:
        raise ValueError("Main application must not inherit its sandbox")
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    with (app / "Contents/Resources/PrivacyInfo.xcprivacy").open("rb") as stream:
        privacy = plistlib.load(stream)
    if not isinstance(privacy, dict) or privacy.get("NSPrivacyTracking") is not False:
        raise ValueError("Expected the non-tracking privacy manifest")
    if not isinstance(privacy.get("NSPrivacyAccessedAPITypes"), list):
        raise ValueError("Privacy manifest is missing required-reason API declarations")
    if info.get("CFBundleIdentifier") != "io.github.waton1990.travel-media-manager":
        raise ValueError("Unexpected application bundle identifier")
    main = app / "Contents/MacOS" / info["CFBundleExecutable"]
    helper = app / "Contents/Helpers/USBHelper.app/Contents/MacOS/iphone-usb-helper"
    if not main.is_file() or not helper.is_file():
        raise ValueError("Application or bundled USB helper is missing")
    if (app / "Contents/Resources/USBHelper").exists():
        raise ValueError("Store helper must be in Contents/Helpers, not Resources")
    codesign("--verify", "--deep", "--strict", "--test-requirement", DEVELOPER_ID_REQUIREMENT, app)
    expected_identity = developer_identity(app)
    if entitlements(app) != expected or entitlements(main) != expected:
        raise ValueError("Main signature entitlements differ from the requested configuration")
    binaries = macho_files(app)
    if len(binaries) < 3:
        raise ValueError("Bundled Python runtime is missing")
    for path in binaries:
        codesign("--verify", "--strict", "--all-architectures", "--test-requirement", DEVELOPER_ID_REQUIREMENT, path)
        if developer_identity(path) != expected_identity:
            raise ValueError(f"Bundled code has a different signing team or identity: {path.relative_to(app)}")
        actual = entitlements(path)
        wanted = expected if path == main else HELPER_ENTITLEMENTS if path == helper else {}
        if actual != wanted:
            raise ValueError(f"Unexpected code entitlements: {path.relative_to(app)}")
    return len(binaries)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--entitlements", type=Path,
                        default=Path(__file__).resolve().parent.parent / "packaging/store-app.entitlements")
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    if not app.is_dir() or app.suffix != ".app":
        raise ValueError("Expected an application bundle")
    with args.entitlements.open("rb") as stream:
        expected = plistlib.load(stream)
    count = verify(app, expected)
    print(f"PASS: local sandbox candidate and {count} Mach-O signatures/entitlements verified (same Developer ID, runtime, timestamps).")
    print("This check does not prove sandbox runtime behavior, distribution signing, or App Review acceptance.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException) as error:
        print(f"Store candidate verification failed: {error}", file=sys.stderr)
        sys.exit(1)
