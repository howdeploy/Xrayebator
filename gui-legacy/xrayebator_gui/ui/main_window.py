"""Main desktop window, tray integration, deployment and connection controls."""

from __future__ import annotations

import platform
import traceback
from collections.abc import Callable
from datetime import datetime

from PySide6.QtCore import QObject, Qt, QThread, Signal, Slot
from PySide6.QtGui import QAction, QCloseEvent, QIcon
from PySide6.QtWidgets import (
    QFormLayout,
    QHBoxLayout,
    QLabel,
    QMainWindow,
    QMenu,
    QMessageBox,
    QProgressBar,
    QPushButton,
    QSystemTrayIcon,
    QTextEdit,
    QVBoxLayout,
    QWidget,
)

from ..core import subscription
from ..core.connection import (
    ConnectionController,
    ConnectionMode,
    ConnectionSnapshot,
    ConnectionState,
)
from ..core.deploy import STEPS, make_deploy_thread
from ..core.desktop_backend import DesktopBackend
from ..core.helper_install import install_linux_helper
from ..core.latency import probe_routes
from ..core.routing import RoutingProfile
from ..core.servers import ServerStore
from ..core.ssh import SSHClient
from ..core.subscription import VlessLink
from .add_server_dialog import AddServerDialog
from .rounded_combo import RoundedComboBox


class OperationThread(QThread):
    """Run one blocking Python callable without freezing Qt."""

    succeeded = Signal(object)
    failed = Signal(str)

    def __init__(
        self, operation: Callable[[], object], parent: QObject | None = None
    ):
        super().__init__(parent)
        self._operation = operation

    def run(self) -> None:
        try:
            result = self._operation()
        except Exception as exc:
            # Добавляем traceback, иначе невозможно отладить «exception из фона».
            message = f"{exc}\n\n{traceback.format_exc()}"
            self.failed.emit(message)
            return
        self.succeeded.emit(result)


class _ConnectionBridge(QObject):
    snapshot_changed = Signal(object)


_STATE_LABELS = {
    ConnectionState.DISCONNECTED: "Отключено",
    ConnectionState.PREPARING: "Подготовка…",
    ConnectionState.CONNECTING: "Подключение…",
    ConnectionState.VERIFYING: "Проверка туннеля…",
    ConnectionState.CONNECTED: "Подключено",
    ConnectionState.SWITCHING: "Переключение маршрута…",
    ConnectionState.DISCONNECTING: "Отключение…",
    ConnectionState.RECOVERING: "Восстановление предыдущего маршрута…",
    ConnectionState.ERROR: "Ошибка",
}

# Цветовая маркировка состояния — иначе «Подключено» и «Ошибка» визуально
# неразличимы.
_STATE_COLORS = {
    ConnectionState.DISCONNECTED: "#a0a0a0",
    ConnectionState.PREPARING: "#e5c07b",
    ConnectionState.CONNECTING: "#e5c07b",
    ConnectionState.VERIFYING: "#61afef",
    ConnectionState.CONNECTED: "#98c379",
    ConnectionState.SWITCHING: "#e5c07b",
    ConnectionState.DISCONNECTING: "#e5c07b",
    ConnectionState.RECOVERING: "#e5c07b",
    ConnectionState.ERROR: "#e06c75",
}

_BUSY_STATES = {
    ConnectionState.PREPARING,
    ConnectionState.CONNECTING,
    ConnectionState.VERIFYING,
    ConnectionState.SWITCHING,
    ConnectionState.DISCONNECTING,
    ConnectionState.RECOVERING,
}


