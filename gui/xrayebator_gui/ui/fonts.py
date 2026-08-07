"""Inter font loading (static weights, not variable font).

Variable font (InterVariable.ttf) renders condensed on Windows because Qt picks
the wrong instance from the 'opsz' axis — we ship two static TTFs instead:
Inter-Regular.ttf and Inter-Medium.ttf (v4.1, SIL Open Font License).

Strategy:
1. If the system already has Inter installed (macOS, fonts-inter on Linux,
   user-installed on Windows) — use it, skip bundled files entirely.
2. Else load both bundled TTFs via QFontDatabase; Qt merges them into a
   single "Inter" family with weights 400 (Regular) and 500 (Medium).
3. If neither is available, FONT_STACK falls through to system sans.

Public API:
    ensure_inter_font(app) -> str — resolved family name ("Inter" or "")
    FONT_STACK — QSS-ready font-family stack for UI text
    MONO_STACK — QSS-ready monospace stack for the log widget
"""
from __future__ import annotations

import sys
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from PySide6.QtWidgets import QApplication

_BUNDLED_FONTS = ("Inter-Regular.ttf", "Inter-Medium.ttf")


def _fonts_dir() -> Path:
    """Bundled fonts dir — works in dev checkout and PyInstaller onefile."""
    if getattr(sys, "frozen", False) and hasattr(sys, "_MEIPASS"):
        return Path(sys._MEIPASS) / "xrayebator_gui" / "assets" / "fonts"
    # this file lives at xrayebator_gui/ui/fonts.py → assets are one level up
    return Path(__file__).parent.parent / "assets" / "fonts"


def ensure_inter_font(app: QApplication) -> str:
    """Load Inter into QFontDatabase unless the system provides it.

    Returns the family name Qt reports for Inter (usually "Inter"), or
    "" if neither system install nor bundled files are available — in
    which case FONT_STACK degrades to system sans gracefully.
    """
    from PySide6.QtGui import QFontDatabase

    families = set(QFontDatabase.families())
    if "Inter" in families:
        return "Inter"

    fonts_dir = _fonts_dir()
    loaded_family = ""
    for filename in _BUNDLED_FONTS:
        path = fonts_dir / filename
        if not path.is_file():
            continue
        font_id = QFontDatabase.addApplicationFont(str(path))
        if font_id == -1:
            continue
        loaded = QFontDatabase.applicationFontFamilies(font_id)
        if loaded and not loaded_family:
            loaded_family = loaded[0]

    return loaded_family


# Итоговый CSS font-family stack. QSS font-family принимает quoted list.
FONT_STACK = '"Inter", "Segoe UI", "SF Pro Text", "Helvetica Neue", sans-serif'

# Моноширинный — для логов.
MONO_STACK = '"Cascadia Code", "JetBrains Mono", "Fira Code", Consolas, Menlo, monospace'
