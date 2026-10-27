# Тесты

[← Назад к README](../../README.ru.md) · [English](../testing.md) · [简体中文](../zh-CN/testing.md)

---

## Локальная проверка чекаута

Запустите проверки синтаксиса Bash и все validation-скрипты из окружения, где есть Bash:

```bash
bash -n xrayebator
bash -n install.sh
bash -n update.sh
bash -n uninstall.sh
for test_file in validation/test-*.sh; do
  bash "$test_file" || exit 1
done
```

Локальный прогон ShellCheck — дополнительная проверка разработчика, если `shellcheck` установлен:

```bash
shellcheck -S error xrayebator install.sh update.sh uninstall.sh
```

ShellCheck не является CI-гейтом в текущих workflow. Гейт Linux CI — четыре проверки синтаксиса плюс
полный набор validation на Ubuntu; локальные результаты ShellCheck не стоит описывать как отдельное
требование CI.

Bash-тесты используют linux-инструменты: `jq`, `uuidgen`, `rg`. Поэтому голый чекаут в Windows Git Bash
может не суметь прогнать весь набор; для достоверных результатов используйте окружение Ubuntu CI или
Linux-машину. Проверки lifecycle должны также убеждаться в состоянии Xray, DNS и endpoint/сервиса
подписки после установки или обновления; runtime-транзакция `safe_restart_xray` не обещает, что пути
установщика и обновлятора ведут себя одинаково.

## Что покрывают тесты

В `validation/` ровно 45 скриптов. Запускайте каждый `validation/test-*.sh`; текущий набор:

