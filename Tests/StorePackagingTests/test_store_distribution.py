import datetime
import hashlib
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("store_distribution", ROOT / "scripts/package-store-distribution.py")
DIST = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DIST)
TEAM = "ABCDE12345"
SHA = "A" * 40


class DistributionTests(unittest.TestCase):
    def test_rejects_developer_id_as_submission_identity(self):
        with self.assertRaisesRegex(ValueError, "wrong purpose"):
            DIST.choose_identity({SHA: f"Developer ID Application: Test ({TEAM})"}, SHA, DIST.APP_NAMES, TEAM)

    def test_accepts_both_supported_submission_names(self):
        for prefix in DIST.APP_NAMES:
            name = f"{prefix}Test ({TEAM})"
            self.assertEqual(DIST.choose_identity({SHA:name}, SHA, DIST.APP_NAMES, TEAM), (SHA,name))

    def test_rejects_mixed_team(self):
        with self.assertRaises(ValueError):
            DIST.choose_identity({SHA:"Apple Distribution: Test (XXXXX12345)"}, SHA, DIST.APP_NAMES, TEAM)

    def test_requirement_is_submission_not_apple_resigning_oid(self):
        requirement = DIST.submission_requirement(SHA, TEAM)
        self.assertIn("1.2.840.113635.100.6.1.7]", requirement)
        self.assertNotIn("1.2.840.113635.100.6.1.9]", requirement)
        self.assertIn(f'certificate leaf = H"{SHA}"', requirement)
        self.assertIn("anchor apple generic", requirement)

    def test_requirement_rejects_injected_arguments(self):
        with self.assertRaises(ValueError):
            DIST.submission_requirement('" or true', TEAM)

    def profile(self):
        cert = b"synthetic-test-public-certificate"
        return {"ExpirationDate": datetime.datetime(2099,1,1), "TeamIdentifier":[TEAM],
                "DeveloperCertificates":[cert], "Entitlements":{
                    "com.apple.application-identifier": f"{TEAM}.{DIST.BUNDLE_ID}",
                    "com.apple.developer.team-identifier": TEAM,
                }}, hashlib.sha1(cert).hexdigest().upper()

    def test_valid_profile_adds_only_identity_claims(self):
        profile, fingerprint = self.profile()
        claims = DIST.validate_profile(profile, TEAM, fingerprint)
        self.assertEqual(set(claims), {"com.apple.application-identifier", "com.apple.developer.team-identifier"})

    def test_rejects_expired_profile(self):
        profile, fingerprint = self.profile()
        profile["ExpirationDate"] = datetime.datetime(2000,1,1)
        with self.assertRaisesRegex(ValueError, "expired"):
            DIST.validate_profile(profile, TEAM, fingerprint)

    def test_rejects_wrong_certificate_in_profile(self):
        profile, _ = self.profile()
        with self.assertRaisesRegex(ValueError, "does not authorize"):
            DIST.validate_profile(profile, TEAM, SHA)

    def test_rejects_development_profile(self):
        profile, fingerprint = self.profile()
        profile["ProvisionedDevices"] = ["synthetic-device"]
        with self.assertRaisesRegex(ValueError, "device/development"):
            DIST.validate_profile(profile, TEAM, fingerprint)

    def test_rejects_wildcard_profile(self):
        profile, fingerprint = self.profile()
        profile["Entitlements"]["com.apple.application-identifier"] = f"{TEAM}.*"
        with self.assertRaisesRegex(ValueError, "exact bundle ID"):
            DIST.validate_profile(profile, TEAM, fingerprint)

    def test_installer_checks_the_leaf_fingerprint(self):
        cert = b"synthetic installer certificate"
        name = f"3rd Party Mac Developer Installer: Test ({TEAM})"
        digest = hashlib.sha256(cert).hexdigest().upper()
        spaced = " ".join(digest[i:i+2] for i in range(0,64,2))
        report = f"Status: signed by a certificate trusted by macOS\nCertificate Chain:\n  1. {name}\n    SHA256 Fingerprint:\n      {spaced}\n  2. Apple Worldwide Developer Relations Certification Authority\n"
        with patch.object(DIST, "run", return_value=report.encode()):
            self.assertEqual(DIST.verify_package(Path("fixture.pkg"), name, cert), report)
            with self.assertRaisesRegex(ValueError, "fingerprint differs"):
                DIST.verify_package(Path("fixture.pkg"), name, b"different")
        store_report = report.replace("signed by a certificate trusted by macOS", "signed by a developer certificate issued by Apple (Development)")
        with patch.object(DIST, "run", return_value=store_report.encode()):
            self.assertEqual(DIST.verify_package(Path("fixture.pkg"), name, cert), store_report)

    def test_rejects_untrusted_package(self):
        with patch.object(DIST, "run", return_value=b"Status: signed by an untrusted certificate\n"):
            with self.assertRaisesRegex(ValueError, "not reported as trusted"):
                DIST.verify_package(Path("fixture.pkg"), "test", b"test")


if __name__ == "__main__":
    unittest.main()
