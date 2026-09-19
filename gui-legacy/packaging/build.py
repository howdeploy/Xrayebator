"""Build a native Xrayebator desktop bundle on the current operating system."""

from __future__ import annotations

import platform
import shutil
from pathlib import Path

from PIL import Image, ImageDraw
from PyInstaller.__main__ import run as run_pyinstaller

from xrayebator_gui import __version__

GUI_ROOT = Path(__file__).resolve().parents[1]
BUILD_ROOT = GUI_ROOT / "build" / "packaging"
DIST_ROOT = GUI_ROOT / "dist"


def _make_icon() -> Path:
    BUILD_ROOT.mkdir(parents=True, exist_ok=True)
    canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    draw.ellipse((64, 64, 960, 960), fill=(42, 130, 218, 255))
    width = 96
    draw.line((330, 310, 694, 714), fill="white", width=width)
    draw.line((694, 310, 330, 714), fill="white", width=width)

    if platform.system() == "Windows":
        icon = BUILD_ROOT / "xrayebator.ico"
        canvas.save(
            icon,
            format="ICO",
            sizes=[(16, 16), (32, 32), (48, 48), (64, 64), (256, 256)],
        )
        return icon

    icon = BUILD_ROOT / "xrayebator.icns"
    canvas.save(icon, format="ICNS")
    return icon


def _windows_version_file() -> Path:
    parts = [int(part) for part in __version__.split(".")]
    version = tuple((parts + [0] * 4)[:4])
    path = BUILD_ROOT / "version_info.txt"
    path.write_text(
        f"""VSVersionInfo(
  ffi=FixedFileInfo(
    filevers={version},
    prodvers={version},
    mask=0x3f,
    flags=0x0,
    OS=0x40004,
    fileType=0x1,
    subtype=0x0,
    date=(0, 0)
  ),
  kids=[
    StringFileInfo([
      StringTable(
        '040904B0',
        [
          StringStruct('CompanyName', 'Xrayebator'),
          StringStruct('FileDescription', 'Xrayebator desktop client'),
          StringStruct('FileVersion', '{__version__}'),
          StringStruct('InternalName', 'Xrayebator'),
          StringStruct('OriginalFilename', 'Xrayebator.exe'),
          StringStruct('ProductName', 'Xrayebator GUI'),
          StringStruct('ProductVersion', '{__version__}')
        ]
      )
    ]),
    VarFileInfo([VarStruct('Translation', [1033, 1200])])
  ]
)
""",
        encoding="utf-8",
    )
    return path


def main() -> int:
    system = platform.system()
    if system not in {"Windows", "Darwin"}:
        raise SystemExit("Desktop release bundles are built on Windows or macOS")
    vendor_archives = list((GUI_ROOT / "vendor").glob("Xray-*.zip"))
    if len(vendor_archives) != 1:
        raise SystemExit(
            "Run packaging/fetch_xray.py before building; "
            "exactly one platform Xray archive is required"
        )

    shutil.rmtree(DIST_ROOT, ignore_errors=True)
    icon = _make_icon()
    arguments = [
        str(GUI_ROOT / "packaging" / "launcher.py"),
        "--name=Xrayebator",
        "--noconfirm",
        "--clean",
        "--windowed",
        "--noupx",
        f"--icon={icon}",
        f"--distpath={DIST_ROOT}",
        f"--workpath={BUILD_ROOT / 'pyinstaller'}",
        f"--specpath={BUILD_ROOT}",
        f"--paths={GUI_ROOT}",
        f"--add-data={GUI_ROOT / 'vendor'}:vendor",
        "--collect-data=xrayebator_gui",
        "--collect-all=keyring",
    ]
    if system == "Windows":
        arguments.extend(
            [
                "--onefile",
                f"--version-file={_windows_version_file()}",
            ]
        )
    else:
        arguments.extend(
            [
                "--onedir",
                "--osx-bundle-identifier=com.xrayebator.desktop",
                f"--target-arch={platform.machine()}",
            ]
        )
    run_pyinstaller(arguments)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
