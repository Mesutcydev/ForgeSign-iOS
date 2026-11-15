#!/usr/bin/env python3
"""End-to-end signing check on generated fixtures (audit B4).

Builds a self-signed certificate, a P12, two provisioning profiles and an app
with an app extension, then drives the native bridge probe to sign and verify.
Nothing here needs an Apple account. The probe is built by
scripts/build_bridge_probe.sh; the tests skip when it is absent.
"""

import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import uuid
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROBE = Path(os.environ.get("FORGESIGN_PROBE", ROOT / "build/bridge-probe/bridge-probe"))
TEAM = "FIXTURE1234"
APP_ID = "com.example.fixture"
EXT_ID = "com.example.fixture.ext"
PASSWORD = "fixture"
# The openssl CLI that makes the fixture; CI points this at the brewed OpenSSL 3.
OPENSSL = os.environ.get("FORGESIGN_OPENSSL", "openssl")


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **kwargs)


def make_certificate(work: Path) -> None:
    run(OPENSSL, "req", "-x509", "-newkey", "rsa:2048", "-nodes",
        "-keyout", work / "key.pem", "-out", work / "cert.pem", "-days", "30",
        "-subj", f"/CN=ForgeSign Fixture/O=ForgeSign Tests/OU={TEAM}")
    # The certificate is also its own chain, so zsign finds the issuer.
    run(OPENSSL, "pkcs12", "-export", "-inkey", work / "key.pem", "-in", work / "cert.pem",
        "-certfile", work / "cert.pem", "-passout", f"pass:{PASSWORD}", "-out", work / "fixture.p12")
    (work / "password.txt").write_text(PASSWORD + "\n")


def make_profile(work: Path, name: str, app_id: str) -> Path:
    der = subprocess.run([OPENSSL, "x509", "-in", work / "cert.pem", "-outform", "DER"],
                         check=True, capture_output=True).stdout
    now = datetime.now(timezone.utc)
    plist = {
        "Name": name,
        "UUID": str(uuid.uuid4()),
        "TeamIdentifier": [TEAM],
        "TeamName": "ForgeSign Tests",
        "AppIDName": name,
        "CreationDate": now,
        "ExpirationDate": now + timedelta(days=30),
        "Platform": ["iOS"],
        "DeveloperCertificates": [der],
        "Entitlements": {
            "application-identifier": f"{TEAM}.{app_id}",
            "com.apple.developer.team-identifier": TEAM,
            "get-task-allow": True,
        },
    }
    raw = work / f"{name}.plist"
    raw.write_bytes(plistlib.dumps(plist, fmt=plistlib.FMT_XML))
    out = work / f"{name}.mobileprovision"
    run(OPENSSL, "smime", "-sign", "-binary", "-nodetach", "-in", raw,
        "-signer", work / "cert.pem", "-inkey", work / "key.pem", "-outform", "DER", "-out", out)
    return out


def make_binary(work: Path, out: Path) -> None:
    source = work / "main.c"
    source.write_text("int main(void) { return 0; }\n")
    run("xcrun", "--sdk", "iphoneos", "clang", "-arch", "arm64",
        "-miphoneos-version-min=16.0", "-o", out, source)


def info_plist(bundle_id: str, executable: str, package_type: str, extra=None) -> bytes:
    plist = {
        "CFBundleIdentifier": bundle_id,
        "CFBundleExecutable": executable,
        "CFBundleName": executable,
        "CFBundleVersion": "1",
        "CFBundleShortVersionString": "1.0",
        "CFBundlePackageType": package_type,
        "MinimumOSVersion": "16.0",
    }
    plist.update(extra or {})
    return plistlib.dumps(plist, fmt=plistlib.FMT_XML)


