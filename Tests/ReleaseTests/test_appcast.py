import base64
import importlib.util
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("appcast", ROOT / "scripts/generate-appcast.py")
appcast = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(appcast)


class AppcastTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.archive = Path(directory.name) / "SaneScan-1.2.3.dmg"
        self.archive.write_bytes(b"test update archive")
        self.feed = Path(directory.name) / "appcast.xml"
        self.info = {"SUPublicEDKey": base64.b64encode(bytes(32)).decode()}
        self.root = ET.Element("rss")
        self.item = ET.SubElement(ET.SubElement(self.root, "channel"), "item")
        ET.SubElement(self.item, f"{{{appcast.SPARKLE}}}version").text = "1.2.3"
        ET.SubElement(self.item, f"{{{appcast.SPARKLE}}}shortVersionString").text = "1.2.3"
        self.enclosure = ET.SubElement(self.item, "enclosure", {
            "url": f"{appcast.REPOSITORY}/releases/download/v1.2.3/{self.archive.name}",
            "length": str(self.archive.stat().st_size),
            f"{{{appcast.SPARKLE}}}edSignature": base64.b64encode(bytes(64)).decode(),
        })

    def validate(self):
        ET.ElementTree(self.root).write(self.feed)
        return appcast.validate_feed(self.feed, self.archive, "1.2.3", self.info)

    def test_accepts_consistent_release_metadata(self):
        signature, key = self.validate()
        self.assertEqual(len(base64.b64decode(signature)), 64)
        self.assertEqual(key, self.info["SUPublicEDKey"])

    def test_rejects_unsigned_archive(self):
        del self.enclosure.attrib[f"{{{appcast.SPARKLE}}}edSignature"]
        with self.assertRaises(ValueError):
            self.validate()

    def test_rejects_modified_archive_size(self):
        self.archive.write_bytes(b"changed update")
        with self.assertRaises(ValueError):
            self.validate()

    def test_rejects_another_download_host(self):
        self.enclosure.set("url", "https://example.com/update.dmg")
        with self.assertRaises(ValueError):
            self.validate()

    def test_rejects_incorrect_build_version(self):
        self.item.find(f"{{{appcast.SPARKLE}}}version").text = "1"
        with self.assertRaises(ValueError):
            self.validate()

    def test_only_accepts_stable_numeric_versions(self):
        for value in ["1", "1.2", "1.2.3"]:
            self.assertEqual(appcast.validate_version(value), value)
        for value in ["v1.2", "1.2-beta", "01.2", "1.2.3.4", "1\n2", ""]:
            with self.subTest(version=value), self.assertRaises(ValueError):
                appcast.validate_version(value)


if __name__ == "__main__":
    unittest.main()
