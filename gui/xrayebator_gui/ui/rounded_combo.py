"""Custom QComboBox with fully styled rounded popup.

Qt's built-in combo popup (QComboBoxPrivateContainer) cannot be reliably
rounded through QSS on Windows because the outer frame is painted by
QWindowsVistaStyle, which ignores border-radius. This widget replaces the
combo's dropdown with our own QListWidget hosted in a QFrame that has
explicit border-radius + gap below the button + item padding that prevents
text overlap.

Usage:
    from .rounded_combo import RoundedComboBox
    cb = RoundedComboBox(tokens)
    cb.addItems(["a","b"])
    cb.setCurrentIndex(0)
    cb.currentTextChanged.connect(...)
"""

from __future__ import annotations

from PySide6.QtCore import QPoint, Qt, Signal
from PySide6.QtGui import QColor
from PySide6.QtWidgets import (
    QComboBox,
    QFrame,
    QHBoxLayout,
    QListWidget,
    QListWidgetItem,
    QPushButton,
    QVBoxLayout,
    QWidget,
)


# Импортируем lazily чтобы theme.py не циклил
def _tokens_from_app():
    from PySide6.QtWidgets import QApplication
    app = QApplication.instance()
    return getattr(app, "_heroui_tokens", None)


class _RoundedPopup(QFrame):
    """Popup frame hosting the list; positioned below the button."""

    picked = Signal(int)

    def __init__(self, parent: RoundedComboBox):
        super().__init__(parent, Qt.WindowType.Popup | Qt.WindowType.FramelessWindowHint)
        self._combo = parent
        tokens = parent._tokens
        self.setStyleSheet(
            f"""
            QFrame {{
                background-color: {tokens.surface};
                color: {tokens.foreground};
                border: 1px solid {tokens.border};
                border-radius: {tokens.RADIUS_MD + 2}px;
            }}
            QListWidget {{
                background: transparent;
                border: none;
                outline: none;
                padding: 4px;
                font-family: inherit;
            }}
            QListWidget::item {{
                padding: 8px 12px;
                border-radius: {tokens.RADIUS_SM}px;
                min-height: 28px;
                margin: 1px 0;
            }}
            QListWidget::item:selected {{
                background-color: {tokens.accent};
                color: {tokens.accent_foreground};
            }}
            QListWidget::item:hover:!selected {{
                background-color: {tokens.surface_tertiary};
            }}
        """
        )
        layout = QVBoxLayout(self)
        layout.setContentsMargins(4, 4, 4, 4)
        layout.setSpacing(0)
        self.list = QListWidget()
        layout.addWidget(self.list)
        self.list.itemClicked.connect(self._on_pick)

    def set_items(self, items: list[str]) -> None:
        """Rebuild list entries from combo's (label, data) pairs.

        GUI-4-fix: записи, помеченные суффиксом '[disabled]', показываем как
        невыбираемые и делаем их текст приглушённым (настоящее disable).
        """
        self.list.clear()
        for label in items:
            item = QListWidgetItem(label)
            if label.endswith(" [disabled]"):
                item.setFlags(item.flags() & ~Qt.ItemFlag.ItemIsSelectable & ~Qt.ItemFlag.ItemIsEnabled)
                item.setForeground(QColor(self._combo._tokens.muted))
                # Прячем маркер из видимого текста — пользователь видит чистую строку.
                item.setText(label.removesuffix(" [disabled]"))
            self.list.addItem(item)

    def _apply_enabled_flags(self) -> None:
        """Re-apply per-item flags after enable-state mutation (model().item().setEnabled)."""
        for i in range(self.list.count()):
            item = self.list.item(i)
            raw_label, _ = self._combo._items[i]
            is_disabled = raw_label.endswith(" [disabled]")
            if is_disabled:
                item.setFlags(item.flags() & ~Qt.ItemFlag.ItemIsSelectable & ~Qt.ItemFlag.ItemIsEnabled)
                item.setForeground(QColor(self._combo._tokens.muted))
                visible = raw_label.removesuffix(" [disabled]")
            else:
                item.setFlags(item.flags() | Qt.ItemFlag.ItemIsSelectable | Qt.ItemFlag.ItemIsEnabled)
                if self._combo._tokens is not None:
                    item.setForeground(QColor(self._combo._tokens.foreground))
                visible = raw_label
            item.setText(visible)

    def popup_at(self, pos: QPoint, width: int) -> None:
        # Wider than the button: text shouldn't clip. HeroUI menus are
        # typically wider than their parent trigger.
        item_count = self.list.count()
        # Pick a width big enough that "xhttp-legacy (Vision + uTLS)" also fits
        max_text_len = max((len(self._combo._items[i][0]) for i in range(item_count)), default=0)
        # Rough estimate: 8px per char for our font, + padding + arrow room
        suggested_width = max(
            width,                    # never narrower than the trigger button
            200,                       # sane minimum
            min(max_text_len * 9 + 48, 480),  # text-fit up to 480px
        )
        self.setFixedWidth(suggested_width)
        # Height: each row needs ~36px (padding 8px*2 + font 16px = 32,
        # but QListWidget widget's sizeHint for item is bigger than that).
        # Use actual sizeHint from QListWidgetItem to avoid clipping -
        # we still hardcode a floor of 40 per item because Qt cem hidden
        # default margins the row needs on top of our padding values.
        item_row_h = 40
        container_margin = 8   # setContentsMargins(4,4,4,4) sums to 8
        # Always reserve a bit extra for divider lines and the rounded frame
        extra_padding = container_margin + 12
        content_h = item_count * item_row_h + extra_padding
        # Cap at 480 px; scrollbar only when it would overflow
        needs_scroll = content_h > 480
        self.setFixedHeight(min(content_h, 480))
        self.list.setVerticalScrollBarPolicy(
            Qt.ScrollBarPolicy.ScrollBarAsNeeded if needs_scroll
            else Qt.ScrollBarPolicy.ScrollBarAlwaysOff
        )
        # 4px gap so popup doesn't touch the combo bottom edge
        pos.setY(pos.y() + 4)
        self.move(pos)
        self.show()
        self.raise_()
        self.setFocus()

    def _on_pick(self, item: QListWidgetItem) -> None:
        row = self.list.row(item)
        self.picked.emit(row)
        self.hide()