def make_unsigned_app(work: Path) -> Path:
    """An unsigned IPA-shaped folder: Payload/App.app with one extension."""
    stage = work / "stage"
    app = stage / "Payload" / "App.app"
    ext = app / "PlugIns" / "Ext.appex"
    ext.mkdir(parents=True)
    make_binary(work, app / "App")
    make_binary(work, ext / "Ext")
    # A framework and a resource file, so the seal check meets the layouts real apps use.
    framework = app / "Frameworks" / "Fx.framework"
    framework.mkdir(parents=True)
    make_binary(work, framework / "Fx")
    (framework / "Info.plist").write_bytes(info_plist(APP_ID + ".fx", "Fx", "FMWK"))
    (app / "Resource.txt").write_text("resource sealed with the app\n")
    (app / "Info.plist").write_bytes(info_plist(APP_ID, "App", "APPL"))
    (ext / "Info.plist").write_bytes(info_plist(EXT_ID, "Ext", "XPC!", {
        "NSExtension": {"NSExtensionPointIdentifier": "com.apple.share-services"},
    }))
    return stage


def zip_ipa(stage: Path, ipa: Path) -> None:
    with zipfile.ZipFile(ipa, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(stage.rglob("*")):
            if path.is_file():
                archive.write(path, path.relative_to(stage).as_posix())


class SigningFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not PROBE.exists():
            raise unittest.SkipTest(f"bridge probe not built: {PROBE}")
        cls.tmp = Path(tempfile.mkdtemp(prefix="forgesign-fixture-"))
        cls.work = cls.tmp / "work"
        cls.work.mkdir()
        make_certificate(cls.work)
        cls.app_profile = make_profile(cls.work, "App", APP_ID)
        cls.ext_profile = make_profile(cls.work, "Ext", EXT_ID)
        cls.unsigned = cls.tmp / "unsigned.ipa"
        zip_ipa(make_unsigned_app(cls.work), cls.unsigned)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(getattr(cls, "tmp", ""), ignore_errors=True)

    def sign(self, profiles, name):
        out = self.tmp / f"{name}.ipa"
        temp = self.tmp / f"temp-{name}"
        temp.mkdir(exist_ok=True)
        result = subprocess.run(
            [str(PROBE), "sign", str(self.unsigned), str(self.work / "fixture.p12"),
             str(self.work / "password.txt"), "\n".join(str(p) for p in profiles),
             APP_ID, str(out), str(temp), "profile"],
            capture_output=True, text=True)
        return result, out, temp

    def verify(self, ipa: Path, name: str) -> subprocess.CompletedProcess:
        temp = self.tmp / f"verify-{name}"
        temp.mkdir(exist_ok=True)
        return subprocess.run([str(PROBE), "verify", str(ipa), str(temp)],
                              capture_output=True, text=True)

    def test_extension_with_its_own_profile_signs_and_verifies(self):
        result, out, _ = self.sign([self.app_profile, self.ext_profile], "explicit")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        verified = self.verify(out, "explicit")
        self.assertEqual(verified.returncode, 0, verified.stdout)

    def test_extension_without_its_own_profile_verifies(self):
        # Audit S1: the audit says the app profile signs the extension, so the
        # verifier must accept that output too.
        result, out, _ = self.sign([self.app_profile], "fallback")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        verified = self.verify(out, "fallback")
        self.assertEqual(verified.returncode, 0, verified.stdout)

    def test_tampered_output_fails_verification(self):
        # Audit S2: a changed file under a sealed bundle must not verify.
        result, out, _ = self.sign([self.app_profile, self.ext_profile], "tamper-source")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        tampered = self.tmp / "tampered.ipa"
        with zipfile.ZipFile(out) as source, zipfile.ZipFile(tampered, "w", zipfile.ZIP_DEFLATED) as target:
            for item in source.infolist():
                data = source.read(item.filename)
                if item.filename == "Payload/App.app/Info.plist":
                    plist = plistlib.loads(data)
                    plist["ForgeSignTamper"] = "changed after signing"
                    data = plistlib.dumps(plist, fmt=plistlib.FMT_XML)
                target.writestr(item, data)
        verified = self.verify(tampered, "tampered")
        self.assertNotEqual(verified.returncode, 0, "a changed sealed file verified: " + verified.stdout)


if __name__ == "__main__":
    unittest.main()
