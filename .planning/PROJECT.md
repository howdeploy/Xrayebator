# Xrayebator — Оптимизация и исправление багов

## What This Is

Xrayebator — автоматизированный менеджер Xray Reality VPN для обхода DPI-цензуры в России. Единый Bash-скрипт (~2500 строк) с интерактивным TUI, который превращает VPS в управляемый VPN-сервер. Развёртывается на Debian 10+/Ubuntu 20.04+.

## Core Value

VPN должен стабильно и быстро работать через ТСПУ — подключение не падает, скорость сопоставима с платными решениями, блокировки обходятся надёжно.

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

### Active

- [ ] Исправить все критические баги из аудита (~15 проблем)
- [ ] Оптимизировать DNS-конфигурацию (убрать DoH-латентность)
- [ ] Оптимизировать маршрутизацию (QUIC, freedom outbound)
- [ ] Актуализировать транспорты под текущие методы блокировки РКН/ТСПУ
- [ ] Добавить валидацию конфига перед рестартом Xray
- [ ] Исправить безопасность (root, порт 53, shortIds)
- [ ] Привести все jq-операции к safe_jq_write
- [ ] Защитить update.sh от затирания AdGuard Home DNS

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
| Не менять архитектуру | Single-file удобен для деплоя через curl, пользователи привыкли | — Pending |
| Ресерч РКН перед оптимизацией транспортов | Нужно знать актуальные методы блокировки чтобы не ломать рабочие связки | — Pending |
| Валидация конфига перед рестартом | Предотвращает downtime от сломанного JSON | — Pending |
| Рандомизация serviceName/path | Затрудняет DPI-детекцию по известным паттернам | — Pending |

---
*Last updated: 2026-03-08 after initialization*
