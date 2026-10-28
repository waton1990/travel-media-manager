#!/usr/bin/env python3
"""Prepare a separately signed Mac App Store submission package; never upload it.

The source must already pass the local Developer ID sandbox verifier. All
distribution work happens in a copy, and the output directory must be new.
OID reference: Apple WWDR CPS v3.0, sections 4.11.5, 4.11.6 and 4.11.24.
"""

import argparse
import contextlib
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("travel_local_store", ROOT / "scripts/verify-store-app.py")
LOCAL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LOCAL)
BUNDLE_ID = "io.github.waton1990.travel-media-manager"
APP_SUBMISSION_OID = "1.2.840.113635.100.6.1.7"
INSTALLER_SUBMISSION_OID = "1.2.840.113635.100.6.1.8"
APP_NAMES = ("Apple Distribution: ", "3rd Party Mac Developer Application: ")
INSTALLER_NAMES = ("3rd Party Mac Developer Installer: ",)


def run(*arguments, data=None):
    result = subprocess.run(list(map(str, arguments)), input=data, capture_output=True)
    if result.returncode:
        message = result.stderr.decode(errors="replace").strip() or result.stdout.decode(errors="replace").strip()
        raise ValueError(f"{Path(str(arguments[0])).name}: {message}")
    return result.stdout


def identities():
    text = run("/usr/bin/security", "find-identity", "-v").decode()
    return {sha.upper(): name for sha, name in re.findall(r'\)\s+([0-9A-Fa-f]{40})\s+"([^"]+)"', text)}


def choose_identity(available, fingerprint, prefixes, team):
    if not fingerprint or not re.fullmatch(r"[0-9A-Fa-f]{40}", fingerprint):
        raise ValueError("Specify a 40-character certificate SHA-1 identity fingerprint")
    fingerprint = fingerprint.upper()
    name = available.get(fingerprint, "")
    if not name.startswith(prefixes) or not name.endswith(f"({team})"):
        raise ValueError("Requested valid distribution identity is missing, has the wrong purpose, or belongs to another team")
    return fingerprint, name


def certificate_for(fingerprint, name, oid):
    pem = run("/usr/bin/security", "find-certificate", "-a", "-c", name, "-p")
    for match in re.findall(rb"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", pem, re.S):
        der = run("/usr/bin/openssl", "x509", "-outform", "DER", data=match)
        if hashlib.sha1(der).hexdigest().upper() != fingerprint:
            continue
        details = run("/usr/bin/openssl", "x509", "-noout", "-text", data=match).decode()
        if not re.search(re.escape(oid) + r"\s*:", details):
            raise ValueError(f"Certificate does not have the required submission OID {oid}")
        return der
    raise ValueError("Could not match the selected identity to its public certificate")


def submission_requirement(fingerprint, team):
    if not re.fullmatch(r"[0-9A-F]{40}", fingerprint) or not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValueError("Invalid certificate fingerprint or Team ID")
    # .7 is the developer's submission certificate; .9 belongs to Apple's
    # later Mac App Store re-signature and must not be used here.
    return (f'=anchor apple generic and certificate leaf[field.{APP_SUBMISSION_OID}] exists '
            f'and certificate leaf = H"{fingerprint}" and certificate leaf[subject.OU] = "{team}"')