| Тест | Что проверяет |
|---|---|
| `test-audit-functional.sh` | Функциональные regression-проверки аудита HowDeploy (P0/P1) |
| `test-audit-privilege-regressions.sh` | Границы привилегий, владение сертификатами, rollback и регрессии HAPP-setup |
| `test-traffic-limit-cli.sh` | Учёт трафика профилей: нормализацию единиц лимита, накопление дельт и сброс watermark, мгновенный бан/разбан с сохранением flow, кросс-гарды `expire` × трафик, миграцию Stats-инбаунда с коллизией порта, трафик-поля вывода `profiles`, регистрацию миграций |
| `test-alerts-monitor.sh` | Telegram-алерты мониторинга: `alerts-setup/status/enable/disable/test`, отсутствие сохранения конфига при недоставленном тесте, unit'ы и миграцию таймера, детекцию сервисов и бэкендов (hysteria2, AWG), подписку и её деградацию до `http_tls`, SNI-пробу (частичная/полная недоступность, восстановление, интервал, retry без повторной пробы), edge-триггер перезагрузки |
| `test-subscription-formats.sh` | Форматы подписки: нормализацию `vless://` (7 транспортов) и `hysteria2://`, IPv6/percent-decoding, Clash/mihomo YAML (reality-opts, flow, packet-encoding, grpc-opts, hysteria2, валидация PyYAML при наличии), sing-box JSON через `jq`, пропуск PQ и xhttp с пояснением, edge-cases (нет живых маршрутов, только PQ), content negotiation в heredoc'е хендлера, регистрацию миграции и CLI-контракт `profiles` |
| `test-channel-test-cli.sh` | CLI `channel-test`: шов «ссылка → конфиг клиента», выбор свободного SOCKS-порта и JSON-контракт (сам сетевой прогон возможен только на живом сервере) |
| `test-jq-keyword-compat.sh` | Совместимость с jq 1.6: объектные пары вида `label: $label` — синтаксическая ошибка на jq 1.6 (Ubuntu 22.04, Debian 12), поэтому метка маршрута передаётся как `$lbl` |
| `test-pq-routes.sh` | PQ-маршрут на любом транспорте: отдельный инбаунд с `decryption`, ML-KEM в ссылке, обычный маршрут не тронут, одно-маршрутная форма разворачивается перед добавлением, union портов для удаления, отказ на дубль |
| `test-sni-reachability.sh` | Выбор дефолтного SNI: недоступный кандидат заменяется доступным, полная недоступность оставляет прежний дефолт, одна проба на SNI за запуск, строгий критерий TLS 1.3 + HTTP проверяется на реальном выводе `openssl`, порядок кандидатов (голова списка, затем глобальные фолбэки) и обязательный второй замер |
| `test-dns01-certbot.sh` | DNS-01 (Cloudflare/Route53): валидацию домена (IP и локальные имена отклоняются) и провайдера, сборку аргументов certbot (плагин, credentials, propagation, deploy-hook, `-m` или регистрация без email), запись credentials `0600` с содержимым по провайдеру, nginx-vhost **без** `listen 80` и ACME-location, CLI-ошибки без записи на диск и проводку (диспатчер, пункт меню, пакеты плагинов, UFW-порт, маркеры `domain_tls`, manifest certbot, cleanup в uninstall) |
| `test-bbr-removal-migration.sh` | Безопасное удаление удалённого BBR/TCP tuning на всех путях |
| `test-profile-revoke-expire-cli.sh` | CLI `profile-revoke` (только токен / ротация uuid с сохранением чужих клиентов на общем порту) и сроки профилей (отключение, возврат из снимка, rebuild без снимка, идемпотентный `expire-check`) |
| `test-cascade-routing.sh` | Cascade routing |
| `test-cascade-upstream-import.sh` | Импорт upstream каскада из ссылки VLESS |
| `test-dead-stealth-route-pruning.sh` | Отсечение мёртвых stealth-маршрутов |
| `test-fingerprint-subscription-sync.sh` | Синхронность маршрутов и подписки при смене fingerprint |
| `test-happ-subscription-static.sh` | Обработчик HAPP-подписки (плейсхолдеры routing, порядок валидации) |
| `test-happ-client-routing.sh` | HAPP клиентский split-профиль: генератор из bypass-наборов (258 доменов, плейсхолдеры, `geoip:ru`), nginx-буферы, проводка меню |
| `test-legacy-profile-port-sync.sh` | Легаси-профили без `routes` получают обновления SNI/порта |
| `test-config-temp-json-suffix.sh` | Валидация конфига в установщике и обновлении: временный конфиг для `xray run -test` обязан заканчиваться на `.json` (Xray ≥ 26.10 определяет формат по расширению и игнорирует `-format json`), провал печатает вывод ядра, а `mktemp --suffix=.json` проверяется функционально |
| `test-installer-network-fallbacks.sh` | Сетевые fallback'и установщика |
| `test-legacy-udp443-migration.sh` | Одноразовое удаление legacy правила блокировки UDP/443 |
| `test-main-menu-numbering.sh` | Нумерацию пунктов меню и их соответствие обработчикам (1..14 с бэкенд-пунктами и мониторингом) |
| `test-backend-registry.sh` | Реестр бэкендов (мультипротокольный этап): source-mode CRUD через `safe_jq_write`, чтение installed/field, lifecycle-точка как безопасный no-op, форма JSON `backend-status` |
| `test-hysteria2-lifecycle.sh` | Бэкенд Hysteria 2: рендер `server.yaml` (userpass-карта, placeholder-fallback), модель безопасности юнита, arch-маппинг, TLS-детект, события грантов/revoke/expire-restore, реген deleted при заранее удалённом файле профиля, created = no-op (без авто-выдачи), pure-строитель `hysteria2://`, проводка диспетчера и подписки |
| `test-ssh-protect.sh` | Защита SSH от перебора: конфиг джейла (journald, 4 неудачи за 10 минут, бан 30 минут, эскалация), drop-in sshd (`MaxAuthTries 3` / `LoginGraceTime 30`), сохранение парольного входа, форма статус-JSON для GUI, снятие защиты, проводка в меню/CLI/quickstart/install.sh и валидация `--unban`. Плюс 24-часовое исключение для адреса деплоя: `ignoreip` с меткой срока, разбор адреса из `SSH_CONNECTION`/`SSH_CLIENT`, отказ для loopback, снятие по сроку и сохранение loopback-базы |
| `test-awg-ppa-repo.sh` | PPA `amnezia/ppa` ставится только вместе с ключом подписи: строка `signed-by`, порядок «ключ до репозитория», отсутствие репозитория без ключа, ремонт уже испорченного неподписанного репозитория, идемпотентность по маркеру и проводка ремонта в `main_menu`/`quickstart`/`happ-setup` |
| `test-awg-lifecycle.sh` | Бэкенд AmneziaWG: junk-диалект по умолчанию Amnezia (Jc=5, Jmin=10, Jmax=50, H1–H4=1..4, S1–S4 уникальные), генерация ключей, рендер серверного конфига (PostUp MASQUERADE, без peer-ов при установке), аллокация адресов, содержимое клиентского `.conf`, события revoke/expire/restore, реген deleted при заранее удалённом файле профиля, created = no-op (без авто-выдачи), диспетчер CLI |
| `test-main-readiness-regressions.sh` | Регрессии readyness после аудита: certbot-manifest, UFW manifest, nginx rollback, привилегии, SSH-порт |
| `test-multiroute-argument-preservation.sh` | Сохранение transport-аргументов multiroute-профиля |
| `test-port-change-cli.sh` | CLI `port-change`: сценарии unit/shared/move, неверный порт, multi-route `--route` |
| `test-bypass-cli.sh` | CLI `bypass`: JSON stdout, routing-правила, add с проверкой SNI |
| `test-project-update-rollback.sh` | Откат неудачного обновления проекта |
| `test-apt-lock-race.sh` | Гонка apt-lock: `DPkg::Lock::Timeout` при установках, учёт воркера `unattended-upgrade` и бюджет 12 минут в quickstart |
| `test-quickstart-email-and-inspect.sh` | Явный email-режим `quickstart` (`--without-email` без фиктивного адреса) и read-only инварианты `inspect --json` |
| `test-quickstart-migration-parity.sh` | `quickstart` гоняет те же критичные миграции, что и `main_menu` |
| `test-quickstart-subscription-port.sh` | `quickstart` использует canonical helper базы подписки и не возвращается к несвязанному hardcode URL |
| `test-quickstart-tls-fallback.sh` | Ветку graceful-degradation `http_tls`: переключение SUB_TLS_MODE, HTTP-only vhost (без ssl и proxy), маркеры с учётом режима, renew-таймер только в ip_tls и degraded-метаданные JSON |
| `test-sni-change-cli.sh` | CLI `sni-change`: JSON stdout, Reality, XHTTP host, синхронизацию, rollback |
| `test-subscription-server-name.sh` | Имя сервера подписки, которое видит клиент (HAPP) |
| `test-transaction-safety.sh` | Транзакционную безопасность операций с конфигом |
| `test-update-branch-pinning.sh` | `update <branch>` закрепляет ветку в `.current_branch`; GUI-обновление не откатывает сервер на другую ветку |
| `test-update-xray-core-sync.sh` | Синхронность обновления Xray-core |
| `test-vless-url-generation.sh` | Генерацию ссылок `vless://` |
| `test-xhttp-route-path-repair.sh` | Починку путей XHTTP-маршрутов при миграции |

