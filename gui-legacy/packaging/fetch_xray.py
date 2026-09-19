"""Download and verify the pinned Xray archive used by a desktop bundle."""

from __future__ import annotations

import platform
import shutil
import tempfile
from pathlib import Path

from xrayebator_gui.core.xray import (
    XRAY_REPO,
    XRAY_TUN_VERSION,
    _parse_dgst,
    _platform_asset,
    _sha256,
)

GUI_ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    asset = _platform_asset()
    base = f"https://github.com/{XRAY_REPO}/releases/download/{XRAY_TUN_VERSION}"
    vendor = GUI_ROOT / "vendor"
    vendor.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="xrayebator-release-") as temp_dir:
        temp = Path(temp_dir)
        archive = temp / asset
        digest_file = temp / f"{asset}.dgst"
        _download(f"{base}/{asset}", archive)
        _download(f"{base}/{asset}.dgst", digest_file)
        expected = _parse_dgst(digest_file.read_text(encoding="utf-8"), asset)
        if expected is None:
            raise RuntimeError(f"Xray release does not publish SHA-256 for {asset}")
        actual = _sha256(archive)
        if actual.lower() != expected.lower():
            raise RuntimeError(f"SHA-256 mismatch for {asset}")
        shutil.copy2(archive, vendor / asset)

    print(
        f"Bundled Xray {XRAY_TUN_VERSION}: {asset} "
        f"({_sha256(vendor / asset)}) on {platform.platform()}"
    )
    return 0


def _download(url: str, destination: Path) -> None:
    import requests

    with requests.get(url, stream=True, timeout=180) as response:
        response.raise_for_status()
        with destination.open("wb") as output:
            for chunk in response.iter_content(1 << 20):
                output.write(chunk)


if __name__ == "__main__":
    raise SystemExit(main())
