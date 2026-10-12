import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/update-homebrew-cask.py"
SPEC = importlib.util.spec_from_file_location("homebrew_release", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class HomebrewReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.archive = self.directory / "Headroom.zip"
        self.archive.write_bytes(b"published release archive")
        self.checksum = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.checksums = self.directory / "SHA256SUMS"
        self.checksums.write_text("%s  Headroom.zip\n%s  Headroom.dmg\n" % (self.checksum, "a" * 64))
        self.output = self.directory / "Casks/headroom.rb"
        self.metadata = self.directory / "release.json"
        self.set_release("v1.2.0")

    def set_release(self, tag):
        self.metadata.write_text(json.dumps({"tagName": tag, "isDraft": False, "isPrerelease": False}))

    def update(self, version="v1.2.0"):
        MODULE.update(version, self.checksums, self.archive, self.output, self.metadata)

    def assert_rejected_without_change(self, version="v1.2.0"):
        before = self.output.read_bytes() if self.output.exists() else None
        with self.assertRaises(ValueError):
            self.update(version)
        after = self.output.read_bytes() if self.output.exists() else None
        self.assertEqual(before, after)

    def test_first_release_pins_version_and_verified_archive(self):
        self.update()
        content = self.output.read_text()
        self.assertIn('version "1.2.0"', content)
        self.assertIn('sha256 "%s"' % self.checksum, content)
        self.assertIn('releases/download/v#{version}/Headroom.zip', content)
        self.assertIn('depends_on macos: :ventura', content)
        self.assertIn('depends_on arch: :arm64', content)
        self.assertNotIn("no_check", content)
        self.assertNotIn("zap", content)

    def test_identical_retry_does_not_rewrite(self):
        self.update()
        timestamp = self.output.stat().st_mtime_ns
        self.update()
        self.assertEqual(timestamp, self.output.stat().st_mtime_ns)

    def test_upgrade_compares_versions_numerically(self):
        self.set_release("v1.9.0")
        self.update("1.9.0")
        self.set_release("v1.10.0")
        self.update("v1.10.0")
        self.assertIn('version "1.10.0"', self.output.read_text())
        self.set_release("v1.9.1")
        self.assert_rejected_without_change("1.9.1")

    def test_only_matching_published_stable_metadata_is_accepted(self):
        self.update()
        valid = {"tagName": "v1.2.0", "isDraft": False, "isPrerelease": False}
        invalid = [None, [], {}, dict(valid, tagName="v1.3.0"), dict(valid, tagName="1.2.0"),
                   dict(valid, isDraft=True), dict(valid, isPrerelease=True),
                   dict(valid, isDraft=0), dict(valid, isPrerelease="false"),
                   {key: value for key, value in valid.items() if key != "isDraft"},
                   {key: value for key, value in valid.items() if key != "isPrerelease"}]
        for metadata in invalid:
            with self.subTest(metadata=metadata):
                self.metadata.write_text(json.dumps(metadata))
                self.assert_rejected_without_change()
        self.metadata.write_text("not JSON")
        self.assert_rejected_without_change()

    def test_unknown_metadata_fields_do_not_break_publication(self):
        self.metadata.write_text(json.dumps({"tagName": "v1.2.0", "isDraft": False,
                                             "isPrerelease": False, "futureField": "extra"}))
        self.update()
        self.assertTrue(self.output.exists())

    def test_missing_metadata_cannot_create_a_cask(self):
        self.metadata.unlink()
        with self.assertRaises(OSError):
            self.update()
        self.assertFalse(self.output.exists())

    def test_same_version_cannot_replace_published_bytes(self):
        self.update()
        self.archive.write_bytes(b"different release archive")
        self.checksums.write_text(hashlib.sha256(self.archive.read_bytes()).hexdigest() + "  Headroom.zip\n")
        self.assert_rejected_without_change()

    def test_checksum_must_be_present_valid_and_unique(self):
        for content in ("", "a" * 64 + "  Headroom.dmg\n", "invalid  Headroom.zip\n",
                        "%s  Headroom.zip\n%s  Headroom.zip\n" % (self.checksum, self.checksum),
                        "%s extra Headroom.zip\n" % self.checksum):
            with self.subTest(content=content):
                self.checksums.write_text(content)
                self.assert_rejected_without_change()

    def test_modified_archive_is_rejected(self):
        self.archive.write_bytes(b"corrupt download")
        self.assert_rejected_without_change()

    def test_only_stable_versions_are_accepted(self):
        for version in ("latest", "1.2", "v1.2.3-beta", "01.2.3", '1.2.3"', "v1.2.3\n"):
            with self.subTest(version=version):
                self.assert_rejected_without_change(version)

    def test_existing_malformed_cask_is_not_overwritten(self):
        self.output.parent.mkdir()
        self.output.write_text('cask "headroom" do\nend\n')
        self.assert_rejected_without_change()


if __name__ == "__main__":
    unittest.main()