> Статические тесты не заменяют проверку на disposable VPS: создание и удаление профиля, валидацию
> конфига, рестарт сервисов, rollback, поведение firewall и реальное подключение клиента.

## Проверка lifecycle и HAPP-эндпоинта

Для новой развёртки прогоните широкий путь `quickstart --email <адрес>` и убедитесь, что он поднимает
IP-TLS endpoint продукта на `8443`, создаёт профиль и оставляет здоровые сервисы. Его
неинтерактивные вызовы миграций — best-effort, поэтому дополнительно посмотрите маркеры миграций и
получившийся профиль/конфиг. Для существующей установки отдельно прогоните урезанный путь
`happ-setup`: удалите один или оба маркера подписки в одноразовом окружении и убедитесь, что он
отказывается их фабриковать, пока не проверен IP-TLS endpoint/сертификат продукта на `8443`. Когда
оба маркера на месте, убедитесь, что настройка переиспользует их, а не считает их наличие
доказательством, что endpoint всё ещё здоров: проверка оператором или повторный прогон подходящего
пути настройки всё равно нужны.

## Ручные проверки на живом сервере

Используйте подкоманду `run` Xray при проверке установленного конфига:

```bash
sudo xrayebator probe-test                                        # доступность SNI с VPS
sudo /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
sudo systemctl status xray --no-pager -l
sudo systemctl status xrayebator-sub --no-pager -l
curl -sS -i http://127.0.0.1:8080/sub/                            # ожидается 404
jq -r '.routes[] | [.label,.transport,.port,(.pq_enabled // false)] | @tsv' \
  /usr/local/etc/xray/profiles/<profile>.json
sudo xrayebator channel-test --name <profile>                     # реальный трафик через каждый маршрут
```

`channel-test` — единственная проверка, доказывающая, что маршрут действительно везёт трафик: он
поднимает локальный Xray-клиент по каждой ссылке подписки и прогоняет HTTP-запрос, отдавая по каждому
маршруту `ok`, `http` и задержку, включая PQ. Запускайте дважды: первый прогон сразу после перезапуска
Xray платит за прогрев соединения (на живом профиле было ~5.1 с и ~150 мс во втором прогоне), поэтому
одно медленное измерение ещё не значит, что канал сломан.

