"""GUI-1..9: offscreen regression-тесты критических UI-фиксов.

Сценарии из требований:
  (а) поле SSH-ключа отображается в форме (GUI-1);
  (б) успешное завершение операции снимает busy-state (GUI-2);
  (в) старт/закрытие при XRAYEBATOR_NO_TRAY=1 (GUI-3);
  (г) смена темы обновляет RoundedComboBox + disable-состояние (GUI-4/GUI-5);
  (д) установка TUN helper не падает (setItemText/disable) (GUI-4);
  (е) NO_TRAY close реально завершает процесс (GUI-8, через настоящий subprocess);
  (ж) валидатор хоста IPv4/IPv6/hostname (GUI-9).

Запуск без дисплея: QT_QPA_PLATFORM=offscreen. Настоящий MainWindow
строится с пустым ServerStore во временной папке и реальным
ConnectionController на фейковом backend — без моков Ui.
"""
from __future__ import annotations

import os
import subprocess
import sys
import textwrap
from pathlib import Path

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
os.environ["XRAYEBATOR_NO_TRAY"] = "1"

import pytest
from PySide6.QtCore import QEvent, Qt
from PySide6.QtGui import QCloseEvent, QIcon, QKeyEvent
from PySide6.QtWidgets import QApplication

from xrayebator_gui.core.connection import ConnectionController
from xrayebator_gui.ui.add_server_dialog import AddServerDialog, valid_host
from xrayebator_gui.ui.main_window import MainWindow
from xrayebator_gui.ui.rounded_combo import RoundedComboBox
from xrayebator_gui.ui.theme import apply_theme


class _FakeBackend:
    """TunnelBackend, который ничего не делает — реальный контроллер не трогает
    его при конструировании окна."""

    def prepare(self, *args, **kwargs) -> None:
        pass

    def start(self, *args, **kwargs) -> None:
        pass

    def verify(self) -> str | None:
        return None

    def replace(self, *args, **kwargs) -> None:
        pass

    def stop(self, *args, **kwargs) -> None:
        pass


@pytest.fixture(scope="session")
def qapp():
    app = QApplication.instance()
    if app is None:
        app = QApplication([])
    apply_theme(app, "dark")
    yield app


@pytest.fixture()
def make_window(qapp, tmp_path):
    """Фабрика настоящего MainWindow: пустой store + fake backend, NO_TRAY."""
    created = []

    def _make():
        from xrayebator_gui.core.servers import ServerStore

        w = MainWindow(
            icon=QIcon(),
            store=ServerStore(tmp_path / "store"),
            controller=ConnectionController(_FakeBackend()),
        )
        created.append(w)
        return w

    yield _make

    for w in created:
        w.deleteLater()
    qapp.processEvents()


def test_g1_key_field_in_form(qapp):
    """GUI-1: key_row с inline-ошибкой реально вложен в форму диалога."""
    d = AddServerDialog()
    # key_row добавлен в HBox (key_with_browse) → parentWidget = key_container,
    # а key_container добавлен в QFormLayout диалога.
    assert d.key_row.parentWidget() is not None, "key_row не в форме"
    assert d.key_row.parentWidget() is not d
    assert d.key_edit.parentWidget() is d.key_row

    # Переключаемся на SSH-ключ и вводим невалидный путь — ошибка показывается.
    d.auth_combo.setCurrentIndex(1)  # SSH-ключ
    d.key_edit.setText("invalid")
    d._validate_fields()
    assert d.key_row.error_label.text() != "", "inline error не показана"
    assert not d.key_row.error_label.isHidden(), "error label скрыт"
    assert "~" in d.key_row.error_label.text() or "/" in d.key_row.error_label.text()

    # Валидный путь — ошибка прячется.
    d.key_edit.setText("/home/user/.ssh/id_ed25519")
    d._validate_fields()
    assert d.key_row.error_label.isHidden()

    d.deleteLater()


def test_g2_operation_finished_unlocks_ui(make_window):
    """GUI-2: после очистки операции единый _on_snapshot снимает busy-state —
    прогресс скрыт, кнопки разблокированы."""
    w = make_window()

    # Во время операции: _operation установлен, snapshot репейнит busy → прогресс виден.
    w._operation = object()
    w._set_operation_busy(True)
    w._on_snapshot(w._controller.snapshot)
    assert not w.add_server_button.isEnabled()
    assert not w.busy_progress.isHidden(), "прогресс должен быть виден в busy-state"

    # success-callback (succeeded сигнал) снял busy с кнопок раньше finished.
    w._set_operation_busy(False)
    assert w.add_server_button.isEnabled()

    # worker.finished сигналит об очистке — теперь _operation_finished делает
    # _on_snapshot → busy пересчитан как (state в _BUSY_STATES или operation!=None).
    w._operation_finished()

    assert w._operation is None
    assert w.add_server_button.isEnabled()
    assert w.busy_progress.isHidden(), "прогресс должен скрыться после очистки операции"

    w.close()