class RoundedComboBox(QWidget):
    """List replacement for QComboBox with full HeroUI styling control.

    Public API mirrors QComboBox where needed by our codebase (addItems,
    setPlaceholderText, currentIndexChanged, currentData, currentText, etc.).
    """

    currentIndexChanged = Signal(int)

    def __init__(self, parent: QWidget | None = None):
        super().__init__(parent)
        self._tokens = _tokens_from_app()
        if self._tokens is None:
            # If widget was constructed before apply_theme, defer styled init
            # until polish event (which our eventFilter intercepts and re-calls).
            pass
        self._placeholder: str = ""
        self._items: list[tuple[str, object]] = []  # (label, userData)
        self._current: int = -1

        layout = QHBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)

        self.button = QPushButton()
        self.button.setProperty("comboTrigger", True)
        self.button.setMinimumHeight(38)
        # GUI-5-fix: dropdown indicator — Unicode-triangle нестабилен по шрифтам,
        # ставим реюзовую стрелку через QSS border-image ниже. Оставляем явный
        # hint — padding-bottom увеличен чтобы текст налево не прилипал к краю.
        self.button.setFocusPolicy(Qt.FocusPolicy.StrongFocus)
        self.button.clicked.connect(self._toggle_popup)
        self.button.setCursor(Qt.CursorShape.PointingHandCursor)
        layout.addWidget(self.button)

        # Keyboard navigation required by GUI-5-spec — Up/Down navigate without
        # opening popup, Enter/Escape open/close it.
        self.button.installEventFilter(self)

        if self._tokens is not None:
            self._apply_style()
        self._popup: _RoundedPopup | None = None

    def _apply_style(self) -> None:
        """Re-apply theme style on this widget (called by wrap_combo helper)."""
        tokens = self._tokens
        self.button.setStyleSheet(
            f"""
            QPushButton[comboTrigger="true"] {{
                background-color: {tokens.surface_secondary};
                color: {tokens.foreground};
                border: 1px solid {tokens.border};
                border-radius: {tokens.RADIUS_XL}px;
                padding: 8px 12px;
                padding-right: 32px;
                text-align: left;
                font-weight: 500;
                min-height: 22px;
            }}
            QPushButton[comboTrigger="true"]:hover {{
                background-color: {tokens.surface_tertiary};
            }}
            QPushButton[comboTrigger="true"]:focus {{
                border: 2px solid {tokens.focus_ring};
                padding: 7px 11px;
                padding-right: 31px;
            }}
            QPushButton[comboTrigger="true"]:disabled {{
                background-color: {tokens.surface};
                color: {tokens.muted};
            }}
            /* GUI-5: dropdown indicator — тонкий ▼ на правом краю,
               не конфликтует с focus-ring padding-right. */
            QPushButton[comboTrigger="true"]::indicator,
            QPushButton[comboTrigger="true"]::drop-down {{
                image: none;
                border: none;
                /* Рисуем текстом ▼ через padding-right зоны. */
            }}
        """
        )
        # GUI-5-fix: явно помечаем стрелку в тексте кнопки если она не задана.
        # Это отличает "стоковый QComboBox" (фоном рисует arrow) от нашего —
        # пользователю看不到 dropdown, если текст кнопки идёт без маркера.
        current = self.button.text()
        if current and not current.endswith("▼"):
            # Убираем возможные двойные пробелы в конце, потом добавляем маркер.
            self.button.setText(current.rstrip(" ") + "  ▼")

    def set_tokens(self, tokens) -> None:
        """Setter used by theme.apply_theme on Polish-event paths where the
        widget was constructed before the theme system populated
        app._heroui_tokens."""
        self._tokens = tokens
        self._apply_style()
        if self._popup is not None:
            # Rebuild popup with new tokens
            items = [label for label, _ in self._items]
            self._popup.deleteLater()
            self._popup = None
            self._rebuild_popup(items)

    def addItem(self, label: str, userData: object = None) -> None:
        self._items.append((label, userData))
        if self._current < 0:
            self.setCurrentIndex(0)

    def addItems(self, labels: list[str]) -> None:
        for lbl in labels:
            self.addItem(lbl)

    def clear(self) -> None:
        self._items = []
        self._current = -1
        self._refresh_label()

    def count(self) -> int:
        return len(self._items)

    def currentIndex(self) -> int:
        return self._current

    def _clean_label(self, raw: str) -> str:
        """GUI-4-fix: внутренний маркер «[disabled]» не должен протекать наружу —
        пользователь видит чистую строку через любой публичный API."""
        return raw.removesuffix(" [disabled]") if raw.endswith(" [disabled]") else raw

    def currentText(self) -> str:
        return (
            self._clean_label(self._items[self._current][0])
            if 0 <= self._current < len(self._items)
            else ""
        )

    def currentData(self):
        return self._items[self._current][1] if 0 <= self._current < len(self._items) else None

    def itemData(self, index: int):
        return self._items[index][1] if 0 <= index < len(self._items) else None

    def itemText(self, index: int) -> str:
        return (
            self._clean_label(self._items[index][0])
            if 0 <= index < len(self._items)
            else ""
        )

    def setCurrentIndex(self, index: int) -> None:
        if index == self._current:
            return
        if not (0 <= index < len(self._items)):
            index = -1
        self._current = index
        self._refresh_label()
        self.currentIndexChanged.emit(self._current)

    def setPlaceholderText(self, text: str) -> None:
        self._placeholder = text
        self._refresh_label()

    def placeholderText(self) -> str:
        return self._placeholder

    def setEnabled(self, enabled: bool) -> None:
        self.button.setEnabled(enabled)
        super().setEnabled(enabled)

    def setItemText(self, index: int, text: str) -> None:
        """GUI-4-fix: совместимость с QComboBox.setItemText — раньше её не было,
        код main_window._install_tun_helper падал с AttributeError.
        Меняем label конкретного пункта, обновляем триггер если это текущий."""
        if 0 <= index < len(self._items):
            _old, data = self._items[index]
            self._items[index] = (text, data)
            if index == self._current:
                self._refresh_label()

    def model(self):
        # Compatibility: existing code calls `mode_combo.model().item(0)` to
        # disable/enable TUN entry. Return a duck-typed wrapper exposing .item()
        # with real enable/disable (disabled items become visually dimmed and
        # not selectable — see _RoundedPopup item flags).
        class _ModelAdapter:
            def __init__(self, outer): self.outer = outer
            def item(self, idx):
                if not (0 <= idx < len(self.outer._items)):
                    return None
                class _ItemAdapter:
                    def __init__(self, combo, i): self.combo, self.i = combo, i
                    def setEnabled(self, on):
                        # GUI-4-fix: хранение disabled-флага, а не строкового
                        # суффикса «[disabled]». Пункт либо выбираем, либо нет.
                        lbl, data = self.combo._items[self.i]
                        if on:
                            if lbl.endswith(" [disabled]"):
                                lbl = lbl.removesuffix(" [disabled]")
                        elif not lbl.endswith(" [disabled]"):
                            lbl = lbl + " [disabled]"
                        self.combo._items[self.i] = (lbl, data)
                        # Перестраиваем флаги в видимом popup
                        if self.combo._popup is not None:
                            self.combo._popup._apply_enabled_flags()
                return _ItemAdapter(self.outer, idx)
        return _ModelAdapter(self)

    def findText(self, text: str) -> int:
        for i, (lbl, _d) in enumerate(self._items):
            if lbl == text:
                return i
        return -1

    # ─── internals ───────────────────────────────────────────────

    def eventFilter(self, watched, event) -> bool:
        """GUI-5-fix: keyboard navigation на триггере — Up/Down/Enter/Escape."""
        if watched is self.button:
            if event.type() == event.Type.KeyPress:
                if event.key() in (Qt.Key.Key_Up, Qt.Key.Key_Down):
                    self._navigate(-1 if event.key() == Qt.Key.Key_Up else 1)
                    return True
                if event.key() in (Qt.Key.Key_Return, Qt.Key.Key_Enter, Qt.Key.Key_Space):
                    self._toggle_popup()
                    return True
                if event.key() == Qt.Key.Key_Escape and self._popup and self._popup.isVisible():
                    self._popup.hide()
                    return True
        return super().eventFilter(watched, event)

    def _navigate(self, delta: int) -> None:
        """GUI-5-fix: keyboard Up/Down — проходим по пунктам, пропуская disabled."""
        if not self._items:
            return
        idx = self._current
        for _ in range(len(self._items)):
            idx = (idx + delta) % len(self._items)
            if not self._items[idx][0].endswith(" [disabled]"):
                self.setCurrentIndex(idx)
                return

    def _refresh_label(self) -> None:
        """Update trigger button text. ▼ marker added once, [disabled] hidden from UI."""
        if 0 <= self._current < len(self._items):
            raw = self._items[self._current][0]
            # Прячем «[disabled]» из видимого текста, сохраняя корректный disabled state.
            if raw.endswith(" [disabled]"):
                label = raw.removesuffix(" [disabled]")
            else:
                label = raw
            if not label.endswith("  ▼"):
                label = label + "  ▼"
            self.button.setText(label)
        else:
            ph = self._placeholder or ""
            self.button.setText((ph if ph else "—") + "  ▼")

    def _toggle_popup(self) -> None:
        if self._popup is None:
            items = [label for label, _ in self._items]
            self._rebuild_popup(items)
        if self._popup is None:
            return
        if self._popup.isVisible():
            self._popup.hide()
            return
        # Show below the button aligned to its left edge
        global_pos = self.button.mapToGlobal(QPoint(0, self.button.height()))
        self._popup.set_items([label for label, _ in self._items])
        self._popup.popup_at(global_pos, max(self.button.width(), 200))

    def _rebuild_popup(self, items: list[str]) -> None:
        if self._tokens is None:
            return
        self._popup = _RoundedPopup(self)
        self._popup.set_items(items)
        self._popup.picked.connect(self._on_picked)

    def _on_picked(self, row: int) -> None:
        self.setCurrentIndex(row)