Локальный self-test подписки должен возвращать `404` без токена и `200` с валидным токеном и строками
VLESS. Проверьте, что заново созданный стандартный HAPP-профиль имеет `schema_version: 3` и семь
живых маршрутов, и что HAPP-тело публикует все семь: PQ-маршрут больше не отфильтровывается из него
(base64-тело для v2rayNG/v2rayN, наоборот, PQ-маршруты отбрасывает, поэтому в нём шесть). Существующий
профиль, переиспользованный HAPP-setup, может удовлетворять только минимуму из семи живых маршрутов,
поэтому смотрите его фактические labels и schema; миграция не доделывает недостающие маршруты. Если
UFW уже активен, сравните numbered rules до и после операции: установщик добавляет фиксированный
TCP-список сервисов проекта и не должен менять политику по умолчанию, а uninstall — удалять только
записанные как принадлежащие ему правила.

Для опциональных бэкендов одноразовый прогон на VPS должен дополнительно покрыть:
`hysteria2-install --grant-all` (сервис активен, UDP-листенер на месте, грант в `server.yaml`),
`awg-install --grant-all` (модуль в `lsmod`, `awg show awg0` показывает peer), цикл `profile-revoke`
с ротацией обоих грантов, цикл expire/restore и наличие ровно одной строки `hysteria2://` на каждый
грант в обоих телах подписки. CI покрывает рендеры, интеграцию с реестром и проводку диспетчера на
мокнутых бинарниках; сама установка пакетов (сеть, сборка DKMS, настоящий systemctl) и реальное
подключение клиента — проверки живого сервера по замыслу.

Неделя наблюдений на живом сервере проверяет не «работает сейчас», а «не деградировало ли само»:

```bash
systemctl show <unit> -p NRestarts --value              # у всех юнитов 0
journalctl -u xray --since "7 days ago" -p warning      # пусто
xrayebator inspect --json | jq '.profile_count, .route_count'
xrayebator channel-test --name <profile>                # 8/8 маршрутов, задержки одного порядка
```

На живом сервере такая неделя дала: ни одного warning Xray, ни одного перезапуска юнитов по сбою, 8/8
живых маршрутов с задержкой 150–250 мс. Единственные записи в журнале бэкенда Hysteria 2 за эту неделю —
`timeout: no recent network activity` при отключении клиента; ошибок со стороны сервера не было.

## Десктоп-GUI

В активном Electron GUI ровно двадцать пять unit-файлов Vitest:

| Тест | Что проверяет |
|---|---|
| `tests/unit/awg-shared.test.ts` | Парсинг AWG `.conf`, снятие комментариев, сборка `vpn://` и qCompress |
| `tests/unit/backend-manager.test.ts` | Разбор backend-статуса и AWG-конфигов (hysteria2/awg, флаги 3.1) |
| `tests/unit/calendar.test.ts` | Календарь: локальные ISO-даты без UTC-сдвига, сетка месяца, границы навигации |
| `tests/unit/countryFlag.test.ts` | Флаг страны для карточек серверов |
| `tests/unit/clipboard.test.ts` | Хелпер буфера обмена: отказ в копировании возвращает `false`, а не reject, поэтому UI не показывает молчаливый успех (все три сценария отказа) |
| `tests/unit/deployer.test.ts` | Аргументы quickstart: режимы provided/without email без фиктивного адреса, валидация только в режиме provided |
| `tests/unit/expire.test.ts` | Статусы срока действия, дата по часовому поясу сервера, приоритет флага отключения |
| `tests/unit/traffic.test.ts` | Хелперы лимита трафика: разбор и валидация ввода (`500MB`/`1.5GB`/`2TB`/`none`), форматирование расхода и лимита, описание чипа (тона 80% и исчерпания), преобразование лимита в поле ввода |
| `tests/unit/extractJson.test.ts` | Разбор JSON из вывода `xrayebator` |
| `tests/unit/probe-ports.test.ts` | Порты, которые использует проба доступности на Dashboard |
| `tests/unit/server-inspector.test.ts` | Нормализация диагностики: публичная vs local-only/unreachable подписка, partial- и refuse-import состояния |
| `tests/unit/dns01.test.ts` | Валидация DNS-01 (Cloudflare/Route53): правила домена, формы токена и AWS key/secret, сборка аргументов CLI и готовность |
| `tests/unit/gui-cache-wiring.test.ts` | Проводка GUI-кэшей: страница сервера открывается с карточкой, перечитанной из стора, а страница «Ключи» резолвит срок через кэш |
| `tests/unit/i18n-parity.test.ts` | Паритет ключей трёх локалей (ru/en/zh) |
| `tests/unit/server-keys-render.test.ts` | SSR страницы «Ключи»: кэшированная дата срока есть в самом первом рендере, а профиль, отсутствующий в обоих источниках, не даёт строки |
| `tests/unit/server-settings-render.test.ts` | SSR страницы «Настройки сервера»: разметка экрана подключения, контракт секций и smoke-рендер отдельной страницы «Существующие профили» |
| `tests/unit/server-manager.test.ts` | Валидация безопасных веток для обновления |
| `tests/unit/server-store.test.ts` | Идемпотентный импорт upsert по host+port, подсчёт ссылок на credential, кэш сроков профилей (запись полным набором, удалённый профиль исчезает) |
| `tests/unit/shell-command.test.ts` | POSIX-безопасное quoting аргументов shell и сборка sudo-команды |
| `tests/unit/ssh-access.test.ts` | Валидация параметров SSH-доступа, доступ к одобренным ключам и порядок разрешения ключа из keychain |
| `tests/unit/ssh-client.test.ts` | Доверие host-key, аутентификация и обработка несовпадения |
| `tests/unit/ssh-keychain.test.ts` | Сохранение/чтение/удаление ключей в системном keychain с guard'ами размера и повреждения (mock keytar) |
| `tests/unit/subscription.test.ts` | Парсинг подписки, извлечение VLESS-ссылок и HTTP-ошибки |
| `tests/unit/ui-contracts.test.ts` | Готовность deployment и формирование payload при выборе email-режима |
| `tests/unit/vless.test.ts` | Извлечение порта из IPv4- и IPv6-ссылок `vless://` |