def validate_profile(profile, team, fingerprint, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    expires = profile.get("ExpirationDate")
    if not isinstance(expires, datetime.datetime):
        raise ValueError("Provisioning profile has no valid expiration date")
    if expires.tzinfo is None:
        expires = expires.replace(tzinfo=datetime.timezone.utc)
    if expires <= now or team not in profile.get("TeamIdentifier", []):
        raise ValueError("Provisioning profile is expired or belongs to another team")
    if profile.get("ProvisionedDevices") or profile.get("ProvisionsAllDevices"):
        raise ValueError("Use an App Store distribution profile, not a device/development profile")
    allowed = profile.get("Entitlements", {})
    if allowed.get("get-task-allow") or allowed.get("com.apple.security.get-task-allow"):
        raise ValueError("Development/debug provisioning profiles are not accepted")
    identifier = f"{team}.{BUNDLE_ID}"
    if allowed.get("com.apple.application-identifier") != identifier:
        raise ValueError("Use an explicit distribution profile for this exact bundle ID")
    if allowed.get("com.apple.developer.team-identifier") != team:
        raise ValueError("Provisioning profile team entitlement does not match")
    if fingerprint not in {hashlib.sha1(cert).hexdigest().upper() for cert in profile.get("DeveloperCertificates", [])}:
        raise ValueError("Provisioning profile does not authorize the selected signing certificate")
    return {"com.apple.application-identifier": identifier, "com.apple.developer.team-identifier": team}


def verify_submission(app, expected, fingerprint, team):
    requirement = submission_requirement(fingerprint, team)
    LOCAL.codesign("--verify", "--deep", "--strict", "--test-requirement", requirement, app)
    main = app / "Contents/MacOS/TravelMediaManager"
    helper = app / "Contents/Helpers/USBHelper.app/Contents/MacOS/iphone-usb-helper"
    if LOCAL.entitlements(app) != expected:
        raise ValueError("Main distribution entitlements do not match")
    binaries = LOCAL.macho_files(app)
    for path in binaries:
        LOCAL.codesign("--verify", "--strict", "--all-architectures", "--test-requirement", requirement, path)
        # codesign writes display diagnostics to stderr; use a separate bounded capture.
        inspected = subprocess.run(["/usr/bin/codesign", "--display", "--verbose=4", str(path)], capture_output=True, text=True, check=True)
        details = inspected.stdout + inspected.stderr
        flags = re.search(r"\bflags=0x([0-9a-fA-F]+)\b", details)
        if not flags or not int(flags.group(1), 16) & 0x10000 or not re.search(r"^Timestamp=.+$", details, re.M):
            raise ValueError(f"Missing hardened runtime or timestamp: {path.relative_to(app)}")
        wanted = expected if path == main else LOCAL.HELPER_ENTITLEMENTS if path == helper else {}
        if LOCAL.entitlements(path) != wanted:
            raise ValueError(f"Unexpected distribution entitlements: {path.relative_to(app)}")
    return len(binaries)


def verify_package(package, installer_name, certificate):
    report = run("/usr/sbin/pkgutil", "--check-signature", package).decode()
    status = re.search(r"^\s*Status:\s*(.+)$", report, re.M)
    # pkgutil labels the developer's Mac Installer Submission certificate
    # "Development"; Apple later re-signs Store distributions. The certificate
    # OID, exact name and SHA-256 checks below still distinguish its real purpose.
    accepted_statuses = {
        "signed by a certificate trusted by macOS",
        "signed by a certificate trusted by Mac OS X",
        "signed by a developer certificate issued by Apple (Development)",
    }
    if not status or status.group(1).strip() not in accepted_statuses:
        raise ValueError("Package signature was not reported as trusted: " + (status.group(1) if status else "missing status"))
    leaf = re.search(r"^\s*1\.\s*(.+)$", report, re.M)
    digest = re.search(r"SHA256 Fingerprint:\s*((?:[0-9A-Fa-f]{2}\s*){32})", report)
    if not leaf or leaf.group(1).strip() != installer_name or not digest:
        raise ValueError("Package signature does not identify the expected installer certificate")
    actual = re.sub(r"\s", "", digest.group(1)).lower()
    if actual != hashlib.sha256(certificate).hexdigest():
        raise ValueError("Package signer fingerprint differs from the selected installer certificate")
    return report


@contextlib.contextmanager
def staging_directory(parent):
    with tempfile.TemporaryDirectory(prefix=".store-distribution-", dir=parent) as temporary:
        staged = Path(temporary)
        try:
            yield staged
        except Exception as error:
            debug_root = ROOT / "work/store-distribution-failures"
            debug_root.mkdir(parents=True, exist_ok=True)
            debug = Path(tempfile.mkdtemp(prefix="failed-", dir=debug_root))
            if staged.exists():
                staged.rename(debug / "files")
            (debug / "failure.txt").write_text(str(error) + "\n")
            print(f"Unpublished diagnostic artifacts retained: {debug}", file=sys.stderr)
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--app-identity")
    parser.add_argument("--installer-identity")
    parser.add_argument("--team-id")
    parser.add_argument("--profile", type=Path)
    parser.add_argument("--entitlements", type=Path, default=ROOT / "packaging/store-app.entitlements")
    parser.add_argument("--check-only", action="store_true", help="Inspect local input and certificate inventory without signing or creating files")
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    expected = plistlib.loads(args.entitlements.read_bytes())
    LOCAL.verify(app, expected)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if not info.get("LSApplicationCategoryType"):
        raise ValueError("Candidate is missing LSApplicationCategoryType; rebuild it first")
    available = identities()
    if args.check_only:
        print(json.dumps({"localCandidateVerified": True, "appSubmissionIdentities": {k:v for k,v in available.items() if v.startswith(APP_NAMES)},
                          "installerSubmissionIdentities": {k:v for k,v in available.items() if v.startswith(INSTALLER_NAMES)},
                          "distributionSigned": False, "uploaded": False}, ensure_ascii=False, indent=2))
        return
    if not args.output or not args.team_id or not re.fullmatch(r"[A-Z0-9]{10}", args.team_id):
        raise ValueError("Specify a new --output directory and a valid --team-id")
    output = args.output.resolve()
    if os.path.lexists(output) or output.is_relative_to(app):
        raise ValueError("Output must be a new directory outside the source app")
    app_sha, app_name = choose_identity(available, args.app_identity, APP_NAMES, args.team_id)
    installer_sha, installer_name = choose_identity(available, args.installer_identity, INSTALLER_NAMES, args.team_id)
    certificate_for(app_sha, app_name, APP_SUBMISSION_OID)
    installer_cert = certificate_for(installer_sha, installer_name, INSTALLER_SUBMISSION_OID)
    if args.profile:
        profile = plistlib.loads(run("/usr/bin/security", "cms", "-D", "-i", args.profile))
        expected.update(validate_profile(profile, args.team_id, app_sha))
    output.parent.mkdir(parents=True, exist_ok=True)
    with staging_directory(output.parent) as staged:
        copied = staged / app.name
        run("/usr/bin/ditto", app, copied)
        # Do not retain an unrelated profile from the source candidate.
        embedded = copied / "Contents/embedded.provisionprofile"
        if embedded.exists():
            embedded.unlink()
        if args.profile:
            shutil.copyfile(args.profile, embedded)
        main_entitlements = copied / "Contents/Resources/StoreBuildEntitlements.plist"
        main_entitlements.write_bytes(plistlib.dumps(expected))
        helper_bundle = copied / "Contents/Helpers/USBHelper.app"
        main = copied / "Contents/MacOS/TravelMediaManager"
        helper = helper_bundle / "Contents/MacOS/iphone-usb-helper"
        signing = ["/usr/bin/codesign", "--force", "--sign", app_sha, "--options", "runtime", "--timestamp"]
        for path in LOCAL.macho_files(copied):
            if path not in (main, helper):
                run(*signing, path)
        for framework in sorted(copied.rglob("*.framework"), key=lambda p:len(p.parts), reverse=True):
            if not framework.is_symlink():
                run(*signing, framework)
        run(*signing, "--entitlements", ROOT / "packaging/store-helper.entitlements", helper_bundle)
        run(*signing, "--entitlements", main_entitlements, copied)
        count = verify_submission(copied, expected, app_sha, args.team_id)
        package = staged / f'TravelMediaManager-{info["CFBundleShortVersionString"]}-build{info["CFBundleVersion"]}-MacAppStore.pkg'
        run("/usr/bin/productbuild", "--sign", installer_sha, "--timestamp", "--component", copied, "/Applications", package)
        package_report = verify_package(package, installer_name, installer_cert)
        (staged / "package-signature.txt").write_text(package_report)
        (staged / "BUILD_INFO.json").write_text(json.dumps({
            "bundleIdentifier": BUNDLE_ID, "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
            "teamID": args.team_id, "appCertificateSHA1": app_sha, "installerCertificateSHA1": installer_sha,
            "verifiedMachOCount": count, "profileEmbedded": bool(args.profile), "package": package.name,
            "packageSHA256": hashlib.sha256(package.read_bytes()).hexdigest(), "uploaded": False,
            "appReviewAccepted": False,
        }, ensure_ascii=False, indent=2) + "\n")
        if os.path.lexists(output):
            raise ValueError("Output appeared while packaging; refusing to replace it")
        staged.rename(output)
    print(f"Signed submission files prepared: {output}")
    print("Not uploaded. Local package verification is not App Review acceptance.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException, subprocess.SubprocessError) as error:
        print(f"Store distribution packaging failed: {error}", file=sys.stderr)
        sys.exit(1)
