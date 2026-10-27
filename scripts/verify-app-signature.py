#!/usr/bin/env python3
"""Verify the app and every bundled Mach-O, including code in Resources.

With --developer-id, require a common Developer ID Application identity,
hardened runtime and a secure timestamp on all code. This does not establish
notarization; use stapler and Gatekeeper assessment after Apple accepts the app.
"""

import argparse
from pathlib import Path
import re
import subprocess
import sys


MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}
DEVELOPER_ID_REQUIREMENT = (
    "=anchor apple generic and "
    "certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
)


def codesign(*arguments):
    result = subprocess.run(
        ["/usr/bin/codesign", *map(str, arguments)],
        capture_output=True, text=True,
    )
    if result.returncode:
        raise ValueError(result.stderr.strip() or result.stdout.strip())
    return result.stdout + result.stderr


def identity(path):
    details = codesign("--display", "--verbose=4", path)
    team = re.search(r"^TeamIdentifier=(.+)$", details, re.MULTILINE)
    authority = re.search(r"^Authority=(Developer ID Application: .+)$", details, re.MULTILINE)
    flags = re.search(r"\bflags=0x([0-9a-fA-F]+)\b", details)
    if not team or team.group(1) == "not set" or not authority:
        raise ValueError(f"{path}: Developer ID Application signature is required")
    if not flags or not int(flags.group(1), 16) & 0x10000:
        raise ValueError(f"{path}: hardened runtime is missing")
    if not re.search(r"^Timestamp=.+$", details, re.MULTILINE):
        raise ValueError(f"{path}: secure timestamp is missing")
    return team.group(1), authority.group(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--developer-id", action="store_true")
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    if not app.is_dir() or app.suffix != ".app":
        raise ValueError("Expected an existing .app directory")

    requirements = ["--test-requirement", DEVELOPER_ID_REQUIREMENT] if args.developer_id else []
    codesign("--verify", "--deep", "--strict", "--verbose=2", *requirements, app)
    expected_identity = identity(app) if args.developer_id else None
    binaries = []
    for path in app.rglob("*"):
        if path.is_symlink():
            target = path.resolve(strict=True)
            try:
                target.relative_to(app)
            except ValueError:
                raise ValueError(f"{path}: symbolic link leaves the application") from None
            continue
        if not path.is_file():
            continue
        with path.open("rb") as handle:
            is_macho = handle.read(4) in MACHO_MAGICS
        if is_macho:
            binaries.append(path)
    if not binaries:
        raise ValueError("No Mach-O binaries found")
    for path in sorted(binaries):
        codesign("--verify", "--strict", "--all-architectures", *requirements, path)
        if expected_identity and identity(path) != expected_identity:
            raise ValueError(f"{path}: signing identity differs from the application")
    mode = "Developer ID, hardened runtime and secure timestamps" if args.developer_id else "code signatures"
    print(f"PASS: app and {len(binaries)} Mach-O files verified ({mode}).")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError) as error:
        print(f"Signature verification failed: {error}", file=sys.stderr)
        sys.exit(1)