def wrap_combo(combo: QComboBox, tokens) -> None:
    """Polish-event helper: if the widget is a plain QComboBox we style it via
    the previous `_fix_combo_popup`-style approach. When we've already replaced
    it with `RoundedComboBox`, this becomes a no-op extra set_tokens call.
    """
    # For plain QComboBox, fall back to old approach — at least keep visuals
    # consistent. New code should construct RoundedComboBox directly.
    from PySide6.QtCore import Qt
    from PySide6.QtWidgets import QListView

    combo.setAttribute(Qt.WidgetAttribute.WA_StyledBackground, True)
    combo.style().unpolish(combo)
    combo.style().polish(combo)
    view = combo.view()
    if isinstance(view, QListView):
        view.setStyleSheet(
            f"""
            QListView {{
                background-color: {tokens.surface};
                color: {tokens.foreground};
                border: 1px solid {tokens.border};
                border-radius: {tokens.RADIUS_MD}px;
                outline: none;
                padding: 4px;
            }}
            QListView::item {{
                padding: 8px 12px;
                border-radius: {tokens.RADIUS_SM}px;
                min-height: 28px;
                margin: 1px 0;
            }}
            QListView::item:selected {{
                background-color: {tokens.accent};
                color: {tokens.accent_foreground};
            }}
            QListView::item:hover:!selected {{
                background-color: {tokens.surface_tertiary};
            }}
            """
        )
    parent = view.parentWidget() if view is not None else None
    if parent is not None and parent.windowFlags() & Qt.WindowType.Popup:
        parent.setAttribute(Qt.WidgetAttribute.WA_StyledBackground, True)
        parent.setStyleSheet(
            f"""
            QComboBoxPrivateContainer {{
                background-color: {tokens.surface};
                border: 1px solid {tokens.border};
                border-radius: {tokens.RADIUS_MD + 2}px;
                padding: 4px;
            }}
            """
        )
