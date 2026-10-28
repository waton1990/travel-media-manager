import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("verify_store_app", ROOT / "scripts/verify-store-app.py")
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)


class StorePackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / "Candidate.app"
        self.main = self.app / "Contents/MacOS/TravelMediaManager"
        self.helper = self.app / "Contents/Helpers/USBHelper.app/Contents/MacOS/iphone-usb-helper"
        self.library = self.helper.parent.parent / "Frameworks/libpython.dylib"
        for path in (self.main, self.helper, self.library):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"\xcf\xfa\xed\xfe" + b"fixture")
        self.resources = self.app / "Contents/Resources"
        self.resources.mkdir()
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "io.github.waton1990.travel-media-manager",
            "CFBundleExecutable": "TravelMediaManager",
        }))
        (self.resources / "PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps({
            "NSPrivacyTracking": False,
            "NSPrivacyAccessedAPITypes": [],
        }))
        self.expected = plistlib.loads((ROOT / "packaging/store-app.entitlements").read_bytes())

    def entitlements(self, path):
        if path in (self.app, self.main):
            return self.expected
        if path == self.helper:
            return VERIFY.HELPER_ENTITLEMENTS
        return {}

    def run_verification(self, entitlements=None):
        with patch.object(VERIFY, "codesign", return_value=b""), \
             patch.object(VERIFY, "developer_identity", return_value=("TEAM", "Developer ID Application: Test")), \
             patch.object(VERIFY, "entitlements", side_effect=entitlements or self.entitlements):
            return VERIFY.verify(self.app, self.expected)

    def test_expected_layout_and_entitlements(self):
        self.assertEqual(self.run_verification(), 3)

    def test_rejects_unsandboxed_main(self):
        self.expected.pop("com.apple.security.app-sandbox")
        with self.assertRaisesRegex(ValueError, "Missing required main entitlement"):
            self.run_verification()

    def test_rejects_helper_missing_inheritance(self):
        def grants(path):
            return {} if path == self.helper else self.entitlements(path)
        with self.assertRaisesRegex(ValueError, "Unexpected code entitlements"):
            self.run_verification(grants)

    def test_rejects_process_permissions_on_library(self):
        def grants(path):
            return VERIFY.HELPER_ENTITLEMENTS if path == self.library else self.entitlements(path)
        with self.assertRaisesRegex(ValueError, "Unexpected code entitlements"):
            self.run_verification(grants)

    def test_rejects_changed_main_permissions(self):
        def grants(path):
            return {} if path == self.app else self.entitlements(path)
        with self.assertRaisesRegex(ValueError, "Main signature entitlements differ"):
            self.run_verification(grants)

    def test_rejects_missing_runtime(self):
        self.library.unlink()
        with self.assertRaisesRegex(ValueError, "Bundled Python runtime is missing"):
            self.run_verification()

    def test_rejects_external_symlink(self):
        external = Path(self.temp.name) / "outside"
        external.write_text("outside")
        (self.resources / "link").symlink_to(external)
        with self.assertRaisesRegex(ValueError, "Symbolic link leaves the app"):
            self.run_verification()

    def test_rejects_duplicate_helper_in_resources(self):
        (self.resources / "USBHelper").mkdir()
        with self.assertRaisesRegex(ValueError, "helper must be in Contents/Helpers"):
            self.run_verification()

    def test_rejects_missing_privacy_manifest(self):
        (self.resources / "PrivacyInfo.xcprivacy").unlink()
        with self.assertRaises(FileNotFoundError):
            self.run_verification()

    def test_does_not_ignore_signature_failure(self):
        with patch.object(VERIFY, "codesign", side_effect=ValueError("invalid signature")):
            with self.assertRaisesRegex(ValueError, "invalid signature"):
                VERIFY.verify(self.app, self.expected)

    def test_rejects_mixed_signing_teams(self):
        with patch.object(VERIFY, "codesign", return_value=b""), \
             patch.object(VERIFY, "entitlements", side_effect=self.entitlements), \
             patch.object(VERIFY, "developer_identity", side_effect=lambda path: ("OTHER" if path == self.library else "TEAM", "Developer ID Application: Test")):
            with self.assertRaisesRegex(ValueError, "different signing team"):
                VERIFY.verify(self.app, self.expected)


if __name__ == "__main__":
    unittest.main()