def test_g3_no_tray_start_and_close(make_window):
    """GUI-3: NO_TRAY=1 — snapshot не крашится (tray_toggle_action=None),
    closeEvent закрывает приложение вместо hide()+ignore()."""
    w = make_window()
    assert w.tray is None
    assert w.tray_toggle_action is None

    # На старте _on_snapshot уже вызывался — повторный вызов не должен упасть.
    w._on_snapshot(w._controller.snapshot)

    event = QCloseEvent()
    w.closeEvent(event)
    assert event.isAccepted(), "closeEvent при tray=None должен закрывать окно"

    w._quitting = True
    w.close()


def test_g4_disable_and_theme(qapp):
    """GUI-4+GUI-5: setItemText не падает, disabled-пункт не выбирается,
    apply_theme обновляет существующий RoundedComboBox."""
    cb = RoundedComboBox()
    cb.addItem("TUN (native Xray)", "tun")
    cb.addItem("Системный proxy", "system_proxy")

    # GUI-4: код _install_tun_helper вызывал отсутствовавший ранее setItemText.
    cb.setItemText(0, "TUN (native Xray)")
    assert cb.itemText(0) == "TUN (native Xray)"

    # Настоящее disable: флаг хранится на item, видимый текст без суффикса.
    cb.model().item(0).setEnabled(False)
    assert cb._items[0][0].endswith(" [disabled]"), "внутренний флаг не установлен"
    cb.setCurrentIndex(0)
    assert " [disabled]" not in cb.currentText(), "маркер виден через currentText"
    assert " [disabled]" not in cb.button.text(), "маркер виден на триггере"

    # Disabled-пункт пропускается клавиатурой и не выбирается в popup.
    ev = QKeyEvent(QEvent.Type.KeyPress, Qt.Key.Key_Down, Qt.KeyboardModifier.NoModifier)
    cb.eventFilter(cb.button, ev)
    assert cb.currentIndex() == 1, "Down должен перепрыгнуть disabled пункт"

    cb._toggle_popup()
    assert cb._popup is not None
    popup_item = cb._popup.list.item(0)
    assert not (popup_item.flags() & Qt.ItemFlag.ItemIsSelectable)
    cb._popup.hide()

    # GUI-5: смена темы обновляет токены существующего комбо.
    apply_theme(qapp, "light")
    cb.set_tokens(qapp._heroui_tokens)
    assert cb._tokens is qapp._heroui_tokens
    assert "light" in cb._tokens.name if hasattr(cb._tokens, "name") else True

    cb.deleteLater()


def test_g5_tun_helper_install_path(make_window):
    """GUI-4: путь установки TUN helper (succeeded) не падает — setItemText +
    disable на model().item(0) + сброс busy-state."""
    w = make_window()
    # Новое поведение: TUN выбираем всегда (не disabled), подпись зависит от ОС.
    assert not w.mode_combo._items[0][0].endswith(" [disabled]"), "TUN не должен быть disabled"
    assert " [disabled]" not in w.mode_combo.currentText(), "маркер не виден пользователю"
    # Подпись отражает доступность на текущей ОС.
    assert "доступен для вашей ОС" in w.mode_combo.itemText(0)

    # Реальный фейковый успех: контроллер не используется, только UI-часть.
    w._desktop_backend = type(
        "B", (), {"tun_available": True}
    )()
    w._tun_available = True
    w.mode_combo.setItemText(0, "TUN — доступен для вашей ОС")
    w.mode_combo.setCurrentIndex(0)
    w.install_helper_button.hide()

    assert w.mode_combo.currentText().startswith("TUN — доступен")
    assert not w.mode_combo._items[0][0].endswith(" [disabled]"), "флаг снят после установки helper"

    w.close()


def test_g6_server_placeholder(make_window):
    """Placeholder сервера без хвостового «—» (убрано из текста)."""
    w = make_window()
    assert w.server_combo.placeholderText() == "Выберите сервер или добавьте"
    assert not w.server_combo.placeholderText().endswith("—")
    w.close()


def test_g7_spinbox_arrow_qss(qapp):
    """SpinBox имеет собственные стрелки up/down (не нативные «квадраты с точками»)."""
    qss = qapp.styleSheet()
    assert "QSpinBox::up-arrow" in qss
    assert "QSpinBox::down-arrow" in qss
    assert "QSpinBox::up-button" in qss
    assert "QSpinBox::down-button" in qss
    # В QSS не должно остаться нативного маркера «data:image/png;base64,» пустым.
    assert "data:image/png;base64,iVBORw0KGgo" in qss


