"""Extract one version's release notes from WHATS_NEW.md (audit B7).

WHATS_NEW.md starts with the release being published and keeps older releases
below it. Only the current section is published, and the file must start with
the heading for the version being released.
"""

import argparse
import sys
from pathlib import Path

HISTORY = "## What's new in "


def section_for(version, text):
    lines = text.splitlines()
    if not lines or lines[0].strip() != f"# ForgeSign {version}":
        raise ValueError(f"WHATS_NEW.md must start with '# ForgeSign {version}'")
    kept = []
    history_seen = False
    for line in lines:
        if line.startswith(HISTORY):
            # The first "What's new" belongs to this release; the second starts older ones.
            if history_seen:
                break
            history_seen = True
        kept.append(line)
    return "\n".join(kept).rstrip() + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("--source", type=Path, default=Path("WHATS_NEW.md"))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        notes = section_for(args.version, args.source.read_text(encoding="utf-8"))
    except ValueError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(notes, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
