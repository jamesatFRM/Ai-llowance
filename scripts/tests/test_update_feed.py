import base64
import hashlib
import importlib.util
import pathlib
import tempfile
import unittest
import xml.etree.ElementTree as ET


SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "check-update-feed.py"
SPEC = importlib.util.spec_from_file_location("check_update_feed", SCRIPT)
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class PublishedUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.folder = pathlib.Path(self.temporary.name)
        self.tag = "v0.3.0-build216"
        self.name = "Ai-llowance-0.3.0-build216-macOS-universal.dmg"
        self.signature = base64.b64encode(bytes(range(64))).decode()
        self.feed = self.folder / "appcast.xml"
        self.write_feed(self.feed)
        self.write_archives()

    def write_feed(self, path, build=216, signature=None):
        root = ET.Element("rss")
        item = ET.SubElement(ET.SubElement(root, "channel"), "item")
        ET.SubElement(item, CHECK.SPARKLE + "version").text = str(build)
        ET.SubElement(item, CHECK.SPARKLE + "shortVersionString").text = "0.3.0"
        ET.SubElement(item, "enclosure", {
            "url": CHECK.RELEASE_URL + self.tag + "/" + self.name,
            "length": "4",
            CHECK.SPARKLE + "edSignature": signature or self.signature,
        })
        ET.ElementTree(root).write(path)

    def write_archives(self):
        entries = []
        for name in (self.name, self.name.removesuffix(".dmg") + ".zip"):
            (self.folder / name).write_bytes(b"test")
            entries.append(hashlib.sha256(b"test").hexdigest() + "  " + name)
        (self.folder / "SHA256SUMS").write_text("\n".join(entries) + "\n")

    def validate(self, previous=None, tag=None):
        CHECK.validate(self.feed, self.folder, tag or self.tag, previous)

    def change_enclosure(self, key, value):
        document = ET.parse(self.feed)
        document.find("./channel/item/enclosure").set(key, value)
        document.write(self.feed)

    def test_complete_release(self):
        self.validate()

    def test_interrupted_dmg_upload_is_not_published(self):
        (self.folder / self.name).unlink()
        with self.assertRaisesRegex(ValueError, "missing"):
            self.validate()

    def test_interrupted_zip_upload_is_not_published(self):
        (self.folder / (self.name.removesuffix(".dmg") + ".zip")).unlink()
        with self.assertRaisesRegex(ValueError, "missing"):
            self.validate()

    def test_corrupt_public_asset_is_not_published(self):
        (self.folder / self.name).write_bytes(b"oops")
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.validate()

    def test_feed_cannot_point_to_a_different_release(self):
        self.change_enclosure("url", CHECK.RELEASE_URL + "v0.3.0-build215/" + self.name)
        with self.assertRaisesRegex(ValueError, "download"):
            self.validate()

    def test_tag_must_match_embedded_build(self):
        with self.assertRaisesRegex(ValueError, "version"):
            self.validate(tag="v0.3.0-build217")

    def test_wrong_archive_length_is_rejected(self):
        self.change_enclosure("length", "8")
        with self.assertRaisesRegex(ValueError, "length"):
            self.validate()

    def test_unsigned_archive_is_rejected(self):
        self.change_enclosure(CHECK.SPARKLE + "edSignature", "")
        with self.assertRaisesRegex(ValueError, "signature"):
            self.validate()

    def test_manifest_cannot_escape_asset_directory(self):
        manifest = self.folder / "SHA256SUMS"
        manifest.write_text(manifest.read_text().replace(self.name, "../" + self.name))
        with self.assertRaisesRegex(ValueError, "manifest"):
            self.validate()

    def test_stale_job_cannot_roll_feed_back(self):
        previous = self.folder / "previous.xml"
        self.write_feed(previous, build=217)
        with self.assertRaisesRegex(ValueError, "older build"):
            self.validate(previous)

    def test_retry_cannot_change_published_build(self):
        previous = self.folder / "previous.xml"
        self.write_feed(previous, signature=base64.b64encode(b"a" * 64).decode())
        with self.assertRaisesRegex(ValueError, "already published"):
            self.validate(previous)

    def test_identical_retry_is_safe(self):
        previous = self.folder / "previous.xml"
        self.write_feed(previous)
        self.validate(previous)

    def test_newer_release_can_advance_feed(self):
        previous = self.folder / "previous.xml"
        self.write_feed(previous, build=215)
        self.validate(previous)


if __name__ == "__main__":
    unittest.main()
