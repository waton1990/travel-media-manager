#!/usr/bin/env python3
"""Check publishable source files without opening a phone or modifying files.

This bounded check catches accidental private artifacts and common credentials.
It does not replace reviewing screenshots, documents, or the actual release assets.
Use --tracked in CI and immediately before publishing a committed repository.
"""

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
ALLOWED_DIRECTORIES = {
    "Sources", "Tests", "scripts", "packaging", "docs", "assets", ".github",
    "third-party",
}
ALLOWED_ROOT_FILES = {
    "Package.swift", "Package.resolved", "README.md", "README.en.md", "LICENSE",
    "NOTICE", "THIRD_PARTY_NOTICES.md", "CONTRIBUTING.md", "CHANGELOG.md",
    "SECURITY.md", "CODE_OF_CONDUCT.md", ".gitignore", ".gitattributes",
}
REQUIRED_FILES = {
    "README.md", "LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md", "CONTRIBUTING.md",
    "SECURITY.md", "CHANGELOG.md", "docs/PRIVACY.md", "docs/USER_GUIDE.md",
    "Package.swift", "scripts/usb-helper-requirements.lock",
}
LOCAL_OUTPUT_DIRECTORIES = {
    ".git", ".build", ".swiftpm", "work", "outputs", "dist", ".venv", "venv",
    "__pycache__", ".idea", ".vscode",
}
FORBIDDEN_PARTS = LOCAL_OUTPUT_DIRECTORIES | {"private", "真机导入测试", "xcuserdata"}
FORBIDDEN_EXTENSIONS = {
    ".heic", ".heif", ".jpg", ".jpeg", ".dng", ".cr2", ".cr3", ".nef", ".arw",
    ".mov", ".mp4", ".m4v", ".m4a", ".mp3", ".wav", ".aac", ".lrf", ".aae",
    ".sqlite", ".db", ".p12", ".p8", ".key", ".pem", ".cer", ".certsigningrequest", ".mobileprovision",
    ".provisionprofile", ".log", ".pyc", ".pyo", ".zip", ".dmg", ".pkg",
    ".gz", ".tgz", ".xz", ".bz2",
}
BINARY_ASSETS = {".icns", ".png", ".gif"}
SECRET_PATTERNS = [
    ("private key", re.compile(r"-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----")),
    ("GitHub access token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}\b")),
    ("GitHub fine-grained token", re.compile(r"\bgithub_pat_[A-Za-z0-9_]{50,}\b")),
    ("AWS access key", re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b")),
    ("credential in URL", re.compile(r"https?://[^\s/:@]+:[^\s/@]+@")),
    ("personal home path", re.compile(r"/(?:Users|home)/[^\s/\"']+")),
    ("Windows personal home path", re.compile(r"[A-Za-z]:\\Users\\[^\s\\\"']+")),
    ("device identifier", re.compile(r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\b")),
]


def candidates(tracked):
    if tracked:
        top = subprocess.run(
            ["git", "-C", str(ROOT), "rev-parse", "--show-toplevel"],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
        if Path(top).resolve() != ROOT:
            raise ValueError("--tracked requires this project to be its own Git repository")
        output = subprocess.run(
            ["git", "-C", str(ROOT), "ls-files", "-z"],
            check=True, capture_output=True,
        ).stdout
        return [Path(os.fsdecode(name)) for name in output.split(b"\0") if name]
    result = []
    for directory, dirs, files in os.walk(ROOT, followlinks=False):
        here = Path(directory)
        for name in dirs[:]:
            path = here / name
            if path.is_symlink():
                result.append(path.relative_to(ROOT))
                dirs.remove(name)
            elif name in LOCAL_OUTPUT_DIRECTORIES:
                dirs.remove(name)
        result.extend((here / name).relative_to(ROOT) for name in files if name not in {".DS_Store", ".git"})
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tracked", action="store_true", help="check Git-tracked files, including force-added ignored files")
    args = parser.parse_args()
    try:
        files = sorted(candidates(args.tracked))
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"Unable to select source files: {error}", file=sys.stderr)
        return 2
    findings = []
    available = {p.as_posix() for p in files}
    for missing in sorted(REQUIRED_FILES - available):
        findings.append((missing, "required public document or build input is missing"))
    for relative in files:
        name = relative.as_posix()
        path = ROOT / relative
        if relative.is_absolute() or ".." in relative.parts:
            findings.append((name, "path leaves repository"))
            continue
        if path.is_symlink():
            findings.append((name, "symbolic link needs explicit release review"))
            continue
        if not path.is_file():
            findings.append((name, "tracked file is missing"))
            continue
        if any(part in FORBIDDEN_PARTS or part.endswith(".app") for part in relative.parts):
            findings.append((name, "private or generated directory"))
        if len(relative.parts) == 1:
            if name not in ALLOWED_ROOT_FILES:
                findings.append((name, "unexpected root file; review before adding to allowlist"))
        elif relative.parts[0] not in ALLOWED_DIRECTORIES:
            findings.append((name, "unexpected source directory"))
        if (path.suffix.lower() in FORBIDDEN_EXTENSIONS
                or ".sqlite-" in path.name or ".db-" in path.name
                or path.name in {".env", ".netrc"} or path.name.startswith(".env.")):
            findings.append((name, "private data, media, credential, or release archive"))
        if path.stat().st_size > 2 * 1024 * 1024:
            findings.append((name, "file larger than 2 MiB needs manual review"))
            continue
        data = path.read_bytes()
        if path.suffix.lower() in BINARY_ASSETS:
            if relative.parts[0] not in {"assets", "packaging"}:
                findings.append((name, "binary image outside presentation assets"))
            continue
        try:
            content = data.decode("utf-8")
        except UnicodeDecodeError:
            findings.append((name, "unexpected binary file"))
            continue
        for label, pattern in SECRET_PATTERNS:
            match = pattern.search(content)
            if match:
                line = content.count("\n", 0, match.start()) + 1
                # Do not print matching sensitive data into CI logs.
                findings.append((f"{name}:{line}", label))
    for name, message in findings:
        print(f"FAIL {name}: {message}")
    if findings:
        print(f"Public-source check failed: {len(findings)} finding(s).")
        return 1
    print(f"PASS: {len(files)} public source files checked; manual document/image and release-asset review is still required.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