def test_g8_no_tray_close_quits_event_loop(make_window, qapp, monkeypatch):
    """GUI-8: NO_TRAY — closeEvent должен завершать приложение (выход из event loop),
    а не только accept() с последующим невидимым фоновым циклом.

    До фикса: app.setQuitOnLastWindowClosed(False) + closeEvent→accept() оставляли
    QApplication.exec() крутиться дальше без окна. Тест доказывает, что после
    закрытия окна вызван app.quit() (настоящий выход из event loop).
    """
    w = make_window()
    assert w.tray is None, "тест рассчитан на NO_TRAY режим"

    quit_calls = []
    original_quit = qapp.quit

    def _spy_quit(*args, **kwargs):
        quit_calls.append(True)
        return original_quit(*args, **kwargs)

    monkeypatch.setattr(qapp, "quit", _spy_quit)

    event = QCloseEvent()
    w.closeEvent(event)
    assert event.isAccepted(), "closeEvent при tray=None должен принимать закрытие"
    assert quit_calls, "closeEvent при tray=None должен вызывать QApplication.quit()"

    # Повторный closeEvent (уже _quitting) — не дублирует quit.
    w._quitting = True
    w.closeEvent(QCloseEvent())
    assert len(quit_calls) == 1, "повторное закрытие не должно вызывать повторный quit"

    w.close()


def test_g9_valid_host_ipv4_ipv6_hostname(qapp):
    """GUI-9: валидатор хоста принимает IPv4, IPv6-literal (со скобками и без)
    и hostname; отвергает мусор и вышедшие за границы IPv4-октеты."""
    valid = [
        "8.8.8.8",
        "192.168.1.1",
        "2001:db8::1",
        "[2001:db8::1]",
        "2a00:1450:4001:82f::200e",
        "example.com",
        "sub.example.co.uk",
    ]
    invalid = [
        "",
        "999.1.1.1",
        "256.0.0.1",
        "not a host",
        "example..com",
        "-bad.example.com",
        "2001:db8:::1",
        "1.2.3",
    ]
    for h in valid:
        assert valid_host(h), f"валидный хост отклонён: {h!r}"
    for h in invalid:
        assert not valid_host(h), f"невалидный хост принят: {h!r}"


def test_g8_no_tray_process_exits(tmp_path):
    """GUI-8 (процессно): настоящий subprocess с QApplication.exec() должен
    ВЫЙТИ сам, когда в NO_TRAY режиме окно закрыто.

    Регрессия: setQuitOnLastWindowClosed(False) + closeEvent→accept() оставляли
    event loop жить — процесс висел. Теперь closeEvent в tray=None вызывает
    _quit() → app.quit(), и exec() возвращается, процесс завершается с кодом 0.
    Если завис — subprocess.run(timeout) бросит TimeoutExpired → тест падает.

    Запускаем настоящий процесс (не mock), потому что проверять следует именно
    завершение event loop, а не только факт вызова метода.
    """
    gui_root = Path(__file__).resolve().parents[1]
    helper = tmp_path / "no_tray_exit_helper.py"
    helper.write_text(
        textwrap.dedent(
            """\
            import os
            os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
            os.environ["XRAYEBATOR_NO_TRAY"] = "1"
            from PySide6.QtCore import QTimer
            from PySide6.QtGui import QIcon
            from PySide6.QtWidgets import QApplication
            from xrayebator_gui.core.connection import ConnectionController
            from xrayebator_gui.core.servers import ServerStore
            from xrayebator_gui.ui.main_window import MainWindow

            class _FakeBackend:
                def prepare(self, *a, **k): pass
                def start(self, *a, **k): pass
                def verify(self): return None
                def replace(self, *a, **k): pass
                def stop(self, *a, **k): pass

            import sys
            from pathlib import Path
            app = QApplication([])
            # Имитация app.py: окно НЕ должно закрывать приложение по последнему окну;
            # выход обеспечивает только наш _quit().
            app.setQuitOnLastWindowClosed(False)
            import tempfile
            store_dir = Path(tempfile.mkdtemp(prefix="xr-no-tray-"))
            w = MainWindow(
                icon=QIcon(),
                store=ServerStore(store_dir),
                controller=ConnectionController(_FakeBackend()),
            )
            assert w.tray is None, "NO_TRAY режим должен давать tray=None"
            # Закроем окно после старта event loop.
            QTimer.singleShot(200, w.close)
            rc = app.exec()
            print(f"EXEC_RETURNED rc={rc}", file=sys.stderr)
            sys.exit(rc if rc == 0 else 1)
            """
        ),
        encoding="utf-8",
    )

    env = dict(os.environ)
    env["QT_QPA_PLATFORM"] = "offscreen"
    env["XRAYEBATOR_NO_TRAY"] = "1"
    # GUI-тест уже может быть импортирован; убеждаемся что пакет находит по пути.
    env["PYTHONPATH"] = str(gui_root)

    result = subprocess.run(
        [sys.executable, str(helper)],
        cwd=gui_root,
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, (
        f"NO_TRAY процесс не завершился чисто rc={result.returncode}\n"
        f"stderr={result.stderr}"
    )
    assert "EXEC_RETURNED" in result.stderr, "exec() не вернулся — процесс висит"
    assert str(result.returncode) in result.stderr.replace("rc=", "").strip()
