# Анализ методологии Xrayebator — баги, риски деплоя, мёртвый код

> Временный файл. Создан: 2026-08-05. Анализ покрыл: `xrayebator` (9564 стр.), `install.sh` (1051), `update.sh` (1063), `uninstall.sh` (135), 18 тестов `validation/`, GUI-тесты и CI. Критичность: 🔴 высокая / 🟠 средняя / 🟡 низкая.

## 1. Деплой на VPS — install.sh / update.sh

- **🔴 A1. Повторная установка (`--fresh`) уничтожает рабочий `config.json` без бэкапа.** `install.sh:129-133` → `806-871`. При reinstall конфиг безусловно перезаписывается heredoc-ом с пустыми inbounds. Профили на диске остаются, но активирующий их конфиг теряется безвозвратно — сервер работает без инбаундов. В update.sh бэкап есть, здесь — нет.
- **🔴 A2. Перезапись `/etc/resolv.conf` через systemd-resolved symlink.** `install.sh:183-187`. `printf > /etc/resolv.conf` пишет сквозь symlink в `/run/systemd/resolve/stub-resolv.conf`, бэкап — `cp` содержимого, восстановление неверное. Диагностика DNS проверяет только archive.ubuntu.com — на Debian не срабатывает.
- **🟠 B1. `ufw --force enable` включается до открытия SSH-порта.** `install.sh:887-897`. Default policy deny. SSH на custom-порту → новые подключения отрезаются. Нужно детектить SSH-порт и открывать его первым.
- **🟠 B2. Curl-загрузки без тайм-аутов** — `install.sh:322,332,589,603,929`; `update.sh:518,527,572,587` — только `--connect-timeout`, нет `--max-time`.
- **🟠 B3. `systemctl restart xray` без `sleep` перед `is-active`** — `install.sh:1016-1017`; в update.sh пауза есть.
- **🟡 B4. «Успешно запущен» при пустых inbounds** — `install.sh:1017-1021`.
- **🟠 C1. Self-swap в update.sh — двойная работа.** `update.sh:368-429,421-428`.
- **🟠 C2. Множественные рестарты за один update** (AdGuard + DNS + миграции).

## 2. Отдача ключа и включение сервера — quickstart / happ-setup

- **🔴 A3. `quickstart` не идемпотентен.** `xrayebator:9362-9365`. `ss -ltnp 'sport = :8443' | grep -q LISTEN` отклоняет повторный запуск, даже если 8443 слушает наш собственный nginx с первого прохода.
- **🟠 A4. Subscription-хендлер проверяется только `is-active`, без HTTP self-test.** `xrayebator:5133-5155`; вызов в quickstart `:9444`. `_subscription_local_self_test` (`:5166`) вызывается только в TUI-пути (`:5215,5220`), не в quickstart/happ-setup.
- **🟠 A5. IPv6-деплой не работает.** `xrayebator:9268-9271` принимает IPv6, certbot IP-TLS выдаёт серты только для IPv4. Ошибка вводит в заблуждение. Плюс **🔴** vless:// URL без `[...]` для IPv6 (`_generate_vless_url_pure`, `:449-451,482`).
- **🟠 A6. `happ-setup` на чистом VPS не может создать профиль.** `xrayebator:9470-9493`. Нет `_migrate_mlkem_keys`, а `create_profile_all_routes` идёт с `pq_enabled=true` → «PQ ключи отсутствуют».
- **🔴 A7. Деструктивные действия с nginx без проверки занятости.** `xrayebator:9331` `rm -f /etc/nginx/sites-enabled/default`, перехват 80 (`:9317-9328`), `[::]:8443 ssl` (`:9372-9404`). `nginx -t` не проверяет bind-конфликты. На VPS с сайтом quickstart ломает чужие host-ы.
- **🟠 A8. Повторный `certonly` упирается в Let's Encrypt rate-limit.** `xrayebator:9346-9357`.
- **🟡 A9. happ-setup доверяет устаревшим `.subscription_*`.** `:9500-9504`. `_happ_find_existing_multiroute_profile` (`:5084-5098`) требует `live_count>=7`; при <7 живых — новый профиль рвёт токены.
- **🟡 A10. Renew-таймер без `Persistent=true`.** `:802-830`.

## 3. Ядро — инбаунды, профили, рестарт

