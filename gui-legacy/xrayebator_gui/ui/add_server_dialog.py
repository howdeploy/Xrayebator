"""Диалог добавления сервера: IP, SSH, пользователь, auth, email."""

from __future__ import annotations

import re

from PySide6.QtWidgets import (
    QComboBox,
    QDialog,
    QDialogButtonBox,
    QFileDialog,
    QFormLayout,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QPushButton,
    QSpinBox,
    QVBoxLayout,
    QWidget,
)

_HOST_RE = re.compile(
    r"^(?=.{1,253}$)("
    r"(\d{1,3}\.){3}\d{1,3}"  # IPv4
    r"|\[?[0-9a-fA-F:]{2,45}\]?"  # IPv6 literal (со скобками и без)
    r"|([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}"  # hostname
    r")$"
)
_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

_HOSTNAME_RE = re.compile(
    r"^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$"
)


def _valid_ip_literal(candidate: str) -> bool:
    """Строгая проверка IP-литерала через ipaddress (IPv4/IPv6, со скобками и без)."""
    import ipaddress

    value = candidate[1:-1] if candidate.startswith("[") and candidate.endswith("]") else candidate
    try:
        ipaddress.ip_address(value)
        return True
    except ValueError:
        return False


def valid_host(host: str) -> bool:
    """Проверка IPv4/IPv6 или hostname перед отправкой на сервер."""
    if not _HOST_RE.match(host):
        return False
    if _HOSTNAME_RE.match(host):
        return True
    return _valid_ip_literal(host)


def normalize_host(host: str) -> str:
    """Приводит host к виду, который принимает Paramiko/SSH.

    P2-gui-fix: bracketed IPv6 типа ``[::1]`` проходит валидацию, но скобки — это только
    синтаксис IPv6-адреса в URI, а не часть вин-адреса. Передавать их в Paramiko нельзя
    (SSH не понимает ``hostname="[::1]"``). Снимаем квадратные скобки, если адрес —
    валидный IPv6-литерал.
    """
    text = host.strip()
    if text.startswith("[") and text.endswith("]"):
        inner = text[1:-1]
        if _valid_ip_literal(inner):
            return inner
    return text


def valid_email(email: str) -> bool:
    return bool(_EMAIL_RE.match(email))


class _FieldRow(QWidget):
    """QLineEdit + inline error label (HeroUI-style: красный текст под полем).

    Когда ошибка скрыта — widget имеет только высоту поля (без пустого
    error_label), благодаря чему QFormLayout выравнивает baseline этой строки
    так же, как и другие QLineEdit — не съезжает ни вверх, ни вниз.
    """

    def __init__(self, edit: QWidget, parent=None):
        super().__init__(parent)
        self.edit = edit
        self.error_label = QLabel()
        self.error_label.setObjectName("fieldError")
        self.error_label.setVisible(False)
        # Когда error_label невидим — он не должен оставлять след в layout.
        # setContentsMargins(0,0,0,0) вокруг пустого label + zero-spacing.
        self.error_label.setContentsMargins(4, 0, 4, 2)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(2)
        layout.addWidget(edit)
        layout.addWidget(self.error_label)
        # Устанавливаем sizeHint = только видимая часть (edit или edit+error)
        self.setSizePolicy(self.sizePolicy())

    def set_error(self, message: str | None) -> None:
        """None → скрыть ошибку; иначе показать красным."""
        if message:
            self.error_label.setText(message)
            self.error_label.setVisible(True)
            # Красный бордер через QSS.
            # setProperty триггерит repolish — пересчитает стиль.
            if hasattr(self.edit, 'setProperty'):
                self.edit.setProperty("error", True)
                self.edit.style().unpolish(self.edit)
                self.edit.style().polish(self.edit)
        else:
            self.error_label.setVisible(False)
            if hasattr(self.edit, 'setProperty'):
                self.edit.setProperty("error", False)
                self.edit.style().unpolish(self.edit)
                self.edit.style().polish(self.edit)

    def text(self) -> str:
        return self.edit.text()


