"""Build a CurseForge-style release zip: dist/RareCodex-<version>.zip containing RareCodex/."""

from __future__ import annotations

import re
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ADDON = ROOT / "RareCodex"
DIST = ROOT / "dist"


def addon_version() -> str:
    toc = (ADDON / "RareCodex.toc").read_text(encoding="utf-8")
    match = re.search(r"^## Version:\s*(\S+)", toc, re.M)
    return match.group(1) if match else "dev"


def build_zip() -> Path:
    DIST.mkdir(exist_ok=True)
    target = DIST / f"RareCodex-{addon_version()}.zip"
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(ADDON.rglob("*")):
            if path.is_file():
                # Forward slashes keep the archive valid for every unzip tool.
                archive.write(path, path.relative_to(ROOT).as_posix())
    return target


if __name__ == "__main__":
    print(f"Created {build_zip()}")