- **🔴 A11. Коллизия случайных портов у 7 маршрутов multi-route.** `xrayebator:6475-6501, 6558-6583`. 7 `find_available_random_port` вызываются до создания инбаундов без взаимной исключённости. Два маршрута → один порт → `add_inbound` отклоняет → весь профиль откатывается.
- **🟠 A12. Откат через голый `cp` в обход безопасной записи.** `xrayebator:6569,6572-6574`. Не вызывается `fix_xray_permissions`.
- **🟠 A13. Хрупкая проверка валидации.** `xrayebator:1100`, `:4372`: `grep -qx "Configuration OK."` — точное совпадение; вариант вывода с пробелом/CR = ложный откат.
- **🟠 B5. Нет файловой блокировки (flock).** `safe_jq_write` `:873-904`, `backup_config` `:908-934`. GUI + CLI одновременно → последний запишет config, откат по чужому бэкапу.
- **🟡 B6. `$RANDOM` bias при выборе порта** — `:235`.
- **🟡 B7. `safe_restart_xray` откатывает только config.json, не профили** — `:1079-1138`.
- **🟡 B8. Медленный цикл uuid→файл при SNI-конфликте** — `:6917-6929`.

## 4. Мёртвый код

- **🟠 D1. update.sh: блок `update_xray_core` + 3 хелпера (260 строк) никогда не вызываются** — `update.sh:623-882`. Бинарь обновляет `xrayebator update`. Трёхкратный inline-дубль.
- **🟡 D2. `_ip_renew_timer_active()` объявлена, нигде не вызывается** — `xrayebator:832`.
- **🟡 D3. Дубль certbot-логики**: quickstart инлайн `:9284-9315` вместо `_ensure_certbot_ip_tls` (`:740-792`).
- **🟡 D4. `_subscription_local_self_test` недоступна из quickstart/happ-setup** — см. A4.

## 5. uninstall.sh — неполнота удаления

В uninstall.sh нет ни одного упоминания nginx/letsencrypt/certbot/timer. Остаются:
- **🔴** nginx vhost'ы `xrayebator-sub` + `xrayebator-selfsteal` — nginx слушает 8443, 502.
- **🔴** certbot-сертификаты в `/etc/letsencrypt`.
- **🔴** systemd-таймер `xrayebator-ip-renew.{service,timer}` — стреляет каждые 12ч.
- **🟠** webroot `/var/www/xrayebator-ip-acme`, `/var/www/xrayebator-selfsteal-acme`, snap certbot.
- **🟠** AdGuardHome в `/opt` при прямом uninstall.
- **🟡** `/var/mail/xray`, journald-архивы.

Позитив: порядок (stop→delete), идемпотентность, безопасные `rm -rf`.

## 6. Тесты и CI

Сильные: `test-bbr-removal-migration.sh`, `test-transaction-safety.sh`, `test-happ-subscription-static.sh`. Runtime-тесты корректно source-ят скрипт с guard `XRAYEBATOR_SOURCED`.

- **🔴 D5. `test-cascade-routing.sh` не тестирует реальный код** — переписывает jq руками и ассертит свою копию, а не `_cascade_apply_current_upstream`.
- **🔴 D6. Полный bash-валидационный suite НЕ запускается в CI** — `gui-release.yml` ссылается на несуществующий `ci-linux.yml`; bash-тесты только при изменениях `gui/**`.
- **🟠 D7. uninstall.sh — ноль тестов.**
- **🟠 D8. Не покрыто**: firewall, dedup, subhttp runtime, backup-ротация, real restart.
- **🟡 D9. Хрупкие статические grep-тесты**, `rg`-guard деградирует.
- **🟡 D10. CLAUDE.md устарел**: «16 тестов» — фактически 18; firewall/dedup не покрыты.

## 7. Безопасность

- Модель прав правильная: private_key 600, бэкапы 600 `xray:xray`, snapshot-restore защищён проверкой пути.
- Валидация ввода строгая: имя профиля `^[a-zA-Z0-9_-]+$`, UUID/token валидируются.
- **🟠 E1. Скрипты с raw.githubusercontent не проверяются контрольной суммой** — update.sh:411,451,474,518; install.sh:944,959. SHA256 проверяется только для бинаря Xray.

## Сводка приоритетов

| Приоритет | Проблемы |
|---|---|
| 🔴 Критично | A1 · A3 · A7 · A11 · B5 · uninstall (nginx/серты/таймеры) · D5 · D6 |
| 🟠 Важно | A2 · A4 · A5 · A6 · A8 · A12 · A13 · B1 · D1 · E1 |
| 🟡 Минор | B2 · B3 · B4 · B6 · B7 · B8 · C1 · C2 · A9 · A10 · D2 · D3 · D4 · D7 · D8 · D9 · D10 |