class AddServerDialog(QDialog):
    """Форма параметров VPS; «Развернуть и добавить» → accepted с данными.

    Inline validation: ошибки показываются прямо под полем при изменении,
    не ждём клика «Развернуть». Валидация дергается через textChanged,
    задержки нет (полей мало, регулярки дешёвые).
    """

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Добавить сервер")
        self.setMinimumWidth(460)

        # Поля с inline-error rows (HeroUI style)
        self.host_edit = QLineEdit()
        self.host_edit.setPlaceholderText("203.0.113.10 или vpn.example.com")
        self.host_row = _FieldRow(self.host_edit)

        self.port_spin = QSpinBox()
        self.port_spin.setRange(1, 65535)
        self.port_spin.setValue(22)

        self.user_edit = QLineEdit("root")
        self.user_row = _FieldRow(self.user_edit)

        self.auth_combo = QComboBox()
        self.auth_combo.addItems(["Пароль", "SSH-ключ"])

        self.password_edit = QLineEdit()
        self.password_edit.setEchoMode(QLineEdit.EchoMode.Password)
        self.password_row = _FieldRow(self.password_edit)

        self.sudo_password_edit = QLineEdit()
        self.sudo_password_edit.setEchoMode(QLineEdit.EchoMode.Password)
        self.sudo_password_edit.setPlaceholderText(
            "необязательно: пусто = SSH-пароль или passwordless sudo"
        )

        self.key_edit = QLineEdit()
        self.key_edit.setPlaceholderText("~/.ssh/id_ed25519")
        key_browse = QPushButton("Обзор…")
        key_browse.setProperty("variant", "ghost")
        key_browse.clicked.connect(self._browse_key)
        # GUI-1-fix: key_edit оборачиваем _FieldRow (для inline error ДО кнопки),
        # а в форму добавляем композитную строку key_row + key_browse. Раньше
        # key_row не добавлялся в форму вообще → пользователь видел только кнопку,
        # inline-ошибка была скрыта.
        self.key_row = _FieldRow(self.key_edit)
        key_with_browse = QHBoxLayout()
        key_with_browse.setContentsMargins(0, 0, 0, 0)
        key_with_browse.setSpacing(6)
        key_with_browse.addWidget(self.key_row, 1)
        key_with_browse.addWidget(key_browse)
        key_container = QWidget()
        key_container.setLayout(key_with_browse)

        self.email_edit = QLineEdit()
        self.email_edit.setPlaceholderText("you@example.com (для Let's Encrypt)")
        self.email_row = _FieldRow(self.email_edit)

        form = QFormLayout()
        form.addRow("Адрес сервера:", self.host_row)
        form.addRow("SSH порт:", self.port_spin)
        form.addRow("Пользователь:", self.user_row)
        form.addRow("Аутентификация:", self.auth_combo)
        form.addRow("Пароль:", self.password_row)
        # Composite row: lineEdit (в _FieldRow для inline error) + Browse button.
        # Чтобы не ломать baseline QFormLayout, оборачиваем оба в flat container.
        # Key-edit теперь всегда имеет error_border при ошибке (видно под кнопкой).
        form.addRow("Файл ключа:", key_container)
        form.addRow("Пароль sudo:", self.sudo_password_edit)
        form.addRow("Email:", self.email_row)

        self.buttons = QDialogButtonBox()
        deploy_btn = self.buttons.addButton(
            "Развернуть и подключить", QDialogButtonBox.ButtonRole.AcceptRole
        )
        deploy_btn.setProperty("variant", "primary")
        deploy_btn.setDefault(True)
        self.buttons.addButton(QDialogButtonBox.StandardButton.Cancel)
        deploy_btn.clicked.connect(self._on_accept)
        self.buttons.rejected.connect(self.reject)

        self.auth_combo.currentIndexChanged.connect(self._update_auth_fields)

        # Inline validation wiring
        self.host_edit.textChanged.connect(self._validate_fields)
        self.user_edit.textChanged.connect(self._validate_fields)
        self.password_edit.textChanged.connect(self._validate_fields)
        self.key_edit.textChanged.connect(self._validate_fields)
        self.email_edit.textChanged.connect(self._validate_fields)

        self._update_auth_fields()

        layout = QVBoxLayout(self)
        layout.addLayout(form)
        layout.addWidget(self.buttons)

        # Первичная валидация — подсветит пустые обязательные поля
        self._validate_fields()

    def _update_auth_fields(self) -> None:
        use_password = self.auth_combo.currentIndex() == 0
        self.password_edit.setEnabled(use_password)
        # key_edit nested inside key_inner_widget
        key_widget = self.key_row.edit
        key_widget.setEnabled(not use_password)

    def _browse_key(self) -> None:
        path, _ = QFileDialog.getOpenFileName(
            self, "Выберите приватный SSH-ключ", "", "Все файлы (*)"
        )
        if path:
            self.key_edit.setText(path)

    def _validate_fields(self) -> None:
        """Live validation, показывает/прячет ошибки под полями. Не блокирует submit."""
        # Host
        host_text = self.host_edit.text().strip()
        if not host_text:
            self.host_row.set_error(None)  # ещё не введено — без ошибки
        elif not valid_host(host_text):
            self.host_row.set_error("Некорректный IPv4 или hostname.")
        else:
            self.host_row.set_error(None)

        # User
        if self.user_edit.text().strip() and self.user_edit.text().strip() != "root":
            # Информационно: root хорошо, но не-root тоже сработает (через sudo)
            self.user_row.set_error(None)
        else:
            self.user_row.set_error(None)

        # Password or key
        use_password = self.auth_combo.currentIndex() == 0
        if use_password:
            if self.password_edit.text():
                self.password_row.set_error(None)
            else:
                self.password_row.set_error(None)  # пустое — покажем только на submit
        else:
            key_text = self.key_edit.text().strip()
            if not key_text:
                self.key_row.set_error(None)
            elif not key_text.startswith(("~", "/", "C:", "D:")):
                # Грубая проверка пути — не полная, но лучше чем ничего
                self.key_row.set_error("Путь должен начинаться с ~ или /")
            else:
                self.key_row.set_error(None)

        # Email
        email_text = self.email_edit.text().strip()
        if not email_text:
            self.email_row.set_error(None)
        elif not valid_email(email_text):
            self.email_row.set_error("Некорректный email (нужен для Let's Encrypt).")
        else:
            self.email_row.set_error(None)

    def _on_accept(self) -> None:
        """Submit-time validation собирает все ошибки разом."""
        errors = []
        if not valid_host(self.host_edit.text().strip()):
            errors.append("Некорректный адрес сервера.")
            self.host_row.set_error("Некорректный IPv4 или hostname.")
        if not self.user_edit.text().strip():
            errors.append("Укажите пользователя SSH.")
            self.user_row.set_error("Обязательное поле.")
        if self.auth_combo.currentIndex() == 0:
            if not self.password_edit.text():
                errors.append("Укажите пароль.")
                self.password_row.set_error("Обязательное поле.")
        else:
            if not self.key_edit.text().strip():
                errors.append("Укажите путь к файлу SSH-ключа.")
                self.key_row.set_error("Обязательное поле.")
        if not valid_email(self.email_edit.text().strip()):
            errors.append("Некорректный email.")
            self.email_row.set_error("Некорректный email.")

        if errors:
            # Не QMessageBox — просто показываем под полем, фокус на первое ошибочное
            if not valid_host(self.host_edit.text().strip()):
                self.host_edit.setFocus()
            elif not valid_email(self.email_edit.text().strip()):
                self.email_edit.setFocus()
            return
        self.accept()

    def values(self) -> dict:
        """Собранные и проверенные параметры формы."""
        use_password = self.auth_combo.currentIndex() == 0
        return {
            "host": normalize_host(self.host_edit.text()),
            "port": self.port_spin.value(),
            "user": self.user_edit.text().strip(),
            "auth_type": "password" if use_password else "key",
            "password": self.password_edit.text() if use_password else None,
            "key_path": self.key_edit.text().strip() if not use_password else None,
            "sudo_password": self.sudo_password_edit.text() or None,
            "email": self.email_edit.text().strip(),
        }
