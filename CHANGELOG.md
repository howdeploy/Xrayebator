# Changelog

История пользовательских изменений Xrayebator. Серверный менеджер и Electron-приложение публикуются из канонического репозитория `howdeploy/Xrayebator`.

## [0.5.0] - 2026-09-22

Первый общий релиз обновлённого серверного менеджера и **Xrayebator Desktop GUI**.

### Добавлено

- Electron + React + TypeScript GUI для управления VPS по SSH.
- Dashboard, мастер добавления сервера, страница ключей и QR-кодов.
- Операции создания/удаления профилей и смены fingerprint, SNI и порта.
- Переключение интерфейса RU / EN / 中文.
- Стандартный HAPP schema-v3 профиль из семи маршрутов с единой subscription-ссылкой.
- IPv6-only сценарии, управляемая установка `--check` / `--resume` / `--fresh` и новые CLI-команды для GUI.
- Bash validation-suite из 24 тестов и Electron unit-тесты.

### Изменено

- Runtime-конфигурация проходит через backup, проверку Xray и rollback при ошибке.
- Установщик, обновления, firewall ownership и lifecycle-сценарии получили дополнительные проверки.
- Архивный PySide6 GUI отделён в `gui-legacy/`; активным приложением стал Electron GUI из `src/`.
- Документация синхронизирована на русском, английском и китайском языках.

### Исправлено

- Исправлены сценарии миграций, HAPP subscription, IPv6, сертификатов и синхронизации профилей.
- Убраны ошибки в GUI deployment, SSH-проверках, JSON CLI-ответах, SNI/port-change и тестовом CI.

### Ограничения

- Полный интерактивный menu surface, bypass, probe-test, revoke, happ-setup, cascade, self-steal и service logs остаются в CLI.
- Hardening-задачи последующего аудита `safe_jq_write`, lifecycle rollback, JSON escaping и проверок существующих inbound не входят в этот релиз.

Подробные русские release notes: [docs/releases/v0.5.0.md](docs/releases/v0.5.0.md).
