"""Write standard SHA-256 sidecar files for release artifacts."""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path


def main(paths: list[str]) -> int:
    if not paths:
        raise SystemExit("usage: checksum.py ARTIFACT [...]")
    for raw_path in paths:
        path = Path(raw_path)
        digest = hashlib.sha256()
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1 << 20), b""):
                digest.update(chunk)
        sidecar = path.with_name(f"{path.name}.sha256")
        sidecar.write_text(f"{digest.hexdigest()}  {path.name}\n", encoding="ascii")
        print(sidecar)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
