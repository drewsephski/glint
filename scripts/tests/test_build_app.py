"""Exercise signing selection and safe replacement without compiling or touching the Keychain."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]


class BuildAppTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="glint-build-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for directory in ("scripts", "packaging", "build", "bin", "mock-bin"):
            (self.root / directory).mkdir()
        shutil.copy(REPO / "scripts/build-app.sh", self.root / "scripts/build-app.sh")
        shutil.copy(REPO / "packaging/Info.plist", self.root / "packaging/Info.plist")
        (self.root / "build/AppIcon.icns").touch()
        for product in ("GlintApp", "glint"):
            (self.root / "bin" / product).write_text("test executable")
        self.mock("swift", 'if "--show-bin-path" in sys.argv: print(os.getcwd() + "/bin")')
        self.mock("security", 'print(os.environ.get("TEST_IDENTITIES", ""))')
        self.mock("codesign", '''
with open("signing.jsonl", "a") as output:
    output.write(json.dumps(sys.argv[1:]) + "\\n")
if os.environ.get("TEST_SIGN_FAILURE"): sys.exit(1)
''')

    def mock(self, name, code):
        path = self.root / "mock-bin" / name
        path.write_text("#!/usr/bin/env python3\nimport sys, os, json\n" + code + "\n")
        path.chmod(0o755)

    def build(self, **overrides):
        env = {key: value for key, value in os.environ.items() if not key.startswith("GLINT_")}
        env.update(PATH=str(self.root / "mock-bin") + os.pathsep + env["PATH"], **overrides)
        return subprocess.run(["bash", "scripts/build-app.sh", "debug"], cwd=self.root, env=env,
                              capture_output=True, text=True, timeout=15)

    def bundle_id(self):
        with (self.root / "build/Glint.app/Contents/Info.plist").open("rb") as file:
            return plistlib.load(file)["CFBundleIdentifier"]

    def signatures(self):
        return [json.loads(line) for line in (self.root / "signing.jsonl").read_text().splitlines()]

    def test_development_certificate_keeps_separate_identity(self):
        result = self.build(TEST_IDENTITIES='1) HASH "Apple Development: Test (TEAM)"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.bundle_id(), "dev.glint.Glint.dev")
        signatures = self.signatures()
        self.assertIn("Apple Development: Test (TEAM)", signatures[0])
        self.assertIn("dev.glint.Glint.dev.cli", signatures[0])
        self.assertIn("--verify", signatures[-1])

    def test_missing_or_ambiguous_identity_requires_explicit_choice(self):
        for identities in ("", '1) HASH "Apple Development: One"\n2) HASH "Apple Development: Two"'):
            with self.subTest(identities=identities):
                self.assertNotEqual(self.build(TEST_IDENTITIES=identities).returncode, 0)
                self.assertFalse((self.root / "signing.jsonl").exists())

    def test_distribution_retains_release_identity_and_timestamp(self):
        result = self.build(GLINT_SIGN_IDENTITY="Developer ID Application: Test")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.bundle_id(), "dev.glint.Glint")
        self.assertIn("--timestamp", self.signatures()[0])

    def test_adhoc_is_opt_in_and_never_distribution(self):
        self.assertNotEqual(self.build(GLINT_SIGN_IDENTITY="-").returncode, 0)
        result = self.build(GLINT_ALLOW_ADHOC="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ad-hoc", result.stderr)
        self.assertEqual(self.bundle_id(), "dev.glint.Glint.dev")
        self.assertIn("-", self.signatures()[0])

    def test_failed_signing_preserves_previous_app(self):
        previous = self.root / "build/Glint.app"
        previous.mkdir()
        (previous / "sentinel").write_text("working app")
        result = self.build(GLINT_DEV_SIGN_IDENTITY="Apple Development: Test", TEST_SIGN_FAILURE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((previous / "sentinel").read_text(), "working app")
        self.assertEqual(list((self.root / "build").glob(".glint-app.*")), [])


if __name__ == "__main__":
    unittest.main()
