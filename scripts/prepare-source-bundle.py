#!/usr/bin/env python3
"""Fetch exact PyPI source archives from a lockfile without installing code.

This archives declared Python sources, not a complete binary-license audit.
Native runtime libraries and toolchain provenance require separate review.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import re
import tarfile
import urllib.parse
import urllib.request
from pathlib import Path

LIMIT = 256 * 1024 * 1024
USER_AGENT = "TravelMediaManager-source-preparation/1.0"


def public_tar_metadata(member: tarfile.TarInfo) -> tarfile.TarInfo:
    """Do not publish the packager's local account or filesystem timestamps."""
    member.uid = 0
    member.gid = 0
    member.uname = ""
    member.gname = ""
    member.mtime = 0
    member.pax_headers = {}
    return member


def fetch(url: str, limit: int = LIMIT) -> bytes:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https" or not (
        parsed.hostname == "pypi.org" or parsed.hostname == "files.pythonhosted.org"
    ):
        raise ValueError("Unapproved source host")
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=90) as response:
        final = urllib.parse.urlparse(response.geturl())
        if final.scheme != "https" or final.hostname not in {"pypi.org", "files.pythonhosted.org"}:
            raise ValueError("Unexpected redirect host")
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError("Source response exceeds size limit")
    return data


def fetch_source(item: tuple[str, str], destination: Path) -> dict:
    name, version = item
    record = {"name": name, "version": version}
    try:
        metadata_url = f"https://pypi.org/pypi/{urllib.parse.quote(name)}/{urllib.parse.quote(version)}/json"
        metadata = json.loads(fetch(metadata_url, 8 * 1024 * 1024))
        sources = sorted(
            (entry for entry in metadata["urls"] if entry["packagetype"] == "sdist"),
            key=lambda entry: entry["filename"],
        )
        if not sources:
            raise ValueError("No source distribution for this pinned version")
        entry = sources[0]
        filename = entry["filename"]
        if Path(filename).name != filename or filename in {".", ".."}:
            raise ValueError("Invalid source filename")
        expected = entry["digests"]["sha256"]
        path = destination / filename
        data = path.read_bytes() if path.exists() else fetch(entry["url"])
        if hashlib.sha256(data).hexdigest() != expected:
            raise ValueError("Source SHA-256 does not match PyPI metadata")
        if not path.exists():
            path.write_bytes(data)
        record.update({
            "status": "downloaded-and-verified",
            "filename": filename,
            "sourceURL": entry["url"],
            "metadataURL": metadata_url,
            "sha256": expected,
            "bytes": len(data),
            "licenseExpression": metadata["info"].get("license_expression"),
            "licenseMetadata": metadata["info"].get("license"),
            "projectURLs": metadata["info"].get("project_urls") or {},
        })
    except Exception as error:
        record.update({"status": "unavailable", "error": f"{type(error).__name__}: {error}"})
    return record


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", type=Path, default=Path(__file__).resolve().parent / "usb-helper-requirements.lock")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--workers", type=int, default=6)
    args = parser.parse_args()
    dependencies = []
    for line in args.lock.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = re.fullmatch(r"([A-Za-z0-9_.-]+)==([A-Za-z0-9_.+!-]+)", line)
        if not match:
            raise SystemExit(f"Unsupported lockfile line: {line}")
        dependencies.append(match.groups())
    destination = args.output / "source-archives"
    destination.mkdir(parents=True, exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, min(args.workers, 8))) as executor:
        records = list(executor.map(lambda item: fetch_source(item, destination), dependencies))
    records.sort(key=lambda item: item["name"].lower())
    missing = [item for item in records if item["status"] != "downloaded-and-verified"]
    manifest = {
        "scope": "Exact-version Python source distributions from the checked-in lockfile; does not certify native-library completeness.",
        "packages": records,
        "packageCount": len(records),
        "verifiedCount": len(records) - len(missing),
        "missingCount": len(missing),
    }
    (args.output / "python-source-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    archive_path = args.output / "python-dependency-sources.tar.gz"
    with tarfile.open(archive_path, "w:gz") as archive:
        archive.add(args.output / "python-source-manifest.json", arcname="python-source-manifest.json", filter=public_tar_metadata)
        for record in records:
            if record["status"] == "downloaded-and-verified":
                archive.add(destination / record["filename"], arcname="source-archives/" + record["filename"], filter=public_tar_metadata)
    digest = hashlib.sha256(archive_path.read_bytes()).hexdigest()
    (args.output / "python-dependency-sources.tar.gz.sha256").write_text(f"{digest}  {archive_path.name}\n", encoding="utf-8")
    print(json.dumps({"packages": len(records), "verified": len(records) - len(missing), "missing": missing, "archiveBytes": archive_path.stat().st_size}, ensure_ascii=False, indent=2))
    return 1 if missing else 0


if __name__ == "__main__":
    raise SystemExit(main())
