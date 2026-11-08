"""Package ForgeSign without macOS resource forks; preserve app bytes and modes."""

import argparse
import copy
import plistlib
import stat
import zipfile
from pathlib import Path, PurePosixPath


def is_metadata(name):
    return any(part == "__MACOSX" or part == ".DS_Store" or part.startswith("._")
               for part in PurePosixPath(name).parts)


def validate_ipa(ipa, allow_metadata=False):
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError("Duplicate ZIP entries")
        for name in names:
            path = PurePosixPath(name)
            if path.is_absolute() or ".." in path.parts or "\\" in name:
                raise ValueError(f"Unsafe archive path: {name}")
            if is_metadata(name) and not allow_metadata:
                raise ValueError(f"macOS metadata must not be packaged: {name}")
        retained = [name for name in names if not is_metadata(name)]
        roots = {PurePosixPath(name).parts[1] for name in retained
                 if name.startswith("Payload/") and len(PurePosixPath(name).parts) > 1}
        if len(roots) != 1 or not next(iter(roots)).endswith(".app"):
            raise ValueError("Payload must contain exactly one app")
        root = "Payload/" + next(iter(roots)) + "/"
        try:
            info = plistlib.loads(archive.read(root + "Info.plist"))
        except KeyError:
            raise ValueError("App is missing Info.plist") from None
        executable = info.get("CFBundleExecutable", "")
        if not executable or "/" in executable or "\\" in executable or executable in (".", ".."):
            raise ValueError("Invalid CFBundleExecutable")
        try:
            entry = archive.getinfo(root + executable)
        except KeyError:
            raise ValueError(f"App executable is missing: {executable}") from None
        if not stat.S_ISREG(entry.external_attr >> 16) or not (entry.external_attr >> 16) & 0o111:
            raise ValueError("App executable must be a regular, executable file")
        if info.get("CFBundlePackageType") != "APPL" or not info.get("CFBundleIdentifier"):
            raise ValueError("Missing app identity")
        bad_entry = archive.testzip()
        if bad_entry:
            raise ValueError(f"Corrupt ZIP entry: {bad_entry}")
        return retained


def _create_ipa(output, write, verify=None):
    """Write a new IPA, validate it, and remove it again if any step fails.

    The output is opened in exclusive-create mode, so an existing file is never
    touched; a half-written or invalid IPA is never left behind to block the
    next run.
    """
    output = Path(output)
    archive = zipfile.ZipFile(output, "x", zipfile.ZIP_DEFLATED)
    try:
        with archive:
            write(archive)
        validate_ipa(output)
        if verify:
            verify(output)
    except BaseException:
        output.unlink(missing_ok=True)
        raise


def repack_ipa(source, output):
    retained = validate_ipa(source, allow_metadata=True)

    def write(clean):
        with zipfile.ZipFile(source) as original:
            for name in retained:
                entry = copy.copy(original.getinfo(name))
                entry.extra = b""
                clean.writestr(entry, original.read(name), compress_type=zipfile.ZIP_DEFLATED)

    def verify(output):
        # Repackaging must not alter any app resource, executable or signature.
        with zipfile.ZipFile(source) as original, zipfile.ZipFile(output) as clean:
            for name in retained:
                if original.read(name) != clean.read(name):
                    raise ValueError(f"Repackaging changed app content: {name}")

    _create_ipa(output, write, verify)


def package_app(source, output):
    source = Path(source)
    if not source.is_dir() or source.suffix != ".app" or source.is_symlink():
        raise ValueError("Source must be an app directory")

    def write(archive):
        # ZipFile does not copy filesystem extended attributes or resource forks.
        for item in sorted(source.rglob("*")):
            relative = item.relative_to(source)
            if is_metadata(relative.as_posix()):
                continue
            if item.is_symlink():
                raise ValueError(f"Unexpected symlink in device app: {relative}")
            if item.is_file():
                archive.write(item, (PurePosixPath("Payload") / source.name / relative).as_posix())

    _create_ipa(output, write)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("pack", "repack", "validate"))
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path, nargs="?")
    args = parser.parse_args()
    if args.action == "validate":
        validate_ipa(args.source)
    else:
        if args.output is None:
            parser.error("pack/repack requires an output IPA (must not already exist)")
        {"pack": package_app, "repack": repack_ipa}[args.action](args.source, args.output)
    print("IPA packaging validation passed")


if __name__ == "__main__":
    main()
