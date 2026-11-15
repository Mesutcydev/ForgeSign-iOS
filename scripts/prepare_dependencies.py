#!/usr/bin/env python3
"""Build pinned OpenSSL and prepare the authentication-enabled AltSign package.

Only generated build/dependencies and vendor/{AltSign,openssl/OpenSSL.xcframework}
outputs are replaced. No Git history, Apple account, Keychain or device is used.
"""
import argparse
import hashlib
import json
import os
import platform
from pathlib import Path, PurePosixPath
import plistlib
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / "scripts/dependencies"
LOCK = json.loads((CONFIG / "lock.json").read_text())
PATCH_PINS = json.loads((CONFIG / "patches.json").read_text())
BUILD = ROOT / "build/dependencies"
VENDOR = ROOT / "vendor"


def run(args, cwd=None, env=None):
    subprocess.run([str(arg) for arg in args], cwd=cwd, env=env, check=True)


def output(args):
    return subprocess.check_output(args, text=True).strip()


def digest(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def archive(name, cache):
    pin = LOCK[name]
    path = cache / f"{name}-{pin['sha256'][:16]}.tar.gz"
    if path.exists() and digest(path) == pin["sha256"]:
        return path
    partial = path.with_suffix(".partial")
    try:
        print(f"Downloading pinned {name} source", flush=True)
        for attempt in range(3):
            try:
                with urllib.request.urlopen(pin["url"], timeout=120) as source, partial.open("wb") as file:
                    shutil.copyfileobj(source, file)
                break
            except (urllib.error.URLError, TimeoutError) as error:
                if isinstance(error, urllib.error.HTTPError) and error.code not in (408, 429, 500, 502, 503, 504):
                    raise
                if attempt == 2:
                    raise
                print(f"Retrying {name} source download after a temporary network failure", flush=True)
                time.sleep(2 ** attempt)
        if digest(partial) != pin["sha256"]:
            raise RuntimeError(f"Checksum mismatch for {name}; dependency was not accepted")
        partial.replace(path)
    finally:
        partial.unlink(missing_ok=True)
    return path


def pinned_digest(name):
    """Digest of a patch or source file, refused unless it matches scripts/dependencies/patches.json."""
    pin = PATCH_PINS[name]
    actual = digest(ROOT / pin["file"])
    if actual != pin["sha256"]:
        raise RuntimeError(f"{pin['file']} does not match its pinned digest")
    return actual


def tree_digest(root, skip=()):
    """SHA-256 over every file and symlink under root, in a stable order.
    Symlinks are recorded, not followed, so a link cannot pull in other files."""
    entries = []
    for directory, subdirectories, files in os.walk(root, followlinks=False):
        for name in subdirectories + files:
            if name not in skip:
                entries.append(Path(directory, name))
    hasher = hashlib.sha256()
    for path in sorted(entries):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            hasher.update(f"link {relative} -> {os.readlink(path)}\0".encode())
        elif path.is_file():
            hasher.update(f"file {relative}\0".encode())
            with path.open("rb") as file:
                hasher.update(hashlib.file_digest(file, "sha256").digest())
    return hasher.hexdigest()


def extract(source, destination):
    """Extract checked upstream archives, rejecting traversal and special files."""
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(source) as archive_file:
        for member in archive_file.getmembers():
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts:
                raise RuntimeError("Unsafe path in dependency source archive")
            if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
                raise RuntimeError("Special file in dependency source archive")
        archive_file.extractall(destination, filter="data")
    children = list(destination.iterdir())
    if len(children) != 1 or not children[0].is_dir():
        raise RuntimeError("Expected a single source root in dependency archive")
    return children[0]


HOST_ARCH = platform.machine()
if HOST_ARCH not in ("arm64", "x86_64"):
    raise RuntimeError(f"Unsupported macOS host architecture: {HOST_ARCH}")
SLICES = [
    ("ios-arm64", "iphoneos", "ios64-xcrun", "arm64", "-miphoneos-version-min=16.0", "iPhoneOS"),
    (f"ios-{HOST_ARCH}-simulator", "iphonesimulator", f"iossimulator-{HOST_ARCH}-xcrun", HOST_ARCH, "-mios-simulator-version-min=16.0", "iPhoneSimulator"),
    (f"macos-{HOST_ARCH}", "macosx", f"darwin64-{HOST_ARCH}", HOST_ARCH, "-mmacosx-version-min=15.0", "MacOSX"),
]


def build_openssl(source, jobs):
    version = LOCK["openssl"]["version"]
    toolchain = output(["xcodebuild", "-version"])
    sdk_versions = {sdk: output(["xcrun", "--sdk", sdk, "--show-sdk-version"]) for _, sdk, *_ in SLICES}
    state = {
        "source": LOCK["openssl"], "xcode": toolchain, "sdks": sdk_versions,
        "initializer_sha256": pinned_digest("openssl_initializer"),
        "recipe_sha256": digest(Path(__file__)), "host_architecture": HOST_ARCH,
        "configuration": ["no-shared", "no-module", "no-tests", "no-apps", "enable-legacy"],
    }
    target = VENDOR / "openssl/OpenSSL.xcframework"
    stamp = VENDOR / "openssl/build-info.json"
    # Reuse only when the stamp matches AND the framework on disk is still the one
    # that was built (audit B10): a local edit under vendor/ must trigger a rebuild.
    recorded = json.loads(stamp.read_text()) if stamp.exists() else {}
    if target.exists() and recorded.get("output_sha256") == tree_digest(target) and \
            {k: v for k, v in recorded.items() if k != "output_sha256"} == state:
        print("Pinned OpenSSL framework is current", flush=True)
        return

    frameworks = []
    for identifier, sdk, configure_target, arch, deployment, platform in SLICES:
        print(f"Building OpenSSL {version}: {identifier}", flush=True)
        directory = BUILD / identifier
        shutil.rmtree(directory, ignore_errors=True)
        directory.mkdir(parents=True)
        prefix = directory / "staged/forgesign/openssl"
        sdk_path = output(["xcrun", "--sdk", sdk, "--show-sdk-path"])
        environment = os.environ.copy()
        environment["SDKROOT"] = sdk_path
        environment["SOURCE_DATE_EPOCH"] = str(LOCK["openssl"]["source_date_epoch"])
        environment["ZERO_AR_DATE"] = "1"
        environment["CFLAGS"] = shlex.join(["-O2", "-fPIC", "-isysroot", sdk_path, deployment])
        run(["perl", source / "Configure", configure_target, *state["configuration"],
             "--prefix=/forgesign/openssl", "--openssldir=/forgesign/openssl", "--libdir=lib"], cwd=directory, env=environment)
        run(["make", f"-j{jobs}", "build_libs"], cwd=directory, env=environment)
        run(["make", f"DESTDIR={directory / 'staged'}", "install_dev"], cwd=directory, env=environment)

        framework = directory / "OpenSSL.framework"
        headers = framework / "Headers"
        headers.mkdir(parents=True)
        shutil.copytree(prefix / "include/openssl", headers / "openssl")
        (headers / "OpenSSL.h").write_text(
            "#include <openssl/opensslv.h>\n#include <openssl/provider.h>\n"
            "int forgesign_openssl_providers_ready(void);\n")
        modules = framework / "Modules"
        modules.mkdir()
        (modules / "module.modulemap").write_text('framework module OpenSSL { umbrella header "OpenSSL.h" export * }\n')
        run(["xcrun", "--sdk", sdk, "clang", "-dynamiclib", "-arch", arch,
             "-isysroot", sdk_path, deployment,
             "-install_name", "@rpath/OpenSSL.framework/OpenSSL",
             "-current_version", version, "-compatibility_version", "3.0.0",
             "-I", prefix / "include", CONFIG / "openssl_init.c",
             f"-Wl,-force_load,{prefix / 'lib/libssl.a'}",
             f"-Wl,-force_load,{prefix / 'lib/libcrypto.a'}",
             "-o", framework / "OpenSSL"])
        info = {
            "CFBundleExecutable": "OpenSSL", "CFBundleIdentifier": "org.openssl.OpenSSL",
            "CFBundleName": "OpenSSL", "CFBundlePackageType": "FMWK",
            "CFBundleVersion": version, "CFBundleShortVersionString": version,
            "CFBundleSupportedPlatforms": [platform],
            "MinimumOSVersion": "15.0" if sdk == "macosx" else "16.0",
        }
        (framework / "Info.plist").write_bytes(plistlib.dumps(info))
        frameworks.append(framework)

    with tempfile.TemporaryDirectory(dir=BUILD) as temporary:
        assembled = Path(temporary) / "OpenSSL.xcframework"
        command = ["xcodebuild", "-create-xcframework"]
        for framework in frameworks:
            command += ["-framework", framework]
        run(command + ["-output", assembled])
        target.parent.mkdir(parents=True, exist_ok=True)
        previous = target.with_suffix(".previous")
        shutil.rmtree(previous, ignore_errors=True)
        if target.exists():
            target.rename(previous)
        assembled.rename(target)
        shutil.rmtree(previous, ignore_errors=True)
    # Keep source license and notices next to the generated framework.
    shutil.copy2(source / "LICENSE.txt", target.parent / "LICENSE.txt")
    for name in ("NOTICE", "NOTICE.txt", "NOTICE.md"):
        if (source / name).exists():
            shutil.copy2(source / name, target.parent / name)
    stamp.write_text(json.dumps({**state, "output_sha256": tree_digest(target)}, indent=2) + "\n")


def prepare_altsign(archives):
    state = {name: LOCK[name] for name in ("altsign", "ldid", "libplist")}
    state["auth_patch_sha256"] = pinned_digest("altsign_gsa_http503")
    state["compatibility_patch_sha256"] = pinned_digest("altsign_compatibility")
    target = VENDOR / "AltSign"
    marker = target / ".forgesign-prepared.json"
    # Reuse only when the tree on disk is still the one prepared (audit B10).
    recorded = json.loads(marker.read_text()) if marker.exists() else {}
    if target.exists() and recorded.get("tree_sha256") == tree_digest(target, skip=(marker.name,)) and \
            {k: v for k, v in recorded.items() if k != "tree_sha256"} == state:
        print("Pinned AltSign source is current", flush=True)
        return
    with tempfile.TemporaryDirectory(dir=BUILD) as temporary:
        base = Path(temporary)
        package = extract(archives["altsign"], base / "altsign")
        ldid = extract(archives["ldid"], base / "ldid")
        libplist = extract(archives["libplist"], base / "libplist")
        shutil.copytree(ldid, package / "Dependencies/ldid", dirs_exist_ok=True)
        shutil.copytree(libplist, package / "Dependencies/ldid/libplist", dirs_exist_ok=True)
        run(["git", "apply", "--unsafe-paths", "--directory", package, VENDOR / "altsign-gsa-http503.patch"])
        run(["git", "apply", "--unsafe-paths", "--directory", package, CONFIG / "altsign-compatibility.patch"])
        framework_root = package / "Dependencies/OpenSSL/Frameworks"
        framework_root.mkdir(parents=True, exist_ok=True)
        (framework_root / "OpenSSL.xcframework").symlink_to("../../../../openssl/OpenSSL.xcframework")
        # Preserve the pinned package's legacy include paths without another copy
        # of cryptography. All clients link the same updated dynamic framework.
        include_root = package / "Dependencies/OpenSSL/ios"
        include_root.mkdir()
        (include_root / "include").symlink_to("../../../../openssl/OpenSSL.xcframework/ios-arm64/OpenSSL.framework/Headers")
        prepared_tree = tree_digest(package, skip=(".forgesign-prepared.json",))
        (package / ".forgesign-prepared.json").write_text(
            json.dumps({**state, "tree_sha256": prepared_tree}, indent=2) + "\n")
        if target.exists():
            if not marker.exists():
                raise RuntimeError("Refusing to replace an unmanaged vendor/AltSign directory")
            shutil.rmtree(target)
        shutil.move(package, target)


def main():
    if sys.version_info < (3, 12):
        raise SystemExit("Dependency preparation requires Python 3.12 or newer.")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jobs", type=int, default=min(8, os.cpu_count() or 4))
    parser.add_argument("--cache", type=Path, default=BUILD / "downloads")
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    BUILD.mkdir(parents=True, exist_ok=True)
    args.cache.mkdir(parents=True, exist_ok=True)
    archives = {name: archive(name, args.cache) for name in LOCK}
    source_path = BUILD / "source"
    source = source_path / f"openssl-{LOCK['openssl']['version']}"
    # Always extract from the archive whose digest was just verified. An old extracted
    # tree is never trusted, because nothing checks it (audit B10).
    shutil.rmtree(source_path, ignore_errors=True)
    extract(archives["openssl"], source_path)
    build_openssl(source, args.jobs)
    prepare_altsign(archives)
    print("Dependencies prepared. Run xcodegen generate.", flush=True)


if __name__ == "__main__":
    main()
