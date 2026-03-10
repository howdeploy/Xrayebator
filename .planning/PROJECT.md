# Xrayebator — Оптимизация и исправление багов

## What This Is

Xrayebator — автоматизированный менеджер Xray Reality VPN для обхода DPI-цензуры в России. После v1.0 это single-file Bash TUI с безопасными миграциями, non-root Xray, оптимизированным server-side config.json и актуализированными transport defaults под ТСПУ-2026.

## Core Value

VPN должен стабильно и быстро работать через ТСПУ — подключение не падает, скорость сопоставима с платными решениями, блокировки обходятся надёжно.

## Current State

- **Shipped version:** v1.0 (2026-03-10)
- **Milestone result:** Все 3 roadmap phases выполнены и заархивированы в `.planning/milestones/`
- **Runtime shape:** Один Bash-файл `xrayebator` + supporting `install.sh` / `update.sh`
- **Validated in v1.0:** safe restart + rollback, config migration safety, non-root Xray, DoH Local/UseIPv4 optimizations, randomized transport defaults, persisted gRPC/XHTTP metadata

## Next Milestone Goals

- Сформировать новый milestone через `$gsd-new-milestone`
- Пересобрать fresh `REQUIREMENTS.md` на основе нового аудита/продуктовых целей
- Решить, что из post-v1.0 идет дальше: quality hardening, transport follow-ups, или новые user-facing capabilities

## Requirements

### Validated

- ✓ Создание/удаление профилей с разными транспортами — existing
- ✓ Генерация VLESS-ссылок и QR-кодов — existing
- ✓ Смена SNI/fingerprint/порта профиля — existing
- ✓ Установка/удаление AdGuard Home — existing
- ✓ Система миграций при обновлении — existing
- ✓ Безопасная запись JSON через safe_jq_write — existing
- ✓ Firewall management (UFW) — existing
- ✓ Update/uninstall скрипты с выбором ветки — existing
- ✓ Безопасный restart Xray с валидацией и rollback — v1.0
- ✓ Non-root Xray через systemd drop-in и CAP_NET_BIND_SERVICE — v1.0
- ✓ Оптимизированный config.json baseline (DoH Local, UseIPv4, routeOnly, buffer tuning) — v1.0
- ✓ Актуализированные transport defaults: XHTTP first, random high ports, persisted grpc/xhttp metadata — v1.0

### Active

- [ ] Следующий milestone еще не определен — начать с нового requirements/roadmap цикла

### Out of Scope

- Рефакторинг архитектуры (разбиение на модули, multi-file) — скрипт остаётся single-file
- Добавление новых функций (новые меню, новые сервисы) — только фиксы и оптимизация
- Автоматические тесты — проект не предполагает test framework
- GUI/Web-интерфейс — остаётся терминальный TUI

## Context

### Результаты аудита (март 2026)

**Критические баги:**
1. `install.sh:125` — grep "Password:" вместо "Public" при извлечении публичного ключа
2. `update.sh:329` — DNS миграция затирает AdGuard Home (127.0.0.1) на DoH
3. `update_transport_settings_for_sni` — не использует safe_jq_write
4. Миграции (routing, xhttp_mode, xhttp_extra) — не используют safe_jq_write

**Производительность:**
5. DNS через DoH как primary — +100-300ms на каждый запрос
6. Блокировка QUIC (UDP/443) — убивает HTTP/3 (~40% интернета)
7. Freedom outbound без domainStrategy — потенциальные IPv6-проблемы
8. Нет xray -test перед systemctl restart — сломанный конфиг убивает VPN
9. gRPC serviceName "grpc" и XHTTP path "/xhttp" — легко детектируются DPI

**Безопасность:**
10. Xray запущен от root вместо capabilities
11. Порт 53 открыт публично при AdGuard Home — DNS amplification вектор
12. Порт 53 не закрывается при удалении AdGuard Home
13. Пустые shortIds — нет дополнительной аутентификации

**Код:**
14. Непоследовательное форматирование (create_profile строки 643, 658-660)
15. DNS config с geosite:geolocation-!cn — для Китая, не для России

### Технический стек
- Bash, jq, curl, ufw, systemctl, openssl, uuidgen, qrencode
- Xray-core (XTLS) с Reality протоколом
- Loyalsoldier geo-базы (geoip.dat, geosite.dat)
- AdGuard Home (опционально)

### Целевое окружение
- Сервер: Debian 10+ / Ubuntu 20.04+ VPS за пределами РФ
- Клиенты: v2rayNG, Shadowrocket, sing-box, Hiddify, v2rayN
- Противодействие: ТСПУ (Технические средства противодействия угрозам) Роскомнадзора

## Constraints

- **Single-file**: Весь runtime-код в одном файле `xrayebator` — нельзя разбивать
- **Bash only**: Никаких дополнительных языков (Python только для одноразовой подстановки в AdGuard yaml)
- **Backward compat**: Существующие профили и config.json должны продолжать работать после обновления
- **Production paths**: Все пути фиксированы (/usr/local/etc/xray/...) — менять нельзя
- **Russian UI**: Все строки пользовательского интерфейса на русском

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Не менять архитектуру | Single-file удобен для деплоя через curl, пользователи привыкли | ✓ Good — v1.0 shipped inside single-file Bash constraints |
| Ресерч РКН перед оптимизацией транспортов | Нужно знать актуальные методы блокировки чтобы не ломать рабочие связки | ✓ Good — informed Phase 3 transport ordering and warnings |
| Валидация конфига перед рестартом | Предотвращает downtime от сломанного JSON | ✓ Good — implemented in Phase 1 |
| Рандомизация serviceName/path | Затрудняет DPI-детекцию по известным паттернам | ✓ Good — implemented with persisted profile metadata in Phase 3 |

---
*Last updated: 2026-03-10 after v1.0 milestone*