class MainWindow(QMainWindow):
    def __init__(
        self,
        *,
        icon: QIcon,
        store: ServerStore | None = None,
        controller: ConnectionController | None = None,
    ):
        super().__init__()
        self.setWindowTitle("Xrayebator")
        self.setWindowIcon(icon)
        self.resize(760, 540)

        self._store = store or ServerStore()
        self._desktop_backend: DesktopBackend | None = None
        if controller is None:
            desktop_backend = DesktopBackend()
            self._desktop_backend = desktop_backend
            self._controller = ConnectionController(desktop_backend)
            self._tun_available = desktop_backend.tun_available
        else:
            self._controller = controller
            self._tun_available = False
        self._bridge = _ConnectionBridge(self)
        self._controller.subscribe(self._bridge.snapshot_changed.emit)
        self._bridge.snapshot_changed.connect(self._on_snapshot)

        self._routes: list[VlessLink] = []
        self._latencies: dict[str, int | None] = {}
        self._operation: OperationThread | None = None
        self._deploy_thread: QThread | None = None
        self._connect_after_route_load = False
        self._quitting = False

        self._build_ui()
        self._build_tray(icon)
        self._reload_servers()
        self._on_snapshot(self._controller.snapshot)
        # Центрируем окно при первом запуске — если у пользователя несколько
        # мониторов и один из них выключен, окно могло "ушло" на невидимый
        # экран и выглядит как «приложение не запустилось».
        self._center_on_screen()

    def _center_on_screen(self) -> None:
        """Разместить окно по центру primary screen, рядом с активной позицией."""
        from PySide6.QtGui import QGuiApplication
        screen = QGuiApplication.primaryScreen()
        if screen is None:
            return
        frame = self.frameGeometry()
        frame.moveCenter(screen.availableGeometry().center())
        self.move(frame.topLeft())

    def _build_ui(self) -> None:
        root = QWidget()
        self.setCentralWidget(root)
        layout = QVBoxLayout(root)
        layout.setContentsMargins(24, 20, 24, 20)
        layout.setSpacing(14)

        title = QLabel("Xrayebator")
        title_font = title.font()
        title_font.setPointSize(20)
        title_font.setBold(True)
        title.setFont(title_font)
        layout.addWidget(title)

        subtitle = QLabel(
            "Разверните собственный сервер, выберите маршрут и подключитесь."
        )
        subtitle.setProperty("muted", True)
        layout.addWidget(subtitle)

        server_row = QHBoxLayout()
        self.server_combo = RoundedComboBox()
        self.server_combo.currentIndexChanged.connect(self._server_changed)
        # Empty-state placeholder — без него combo выглядит пустым куском
        # поля и не очевидно, что он вообще есть и для чего.
        self.server_combo.setPlaceholderText("Выберите сервер или добавьте")
        self.server_combo.setCurrentIndex(-1)  # placeholder показывается при -1
        server_row.addWidget(self.server_combo, 1)
        self.add_server_button = QPushButton("Добавить VPS…")
        self.add_server_button.setProperty("variant", "primary")
        self.add_server_button.clicked.connect(self._add_server)
        server_row.addWidget(self.add_server_button)
        self.remove_server_button = QPushButton("Удалить")
        self.remove_server_button.setProperty("variant", "danger")
        self.remove_server_button.clicked.connect(self._remove_server)
        server_row.addWidget(self.remove_server_button)
        layout.addLayout(server_row)

        form = QFormLayout()
        mode_row = QHBoxLayout()
        self.mode_combo = RoundedComboBox()
        # TUN доступен для выбора всегда; подпись зависит от ОС и наличия
        # helper. Пункт НЕ дизаблится — пользователь может попробовать режим
        # и получит понятную ошибку при подключении, если helper недоступен.
        tun_label = (
            "TUN — доступен для вашей ОС"
            if self._tun_available
            else "TUN — не доступен для вашей ОС"
        )
        self.mode_combo.addItem(tun_label, ConnectionMode.TUN)
        self.mode_combo.addItem(
            "Системный proxy (текущий MVP)", ConnectionMode.SYSTEM_PROXY
        )
        self.mode_combo.setCurrentIndex(0 if self._tun_available else 1)
        self.mode_combo.setMinimumHeight(38)
        mode_row.addWidget(self.mode_combo, 1)
        self.install_helper_button = QPushButton("Установить TUN helper…")
        self.install_helper_button.setProperty("variant", "ghost")
        self.install_helper_button.setVisible(
            platform.system() == "Linux"
            and self._desktop_backend is not None
            and not self._tun_available
        )
        self.install_helper_button.clicked.connect(self._install_tun_helper)
        mode_row.addWidget(self.install_helper_button)
        form.setFieldGrowthPolicy(QFormLayout.FieldGrowthPolicy.AllNonFixedFieldsGrow)
        form.setLabelAlignment(Qt.AlignmentFlag.AlignVCenter | Qt.AlignmentFlag.AlignRight)
        form.addRow("Режим:", mode_row)

        profile_row = QHBoxLayout()
        profile_row.setSpacing(8)
        # Отступы 0 чтобы поле занимало ровно ту же высоту, что и другие поля формы.
        profile_row.setContentsMargins(0, 0, 0, 0)
        self.profile_combo = RoundedComboBox()
        for profile in RoutingProfile:
            self.profile_combo.addItem(profile.label, profile)
        self.profile_combo.currentIndexChanged.connect(self._on_profile_selected)
        # Форсируем этот комбо выравнивание по базовой линии поля ввода
        # чтобы он не 'висел' над sibling controls.
        self.profile_combo.setMinimumHeight(38)
        profile_row.addWidget(self.profile_combo, 1)
        self.profile_switch_button = QPushButton("Применить")
        self.profile_switch_button.setProperty("variant", "ghost")
        self.profile_switch_button.clicked.connect(self._switch_profile)
        profile_row.addWidget(self.profile_switch_button)
        form.addRow("Профиль:", profile_row)

        route_row = QHBoxLayout()
        route_row.setSpacing(8)
        route_row.setContentsMargins(0, 0, 0, 0)
        self.route_combo = RoundedComboBox()
        self.route_combo.setMinimumHeight(38)
        route_row.addWidget(self.route_combo, 1)
        self.refresh_button = QPushButton("Обновить")
        self.refresh_button.setProperty("variant", "ghost")
        self.refresh_button.clicked.connect(self._refresh_routes)
        route_row.addWidget(self.refresh_button)
        self.switch_button = QPushButton("Переключить")
        self.switch_button.setProperty("variant", "ghost")
        self.switch_button.clicked.connect(self._switch_route)
        route_row.addWidget(self.switch_button)
        form.addRow("Маршрут:", route_row)
        layout.addLayout(form)

        status_row = QHBoxLayout()
        self.status_label = QLabel("Отключено")
        status_font = self.status_label.font()
        status_font.setBold(True)
        self.status_label.setFont(status_font)
        self.status_label.setWordWrap(True)
        status_row.addWidget(self.status_label)
        status_row.addStretch()
        self.ip_label = QLabel("")
        self.ip_label.setProperty("muted", True)
        self.ip_label.setWordWrap(True)
        status_row.addWidget(self.ip_label)
        layout.addLayout(status_row)

        # Индетерминированный прогресс-бар: показывается когда идёт операция
        # (подключение, переключение, отключение, recover). Без него UI выглядит
        # «зависшим» на долгих шагах деплоя (install.sh, quickstart по 5+ минут).
        self.busy_progress = QProgressBar()
        self.busy_progress.setRange(0, 0)  # marquee
        self.busy_progress.setTextVisible(False)
        self.busy_progress.setMaximumHeight(4)
        self.busy_progress.setVisible(False)
        layout.addWidget(self.busy_progress)

        self.connect_button = QPushButton("Подключить")
        self.connect_button.setProperty("variant", "primary")
        self.connect_button.setMinimumHeight(52)
        self.connect_button.clicked.connect(self._toggle_connection)
        layout.addWidget(self.connect_button)

        self.log = QTextEdit()
        self.log.setReadOnly(True)
        # QTextEdit не имеет setMaximumBlockCount (это только у QPlainTextEdit).
        # Для обрезки истории переопределяем _append_log — срезка по верхнему блоку.
        # Лимит: 5000 блоков ≈ 250 КБ текста. При переполнении — удаляем самый старый блок.
        self._log_max_blocks = 5000
        self.log.setPlaceholderText("Здесь появятся этапы развёртывания и подключения.")
        layout.addWidget(self.log, 1)

    def _build_tray(self, icon: QIcon) -> None:
        # Диагностический режим: без tray icon (некоторые Windows-билды
        # запрещают tray от unsigned exe — падает весь event loop).
        import os as _os
        if _os.environ.get("XRAYEBATOR_NO_TRAY"):
            self.tray = None
            self.tray_toggle_action = None
            self.tray_server_menu = None
            self.tray_route_menu = None
            self.tray_profile_menu = None
            self.theme_action = None
            return

        self.tray = QSystemTrayIcon(icon, self)
        self.tray.setToolTip("Xrayebator — отключено")
        self.tray.activated.connect(self._tray_activated)

        menu = QMenu(self)
        show_action = QAction("Открыть Xrayebator", self)
        show_action.triggered.connect(self._show_window)
        menu.addAction(show_action)
        self.tray_toggle_action = QAction("Подключить", self)
        self.tray_toggle_action.triggered.connect(self._toggle_connection)
        menu.addAction(self.tray_toggle_action)
        self.tray_server_menu = menu.addMenu("Сервер")
        self.tray_route_menu = menu.addMenu("Маршрут")
        self.tray_profile_menu = menu.addMenu("Профиль")
        menu.addSeparator()
        # Theme toggle (HeroUI v3 ships both dark and light) — стиль жёстко прибит
        # к QSS, поэтому переключение живое через apply_theme с сохранением выбора в QSettings.
        from PySide6.QtCore import QSettings as _QS
        _saved = _QS("xrayebator", "xrayebator-gui").value("theme", "dark")
        self.theme_action = QAction(
            "Тема: тёмная" if _saved == "dark" else "Тема: светлая", self
        )
        self.theme_action.triggered.connect(self._toggle_theme)
        menu.addAction(self.theme_action)
        menu.addSeparator()
        quit_action = QAction("Выйти", self)
        quit_action.triggered.connect(self._quit)
        menu.addAction(quit_action)
        self.tray.setContextMenu(menu)
        self.tray.show()
        self._refresh_tray_menus()

    def _append_log(self, text: str) -> None:
        """Добавить строку в UI-лог с таймстампом и цветовой индикацией ошибки.

        Ограничение истории: QTextEdit не имеет setMaximumBlockCount (это метод
        QPlainTextEdit). Делаем обрезку вручную: если блоков > лимита — удаляем
        самый верхний через QTextCursor. Дёшево, O(1) на удаление.
        """
        timestamp = datetime.now().astimezone().strftime("%H:%M:%S")
        low = text.lower()
        # Цветовая маркировка: ошибки красным, предупреждения жёлтым, успех зелёным.
        if "✗" in text or "ошибка" in low or "failed" in low or "traceback" in low:
            color = "#e06c75"
        elif "⚠" in text or "warning" in low or "предупред" in low:
            color = "#e5c07b"
        elif "✓" in text or "ok" in low or "подключено" in low or "заверш" in low:
            color = "#98c379"
        else:
            color = "#abb2bf"
        import html as html_mod
        escaped = html_mod.escape(text)
        html = (
            f'<span style="color:#4b5263">[{timestamp}]</span> '
            f'<span style="color:{color}">{escaped}</span>'
        )
        self.log.append(html)

        # Manual cap: QTextEdit считает блоки через document().blockCount().
        # Если лимит превышен — удаляем первый блок (самый старый лог).
        doc = self.log.document()
        if doc.blockCount() > self._log_max_blocks:
            cursor = self.log.textCursor()
            cursor.movePosition(cursor.MoveOperation.Start)
            cursor.select(cursor.SelectionType.BlockUnderCursor)
            cursor.removeSelectedText()
            cursor.deleteChar()  # удалить пустую строку после блока

    def _reload_servers(self, select_id: str | None = None) -> None:
        self.server_combo.blockSignals(True)
        self.server_combo.clear()
        servers = self._store.list()
        for server in servers:
            self.server_combo.addItem(
                server.get("name") or server.get("host") or "Сервер",
                server,
            )
        self.server_combo.blockSignals(False)

        if select_id:
            for index in range(self.server_combo.count()):
                data = self.server_combo.itemData(index)
                if data and data.get("id") == select_id:
                    self.server_combo.setCurrentIndex(index)
                    break
        else:
            # Если серверов нет — placeholder уже виден (currentIndex=-1).
            # Если серверы есть и combo ещё пустой (только что loaded) —
            # выбираем первый, чтобы не оставалось placeholder-глюка.
            if self.server_combo.count() > 0 and self.server_combo.currentIndex() < 0:
                self.server_combo.setCurrentIndex(0)
        self._refresh_tray_menus()
        self._server_changed()

    def _selected_server(self) -> dict | None:
        data = self.server_combo.currentData()
        return data if isinstance(data, dict) else None

    def _selected_route(self) -> VlessLink | None:
        index = self.route_combo.currentIndex()
        if 0 <= index < len(self._routes):
            return self._routes[index]
        return None

    def _selected_profile(self) -> RoutingProfile:
        profile = self.profile_combo.currentData()
        return (
            profile if isinstance(profile, RoutingProfile) else RoutingProfile(profile)
        )

    @Slot()
    def _server_changed(self) -> None:
        self._routes = []
        self._latencies = {}
        self.route_combo.clear()
        server = self._selected_server()
        enabled = server is not None
        self.remove_server_button.setEnabled(enabled)
        self.refresh_button.setEnabled(enabled)
        if enabled:
            self._refresh_routes()
        else:
            self.route_combo.addItem("Сначала добавьте VPS")
        self._refresh_tray_menus()
        self._on_snapshot(self._controller.snapshot)

    @Slot()
    def _refresh_routes(self) -> None:
        server = self._selected_server()
        if not server or self._operation is not None:
            return
        url = server.get("subscription_url", "")
        if not url:
            QMessageBox.warning(self, "Нет подписки", "У сервера нет subscription URL.")
            return

        self.route_combo.clear()
        # Skeleton-style placeholder: ellipsis + spinner в кнопке,
        # чтобы было видно, что идёт сеть, не UI завис.
        self.route_combo.addItem("⏳ Загрузка подписки…")
        self.refresh_button.setEnabled(False)
        self.refresh_button.setText("…")
        self._set_operation_busy(True)

        should_probe = self._controller.snapshot.state != ConnectionState.CONNECTED

        def load() -> tuple[list[VlessLink], dict[str, int | None]]:
            routes = subscription.parse(subscription.fetch(url))
            if not routes:
                raise RuntimeError(
                    "Подписка не содержит поддерживаемых VLESS-маршрутов"
                )
            latencies = probe_routes(routes) if should_probe else {}
            return routes, latencies

        self._start_operation(load, self._routes_loaded, self._routes_failed)

    def _routes_loaded(self, result: object) -> None:
        if not isinstance(result, tuple) or len(result) != 2:
            routes, latencies = [], {}
        else:
            routes = list(result[0])
            latencies = dict(result[1])
        self._routes = routes
        self._latencies = latencies
        self.route_combo.clear()
        for route in routes:
            label = route.remark or route.label
            latency_ms = latencies.get(route.raw)
            latency_label = (
                f" · {latency_ms} ms"
                if latency_ms is not None
                else (" · timeout" if route.raw in latencies else "")
            )
            self.route_combo.addItem(f"{label} — {route.label}{latency_label}")
        default = subscription.pick_default(routes)
        if default is not None:
            self.route_combo.setCurrentIndex(routes.index(default))
        self._append_log(f"Подписка обновлена: {len(routes)} маршрутов")
        self._refresh_tray_menus()
        self.refresh_button.setEnabled(True)
        self.refresh_button.setText("Обновить")
        self._set_operation_busy(False)
        self._on_snapshot(self._controller.snapshot)

    def _routes_failed(self, message: str) -> None:
        self._routes = []
        self._latencies = {}
        self._connect_after_route_load = False
        self.route_combo.clear()
        self.route_combo.addItem("Не удалось загрузить маршруты")
        self._append_log(f"Ошибка подписки: {message}")
        self._refresh_tray_menus()
        self.refresh_button.setEnabled(True)
        self.refresh_button.setText("Обновить")
        self._set_operation_busy(False)
        QMessageBox.warning(self, "Ошибка подписки", message)
        self._on_snapshot(self._controller.snapshot)

    @Slot()
    def _add_server(self) -> None:
        dialog = AddServerDialog(self)
        if dialog.exec() != AddServerDialog.DialogCode.Accepted:
            return
        values = dialog.values()
        self._append_log(f"Начинаю развёртывание на {values['host']}…")
        self._set_operation_busy(True)

        thread = make_deploy_thread(
            ssh_client=SSHClient(),
            host=values["host"],
            port=values["port"],
            user=values["user"],
            password=values["password"],
            key_path=values["key_path"],
            sudo_password=values["sudo_password"],
            email=values["email"],
        )
        self._deploy_thread = thread
        thread.step_changed.connect(
            lambda index, name: self._append_log(f"[{index + 1}/{len(STEPS)}] {name}")
        )
        thread.log_line.connect(self._append_log)
        thread.finished_ok.connect(
            lambda result: self._deployment_finished(values, result)
        )
        thread.failed.connect(self._deployment_failed)
        thread.finished.connect(self._deployment_thread_finished)
        thread.start()

    @Slot()
    def _install_tun_helper(self) -> None:
        if self._operation is not None:
            return
        self._append_log("Запрашиваю права для установки TUN helper…")
        self._set_operation_busy(True)

        def succeeded(result: object) -> None:
            self._set_operation_busy(False)
            if self._desktop_backend is None or not self._desktop_backend.tun_available:
                message = (
                    "Installer завершился, но helper socket недоступен. "
                    "Проверьте systemctl status xrayebator-gui-helper."
                )
                self._append_log(message)
                QMessageBox.warning(self, "TUN helper", message)
                return
            self._tun_available = True
            self.mode_combo.setItemText(0, "TUN — доступен для вашей ОС")
            self.mode_combo.setCurrentIndex(0)
            self.install_helper_button.hide()
            self._append_log(str(result))
            QMessageBox.information(
                self,
                "TUN helper",
                "Privileged helper установлен. Режим TUN готов к подключению.",
            )

        def failed(message: str) -> None:
            self._set_operation_busy(False)
            self._append_log(f"Установка TUN helper не удалась: {message}")
            QMessageBox.critical(self, "Ошибка установки TUN helper", message)

        self._start_operation(install_linux_helper, succeeded, failed)

    def _deployment_finished(self, values: dict, result: dict) -> None:
        subscription_url = result.get("subscription_url")
        if not subscription_url:
            self._append_log(
                "quickstart не вернул subscription_url — устаревший сервер? "
                "Сервер не добавлен, проверьте /usr/local/etc/xray/profiles/."
            )
            return
        server = self._store.add(
            name=values["host"],
            host=values["host"],
            port=values["port"],
            user=values["user"],
            auth_type=values["auth_type"],
            password=values["password"],
            key_path=values["key_path"],
            subscription_url=subscription_url,
            profile=result.get("profile", "happ"),
        )
        self._append_log("Сервер добавлен, subscription получена и сохранена.")
        self._connect_after_route_load = True
        self._reload_servers(select_id=server["id"])

    def _deployment_failed(self, message: str) -> None:
        # Фильтруем возможные секреты (токены подписок, vless://) из сообщения об ошибке.
        from ..core.deploy import redact_log_line

        safe_message = redact_log_line(message)
        self._append_log(f"Развёртывание не удалось: {safe_message}")
        QMessageBox.critical(self, "Ошибка развёртывания", safe_message)

    def _deployment_thread_finished(self) -> None:
        self._deploy_thread = None
        self._set_operation_busy(self._operation is not None)
        self._on_snapshot(self._controller.snapshot)

    @Slot()
    def _remove_server(self) -> None:
        server = self._selected_server()
        if not server:
            return
        # Предупредить, если сейчас идёт активное соединение через этот сервер,
        # иначе после удаления маршрут потеряет свой сервер и поломает работу.
        # GUI-7-fix: раньше сравнивали route.port (VLESS-порт маршрута) с
        # server.get("port", 443) (SSH-порт сохранённого сервера) — это всегда
        # False, потому что 22 ≠ 443.
        # Правильная проверка: адрес маршрута совпадает с адресом сервера.
        route = self._controller.snapshot.route
        connected_here = (
            self._controller.snapshot.state == ConnectionState.CONNECTED
            and route is not None
            and route.address == server.get("host")
        )
        warning_extra = (
            "\n\n⚠ ВНИМАНИЕ: вы сейчас подключены через этот сервер! "
            "Он будет отключён и удалён."
            if connected_here
            else ""
        )
        answer = QMessageBox.question(
            self,
            "Удалить сервер?",
            f"Удалить {server.get('name') or server.get('host')} из приложения?\n"
            "Конфигурация VPS изменена не будет."
            + warning_extra,
        )
        if answer != QMessageBox.StandardButton.Yes:
            return
        # P2-gui-fix: при активном соединении реально отключаемся через ту же
        # машинерию, что и кнопка «Отключить» (_toggle_connection → disconnect),
        # и удаляем запись ТОЛЬКО после подтверждённого DISCONNECTED. Раньше запись
        # удалялась сразу: SSH-сеанс/controller оставался активным.
        if connected_here:
            self._remove_after_disconnect(server["id"])
        else:
            self._perform_store_remove(server["id"])

    def _remove_after_disconnect(self, server_id: str) -> None:
        self._set_operation_busy(True)

        def failed(message: str) -> None:
            self._set_operation_busy(False)
            self._append_log(message)
            QMessageBox.warning(self, "Не удалось отключиться", message)
            self._on_snapshot(self._controller.snapshot)

        def succeeded(result: object) -> None:
            self._set_operation_busy(False)
            if isinstance(result, ConnectionSnapshot):
                if result.state == ConnectionState.DISCONNECTED:
                    self._append_log("Соединение отключено")
                elif result.state != ConnectionState.ERROR:
                    failed("Соединение не было отключено.")
                    return
            self._perform_store_remove(server_id)

        self._start_operation(self._controller.disconnect, succeeded, failed)

    def _perform_store_remove(self, server_id: str) -> None:
        self._store.remove(server_id)
        self._reload_servers()

    @Slot()
    def _toggle_connection(self) -> None:
        state = self._controller.snapshot.state
        # мгновенная критическая секция: до любого длинного кода помечаем UI как busy,
        # чтобы двойной клик не мог запустить второй OperationThread.
        if state in _BUSY_STATES or self._operation is not None:
            return
        if state == ConnectionState.CONNECTED:
            self._start_connection_operation(self._controller.disconnect)
            return

        route = self._selected_route()
        if route is None:
            QMessageBox.warning(self, "Нет маршрута", "Сначала загрузите подписку.")
            return
        mode = self.mode_combo.currentData()
        if not isinstance(mode, ConnectionMode):
            mode = ConnectionMode(mode)
        profile = self._selected_profile()
        self._start_connection_operation(
            lambda: self._controller.connect(route, mode, profile)
        )

    @Slot()
    def _switch_route(self) -> None:
        # Guard до QMessageBox: молча игнорируем клики во время другой операции.
        if self._operation is not None or self._controller.snapshot.state in _BUSY_STATES:
            return
        route = self._selected_route()
        if route is None:
            return
        if self._controller.snapshot.state != ConnectionState.CONNECTED:
            QMessageBox.information(
                self,
                "Маршрут выбран",
                "Маршрут будет использован при следующем подключении.",
            )
            return
        self._start_connection_operation(
            lambda: self._controller.switch_route(route),
            switch=True,
        )

    @Slot()
    def _switch_profile(self) -> None:
        if self._operation is not None or self._controller.snapshot.state in _BUSY_STATES:
            return
        if self._controller.snapshot.state != ConnectionState.CONNECTED:
            return
        profile = self._selected_profile()
        self._start_connection_operation(
            lambda: self._controller.switch_profile(profile),
            switch=True,
        )

    @Slot()
    def _on_profile_selected(self) -> None:
        self._refresh_tray_menus()
        self._on_snapshot(self._controller.snapshot)

    def _select_server_from_tray(self, index: int) -> None:
        if 0 <= index < self.server_combo.count():
            self.server_combo.setCurrentIndex(index)

    def _select_route_from_tray(self, index: int) -> None:
        if not 0 <= index < len(self._routes):
            return
        self.route_combo.setCurrentIndex(index)
        if self._controller.snapshot.state == ConnectionState.CONNECTED:
            self._switch_route()
        else:
            self._refresh_tray_menus()

    def _select_profile_from_tray(self, profile: RoutingProfile) -> None:
        for index in range(self.profile_combo.count()):
            if self.profile_combo.itemData(index) == profile:
                self.profile_combo.setCurrentIndex(index)
                break
        if self._controller.snapshot.state == ConnectionState.CONNECTED:
            self._switch_profile()
        else:
            self._refresh_tray_menus()

    def _refresh_tray_menus(self) -> None:
        # Guard: в diagnostic режиме (XRAYEBATOR_NO_TRAY) или если tray
        # не создался — пропускаем манипуляции с меню.
        if (
            self.tray is None
            or self.tray_server_menu is None
            or self.tray_route_menu is None
            or self.tray_profile_menu is None
        ):
            return
        self.tray_server_menu.clear()
        for index in range(self.server_combo.count()):
            action = self.tray_server_menu.addAction(self.server_combo.itemText(index))
            action.setCheckable(True)
            action.setChecked(index == self.server_combo.currentIndex())
            action.triggered.connect(
                lambda checked=False, selected=index: (
                    self._select_server_from_tray(selected)
                )
            )
        self.tray_server_menu.setEnabled(self.server_combo.count() > 0)

        self.tray_route_menu.clear()
        for index, route in enumerate(self._routes):
            action = self.tray_route_menu.addAction(route.remark or route.label)
            action.setCheckable(True)
            action.setChecked(index == self.route_combo.currentIndex())
            action.triggered.connect(
                lambda checked=False, selected=index: (
                    self._select_route_from_tray(selected)
                )
            )
        self.tray_route_menu.setEnabled(bool(self._routes))

        self.tray_profile_menu.clear()
        selected_profile = self._selected_profile()
        for profile in RoutingProfile:
            action = self.tray_profile_menu.addAction(profile.label)
            action.setCheckable(True)
            action.setChecked(profile == selected_profile)
            action.triggered.connect(
                lambda checked=False, selected=profile: (
                    self._select_profile_from_tray(selected)
                )
            )

    def _start_connection_operation(
        self, operation: Callable[[], object], *, switch: bool = False
    ) -> None:
        self._set_operation_busy(True)

        def failed(message: str) -> None:
            self._set_operation_busy(False)
            self._append_log(message)
            title = "Маршрут восстановлен" if switch else "Ошибка подключения"
            icon = QMessageBox.Icon.Warning if switch else QMessageBox.Icon.Critical
            box = QMessageBox(icon, title, message, parent=self)
            box.exec()
            self._on_snapshot(self._controller.snapshot)

        def succeeded(result: object) -> None:
            self._set_operation_busy(False)
            if isinstance(result, ConnectionSnapshot):
                if result.state == ConnectionState.CONNECTED:
                    self._append_log(
                        f"Подключено через {result.route.label if result.route else '?'}; "
                        f"внешний IP: {result.external_ip or '?'}"
                    )
                elif result.state == ConnectionState.DISCONNECTED:
                    self._append_log("Соединение отключено")
            self._on_snapshot(self._controller.snapshot)

        self._start_operation(operation, succeeded, failed)

    def _start_operation(
        self,
        operation: Callable[[], object],
        on_success: Callable[[object], None],
        on_failure: Callable[[str], None],
    ) -> None:
        if self._operation is not None:
            return
        worker = OperationThread(operation, self)
        self._operation = worker
        worker.succeeded.connect(on_success)
        worker.failed.connect(on_failure)
        worker.finished.connect(self._operation_finished)
        worker.start()

    def _operation_finished(self) -> None:
        self._operation = None
        # GUI-2-fix: worker.succeeded срабатывает РАНЬШЕ worker.finished, поэтому
        # success-callback вызывает _on_snapshot() пока self._operation ещё не очищен,
        # и busy остаётся True. После очистки делаем единый repaint/snapshot —
        # прогресс скрывается, кнопки разблокируются.
        self._on_snapshot(self._controller.snapshot)
        if self._connect_after_route_load and self._selected_route() is not None:
            self._connect_after_route_load = False
            self._toggle_connection()

    def _set_operation_busy(self, busy: bool) -> None:
        self.add_server_button.setEnabled(not busy)
        self.server_combo.setEnabled(not busy)
        self.mode_combo.setEnabled(not busy)
        self.profile_combo.setEnabled(not busy)
        self.refresh_button.setEnabled(not busy and self._selected_server() is not None)
        self.install_helper_button.setEnabled(not busy)

    @Slot(object)
    def _on_snapshot(self, snapshot: ConnectionSnapshot) -> None:
        label = _STATE_LABELS[snapshot.state]
        color = _STATE_COLORS[snapshot.state]
        self.status_label.setText(label)
        self.status_label.setStyleSheet(
            f"color: {color}; font-weight: bold"
        )
        self.ip_label.setText(
            f"Внешний IP: {snapshot.external_ip}" if snapshot.external_ip else ""
        )
        connected = snapshot.state == ConnectionState.CONNECTED
        busy = snapshot.state in _BUSY_STATES or self._operation is not None
        # Прогресс-бар виден на всех промежуточных стадиях, чтобы UI не выглядел зависшим.
        self.busy_progress.setVisible(busy)
        if snapshot.route is not None and (busy or snapshot.error):
            for index, route in enumerate(self._routes):
                if route.raw == snapshot.route.raw:
                    self.route_combo.blockSignals(True)
                    self.route_combo.setCurrentIndex(index)
                    self.route_combo.blockSignals(False)
                    break
        if snapshot.routing_profile is not None and (busy or snapshot.error):
            for index in range(self.profile_combo.count()):
                if self.profile_combo.itemData(index) == snapshot.routing_profile:
                    self.profile_combo.blockSignals(True)
                    self.profile_combo.setCurrentIndex(index)
                    self.profile_combo.blockSignals(False)
                    break
        self.connect_button.setText("Отключить" if connected else "Подключить")
        self.connect_button.setEnabled(
            not busy and (connected or self._selected_route() is not None)
        )
        self.switch_button.setEnabled(
            connected and self._selected_route() is not None and not busy
        )
        self.profile_switch_button.setEnabled(
            connected
            and not busy
            and self._selected_profile() != snapshot.routing_profile
        )
        # GUI-3-fix: в NO_TRAY режиме tray_toggle_action=None — иначе AttributeError
        # на каждом snapshot'е при старте приложения.
        if self.tray_toggle_action is not None:
            self.tray_toggle_action.setText("Отключить" if connected else "Подключить")
            self.tray_toggle_action.setEnabled(not busy)
        target = ""
        if snapshot.route is not None and snapshot.routing_profile is not None:
            target = (
                f"\n{snapshot.route.remark or snapshot.route.label}"
                f" · {snapshot.routing_profile.label}"
            )
        if self.tray is not None:
            self.tray.setToolTip(f"Xrayebator — {label.lower()}{target}")
        self._refresh_tray_menus()
        # Показывать ошибку всегда, если она есть (не только в ERROR-статусе).
        self.status_label.setToolTip(snapshot.error or "")

    @Slot(QSystemTrayIcon.ActivationReason)
    def _tray_activated(self, reason: QSystemTrayIcon.ActivationReason) -> None:
        if reason in {
            QSystemTrayIcon.ActivationReason.Trigger,
            QSystemTrayIcon.ActivationReason.DoubleClick,
        }:
            self._show_window()

    def _show_window(self) -> None:
        self.show()
        self.raise_()
        self.activateWindow()

    def _toggle_theme(self) -> None:
        """Toggle between HeroUI v3 dark/light themes, persist the choice."""
        from PySide6.QtCore import QSettings
        from PySide6.QtWidgets import QApplication

        from .theme import apply_theme

        settings = QSettings("xrayebator", "xrayebator-gui")
        current = settings.value("theme", "dark")
        new_theme = "light" if current == "dark" else "dark"
        settings.setValue("theme", new_theme)

        app = QApplication.instance()
        if app is not None:
            apply_theme(app, mode=new_theme)

        self.theme_action.setText(
            "Тема: тёмная" if new_theme == "dark" else "Тема: светлая"
        )
        self._append_log(
            f"✓ Тема переключена на {'тёмную' if new_theme == 'dark' else 'светлую'}"
        )

    def closeEvent(self, event: QCloseEvent) -> None:
        if self._quitting:
            event.accept()
            return
        # GUI-3-fix + GUI-8-fix: в NO_TRAY режиме tray=None и закрытие окна должно
        # РЕАЛЬНО завершать приложение (выход из event loop), а не только скрывать
        # окно. Проблема до фикса: app.setQuitOnLastWindowClosed(False) в app.py
        # оставлял невидимый event loop жить в фоне; closeEvent лишь accept().
        # _quit() корректно обрабатывает disconnect в worker (если нужно), затем
        # вызывает app.quit() в GUI thread.
        if self.tray is None:
            event.accept()
            self._quit()
            return
        event.ignore()
        self.hide()
        self.tray.showMessage(
            "Xrayebator",
            "Приложение продолжает работать в системном трее.",
            QSystemTrayIcon.MessageIcon.Information,
            2500,
        )

    def _quit(self) -> None:
        self._quitting = True
        disconnect_needed = (
            self._controller.snapshot.state != ConnectionState.DISCONNECTED
        )
        # _controller.disconnect() может занять 1-5 сек (proxy.restore + xray stop).
        # Выполняем его в OperationThread — главный поток не должен зависать.
        if disconnect_needed and hasattr(self, "_quit_thread_guard"):
            return  # уже в процессе
        try:
            from PySide6.QtWidgets import QApplication

            app = QApplication.instance()

            if disconnect_needed:
                self._quit_thread_guard = True
                if self.tray is not None:
                    self.tray.setToolTip("Xrayebator — отключение перед выходом…")

                def _do_quit():
                    try:
                        self._controller.disconnect()
                    except Exception:
                        pass

                worker = OperationThread(
                    _do_quit,
                    parent=None,
                )
                # GUI-6-fix: tray.hide() и app.quit() — только в GUI thread.
                # finished сигнал эмитится в главном потоке — там и делаем hide/quit.
                worker.finished.connect(self._quit_after_disconnect)
                worker.start()
                # Храним ссылку чтобы GC не удалил до завершения
                self._quit_worker = worker
            else:
                if self.tray is not None:
                    self.tray.hide()
                if app is not None:
                    app.quit()
        except Exception:
            # fail-safe: даже если что-то пошло не так, выйти
            if self.tray is not None:
                self.tray.hide()
            try:
                from PySide6.QtWidgets import QApplication

                app = QApplication.instance()
                if app is not None:
                    app.quit()
            except Exception:
                pass

    def _quit_after_disconnect(self) -> None:
        """Callback в GUI thread после завершения disconnect в worker."""
        if self.tray is not None:
            self.tray.hide()
        try:
            from PySide6.QtWidgets import QApplication

            app = QApplication.instance()
            if app is not None:
                app.quit()
        except Exception:
            pass
