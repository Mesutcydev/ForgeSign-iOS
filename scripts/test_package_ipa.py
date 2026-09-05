import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path

from package_ipa import package_app, repack_ipa, validate_ipa


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / "ForgeSign.app"
        self.app.mkdir()
        (self.app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "ForgeSign", "CFBundlePackageType": "APPL",
            "CFBundleIdentifier": "com.forgesign.mobile",
        }))
        self.executable = self.app / "ForgeSign"
        self.executable.write_bytes(b"unchanged executable fixture")
        self.executable.chmod(0o755)
        self.source = self.root / "original.ipa"

    def test_pack_filters_metadata_and_preserves_mode(self):
        (self.app / "._ForgeSign").write_bytes(b"resource fork")
        (self.app / ".DS_Store").write_bytes(b"finder metadata")
        package_app(self.app, self.source)
        with zipfile.ZipFile(self.source) as archive:
            self.assertEqual(set(archive.namelist()), {
                "Payload/ForgeSign.app/ForgeSign", "Payload/ForgeSign.app/Info.plist"})
            self.assertEqual(archive.getinfo("Payload/ForgeSign.app/ForgeSign").external_attr >> 16 & 0o777, 0o755)

    def test_repack_removes_payload_decoy_without_changing_app(self):
        package_app(self.app, self.source)
        with zipfile.ZipFile(self.source, "a") as archive:
            archive.writestr("Payload/._ForgeSign.app", b"resource fork")
            archive.writestr("Payload/ForgeSign.app/._Info.plist", b"resource fork")
            archive.writestr("__MACOSX/._Payload", b"resource fork")
        with self.assertRaisesRegex(ValueError, "metadata"):
            validate_ipa(self.source)
        output = self.root / "clean.ipa"
        repack_ipa(self.source, output)
        with zipfile.ZipFile(self.source) as original, zipfile.ZipFile(output) as clean:
            for name in clean.namelist():
                self.assertEqual(original.read(name), clean.read(name))
                self.assertEqual(original.getinfo(name).external_attr, clean.getinfo(name).external_attr)

    def test_rejects_extra_payload_root(self):
        package_app(self.app, self.source)
        with zipfile.ZipFile(self.source, "a") as archive:
            archive.writestr("Payload/Other.app/Info.plist", b"unexpected app")
        with self.assertRaisesRegex(ValueError, "exactly one app"):
            validate_ipa(self.source)

    def test_rejects_traversal(self):
        package_app(self.app, self.source)
        with zipfile.ZipFile(self.source, "a") as archive:
            archive.writestr("Payload/../outside", b"unsafe")
        with self.assertRaisesRegex(ValueError, "Unsafe archive path"):
            validate_ipa(self.source)

    def test_rejects_non_executable_binary(self):
        self.executable.chmod(0o644)
        with self.assertRaisesRegex(ValueError, "executable file"):
            package_app(self.app, self.source)

    def test_refuses_to_overwrite_input(self):
        package_app(self.app, self.source)
        original = self.source.read_bytes()
        with self.assertRaises(FileExistsError):
            repack_ipa(self.source, self.source)
        self.assertEqual(original, self.source.read_bytes())


if __name__ == "__main__":
    unittest.main()
