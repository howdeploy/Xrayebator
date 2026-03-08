# Requirements: Xrayebator Optimization

**Defined:** 2026-03-08
**Core Value:** VPN стабильно и быстро работает через ТСПУ — подключение не падает, блокировки обходятся надёжно

## v1 Requirements

### Config Hardening (CFG)

- [ ] **CFG-01**: DNS мигрирован на DoH Local (`https+local://1.1.1.1/dns-query`) для устранения латентности
- [ ] **CFG-02**: Freedom outbound имеет `domainStrategy: "UseIPv4"` для предотвращения IPv6-утечек
- [ ] **CFG-03**: Все inbound имеют sniffing `routeOnly: true` для предотвращения переопределения destination
- [ ] **CFG-04**: Перед каждым `systemctl restart xray` выполняется `xray run -test -config` с откатом при ошибке
- [ ] **CFG-05**: Access log отключен (`"access": "none"`) для приватности и производительности
- [ ] **CFG-06**: Policy section добавлен с `bufferSize: 4` для снижения потребления памяти
- [ ] **CFG-07**: BitTorrent заблокирован в routing rules (VPS TOS compliance)
- [ ] **CFG-08**: Все конфиг-изменения реализованы как миграции с marker-file (обратная совместимость)
- [ ] **CFG-09**: Бэкап config.json создаётся перед каждой миграцией

### Transport Modernization (TRN)

- [ ] **TRN-01**: XHTTP+Reality — первый и рекомендуемый транспорт в меню создания профиля
- [ ] **TRN-02**: Все транспорты используют рандомные высокие порты по умолчанию (не 443/8443/2053)
- [ ] **TRN-03**: gRPC serviceName генерируется рандомно (не "grpc")
- [ ] **TRN-04**: XHTTP path генерируется рандомно (не "/xhttp")
- [ ] **TRN-05**: Vision-на-443 убран как дефолтный вариант, предупреждение о блокировке ТСПУ
- [ ] **TRN-06**: Описания транспортов в меню обновлены с учётом актуальной информации о ТСПУ

### Security (SEC)

- [ ] **SEC-01**: Генерация non-empty shortIds при создании inbound (hex, 8 символов)
- [ ] **SEC-02**: Порт 53 не открывается публично при установке AdGuard Home (bind localhost)
- [ ] **SEC-03**: Порт 53 закрывается в UFW при удалении AdGuard Home
- [ ] **SEC-04**: install.sh: grep для публичного ключа исправлен ("Public" вместо "Password")
- [ ] **SEC-05**: Xray сервис запускается от non-root пользователя с CAP_NET_BIND_SERVICE
- [ ] **SEC-06**: update.sh не затирает AdGuard Home DNS (127.0.0.1) при обновлении

### Code Quality (CQ)

- [ ] **CQ-01**: Все jq-операции в миграциях используют safe_jq_write
- [ ] **CQ-02**: update_transport_settings_for_sni переведён на safe_jq_write
- [ ] **CQ-03**: SNI-лист очищен: удалены google.com, microsoft.com, yahoo.com и другие детектируемые домены
- [ ] **CQ-04**: Форматирование create_profile исправлено (отступы строк 643, 658-660)

## v2 Requirements

### Future Transport Features

- **FTR-01**: Finalmask (XICMP/XDNS) поддержка — ждём стабилизации API
- **FTR-02**: XHTTP CDN bypass options — не финализированы разработчиками Xray
- **FTR-03**: XDRIVE transport — ещё не выпущен
- **FTR-04**: XHTTP downloadSettings (split upload/download)
- **FTR-05**: Hysteria 2 интеграция — другой протокол, значительный scope

### Future UX Features

- **FUX-01**: Connection testing после создания/изменения профиля
- **FUX-02**: Subscription URL модель для безопасной передачи профилей
- **FUX-03**: Russia-specific geo databases (runetfreedom)
- **FUX-04**: Автообновление Xray-core

## Out of Scope

| Feature | Reason |
|---------|--------|
| Рефакторинг в multi-file | Скрипт остаётся single-file для простоты деплоя через curl |
| GUI/Web интерфейс | Остаётся терминальный TUI |
| Автоматические тесты | Проект не предполагает test framework |
| CDN fallback (Cloudflare) | Требует покупку домена, сложная настройка |
| stats/api секции Xray | Overhead, нужны только для мониторинга трафика |
| QUIC toggle (включить/выключить) | QUIC заблокирован ТСПУ с марта 2022, блокировка UDP/443 корректна |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| CFG-01 | Phase 2 | Pending |
| CFG-02 | Phase 2 | Pending |
| CFG-03 | Phase 2 | Pending |
| CFG-04 | Phase 1 | Pending |
| CFG-05 | Phase 2 | Pending |
| CFG-06 | Phase 2 | Pending |
| CFG-07 | Phase 2 | Pending |
| CFG-08 | Phase 1 | Pending |
| CFG-09 | Phase 1 | Pending |
| TRN-01 | Phase 3 | Pending |
| TRN-02 | Phase 3 | Pending |
| TRN-03 | Phase 3 | Pending |
| TRN-04 | Phase 3 | Pending |
| TRN-05 | Phase 3 | Pending |
| TRN-06 | Phase 3 | Pending |
| SEC-01 | Phase 1 | Pending |
| SEC-02 | Phase 1 | Pending |
| SEC-03 | Phase 1 | Pending |
| SEC-04 | Phase 1 | Pending |
| SEC-05 | Phase 1 | Pending |
| SEC-06 | Phase 1 | Pending |
| CQ-01 | Phase 1 | Pending |
| CQ-02 | Phase 1 | Pending |
| CQ-03 | Phase 1 | Pending |
| CQ-04 | Phase 1 | Pending |

**Coverage:**
- v1 requirements: 25 total
- Mapped to phases: 25
- Unmapped: 0

---
*Requirements defined: 2026-03-08*
*Last updated: 2026-03-08 after roadmap creation*