`npm run typecheck` компилирует `tsconfig.node.json`, `tsconfig.web.json` и `tsconfig.contracts.json` —
последний проект реально проверяет типы строгих onboarding-контрактов из `tests/type-contracts/`
(обязательный `emailMode`, keychain-ссылка в выборщике ключа, открытый import API), потому что одной
Vitest-транспиляции для регрессии типов недостаточно.

Запускайте проверки Electron так:

```bash
npm run typecheck
npm test
npm run build
```

`tests/unit/shell-command.test.ts` намеренно вызывает `/bin/sh`. На Windows этот POSIX-специфичный тест
может падать из-за отсутствия `/bin/sh`; источник истины для него — Linux. Остальные unit-файлы всё
равно дают полезное локальное покрытие, а CI гоняет typecheck и unit-набор Electron на Ubuntu.

## CI workflow

У workflow разные зоны ответственности:

- `.github/workflows/ci-linux.yml` — гейт Bash-ядра на `ubuntu-24.04`: ставит `jq`, `uuid-runtime`
  и `ripgrep`, прогоняет все четыре проверки синтаксиса Bash, затем запускает каждый
  `validation/test-*.sh` (на момент написания — 45).
- `.github/workflows/release.yml` — активный путь релиза Electron для тегов `v*` и ручных запусков.
  Сначала job `preflight` проверяет, что файл релизных заметок `docs/releases/<tag>.en.md` существует
  и что секрет репозитория `AP3X0` (если задан) действительно может создавать релизы — проверка идёт
  пробным черновиком, который удаляется в том же шаге, чтобы неприятности всплывали за секунды, а не
  после трёх сборок под три платформы. Обе проверки только предупреждающие: релиз выходит всегда.
  Затем он прогоняет `npm run typecheck` и `npm test` на Ubuntu и собирает/пакует артефакты для
  Windows, macOS и Linux. Job `release` публикует от владельца токена `AP3X0`, если `preflight`
  подтвердил, что токен работает, иначе — от `github-actions[bot]` через встроенный `GITHUB_TOKEN`:
  автор GitHub-релиза фиксируется при создании и позже не переназначается.
- `.github/workflows/gui-release.yml` — legacy workflow PySide6. Он прогоняет Python `ruff` и
  `pytest gui-legacy/tests`, собирает legacy нативные бандлы и запускает лишь небольшой Bash-смоук;
  это не workflow unit-тестов Electron.

Матрица упаковки Windows не меняет источник истины Linux для POSIX-теста shell. Пакет для Windows может
быть собран релизным workflow, хотя локальный прогон на Windows не может выполнить тест с `/bin/sh`.
