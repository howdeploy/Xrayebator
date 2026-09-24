<div align="center">

# Xrayebator

<h3>Xray VLESS Reality на своём VPS</h3>

<p>
<strong>инбаунды</strong> · <strong>профили</strong> · <strong>подписка</strong> ·
<strong>bypass</strong> · <strong>каскад</strong>
</p>

<p>
<strong>Читать на других языках</strong><br>
<a href="README.md">🇺🇸 English</a> ·
<a href="README.ru.md">🇷🇺 Русский</a> ·
<a href="README.zh-CN.md">🇨🇳 简体中文</a>
</p>

<p>
<img alt="Bash 5.0+" src="https://img.shields.io/badge/bash-5.0%2B-4EAA25?style=flat-square&logo=gnubash&logoColor=white">
<img alt="Xray-core Reality" src="https://img.shields.io/badge/Xray--core-Reality-22D3EE?style=flat-square">
<img alt="HAPP subscription" src="https://img.shields.io/badge/subscription-HAPP-A78BFA?style=flat-square">
<a href="LICENSE"><img alt="MIT" src="https://img.shields.io/badge/license-MIT-3FB950?style=flat-square"></a>
</p>

<p>
<strong>Один bash-скрипт превращает чистый VPS в личный VLESS Reality сервер.</strong><br>
Xrayebator ставит Xray-core, поднимает Reality-инбаунды на случайных портах и для новой установки
создаёт стандартный schema-v3 HAPP-профиль из семи маршрутов. Существующий семимаршрутный профиль
может быть переиспользован при наличии живых маршрутов, поэтому при отладке label/schema проверяйте
profile JSON. Клиент получает маршруты одной HTTPS-ссылкой подписки. Актуальная серверная линия — 3.0;
опциональное Electron-десктоп-приложение имеет отдельную версию.
</p>

</div>

```bash
curl -fsSLo ./xrayebator-install.sh \
  https://raw.githubusercontent.com/howdeploy/Xrayebator/main/install.sh
less ./xrayebator-install.sh          # просмотрите скрипт перед запуском
sudo bash ./xrayebator-install.sh

# Флаги управления шагами (interrupt-safe install):
#   --check   Показать, какие из 10 шагов уже сделаны
#   --resume  Продолжить с первого незавершённого шага
#   --fresh   Сбросить маркеры и начать с нуля
```

<div align="center">

<p>
Debian 12/13 · Ubuntu 22.04/24.04 · от 512 MB RAM · права <code>root</code> или <code>sudo</code><br>
Дальше — <code>sudo xrayebator</code> → пункт <code>6</code> и подписка готова.
Подробности: <a href="#быстрый-старт">Быстрый старт</a>
</p>

<p>
<a href="#зачем-это-нужно">Назначение</a> ·
<a href="#карта-возможностей">Возможности</a> ·
<a href="#как-это-работает">Как это работает</a> ·
<a href="#быстрый-старт">Быстрый старт</a> ·
<a href="#документация">Документация</a> ·
<a href="#известные-ограничения">Ограничения</a> ·
<a href="#обновление-и-удаление">Обновление</a>
</p>

</div>

---

## Зачем это нужно

Личный VLESS Reality — это десяток ручных шагов: собрать инбаунд, сгенерировать ключи, подобрать
SNI, не сломать конфиг, раздать ссылку на телефон. Одна опечатка в `config.json` — и Xray не
поднимается.

Одного маршрута при этом мало. DPI режет транспорты неравномерно: в одной сети живёт TCP Vision, в
другой — только gRPC, в третьей вообще ничего кроме XHTTP. Держать под это несколько отдельных
конфигов вручную неудобно.

Xrayebator решает обе задачи так:

- профиль — это не один маршрут, а набор `routes` с общим `sub_token`;
- клиент получает весь набор одной короткой ссылкой подписки, а не семью ссылками `vless://`;
- runtime-изменения конфига идут через backup, явную валидацию `xray run -test` и авто-rollback, поэтому
  неудачная правка не должна оставлять сервер без VPN;
- смена SNI, порта или fingerprint не требует пересоздавать профиль. SNI и порт общие для inbound,
  а fingerprint — клиентский параметр конкретного профиля/маршрута.

Проект развивает и тестирует один человек. Ограничения из этого следуют прямо и описаны в разделе
[Известные ограничения](#известные-ограничения) — читайте его до установки на важный VPS.

## Карта возможностей

| Возможность | Что делает | Где реализовано |
|---|---|---|
| Установка Xray-core | Скачивает релиз с GitHub, обязательно сверяет SHA-256 с `.dgst`, ставит бинарь через `install -m 755`, делает self-test | `install.sh` |
| Reality-инбаунды | Поднимает инбаунды на свободных портах `30000-60000`, сверяясь и с `config.json`, и с реально слушающими сокетами | `xrayebator` |
| Multi-route профиль | Один профиль = набор маршрутов с общим `sub_token`; несколько профилей могут делить один порт | `profiles/<name>.json` |
| HAPP-подписка | Отдаёт список `vless://`, управляемый Global Proxy routing и geo-базы по защищённому токеном URL; наружу публикуется nginx по HTTPS | `subhttp.sh`, `xrayebator-sub.service` |
| Post-quantum XHTTP | Маршрут `xhttp-pq` работает с VLESS-шифрованием `mlkem768x25519plus` | `.vless_encryption`, `.vless_decryption` |
| Совместимость с v2ray | `v2rayNG`/`v2rayN` получают классический base64-body без HAPP-метаданных | `subhttp.sh` |
| Revoke подписки | Генерирует новый 32-символьный hex-токен, старый URL перестаёт работать | `openssl rand -hex 16` |
| Bypass routing | Семь групп доменов можно отправить напрямую через `freedom`, минуя VPN | меню `7` |
| Каскад | Переключает catch-all `tcp,udp` на зарубежный VLESS Reality upstream типа `tcp` или `xhttp` | `upstreams/cascade.json` |
| Self-steal заглушка | Ставит nginx с валидным сертификатом на `127.0.0.1:9444` и заводит Reality fallback на него | меню `9` |
| Безопасная запись JSON | Пишет временный файл в целевом каталоге, валидирует, атомарно переименовывает | `safe_jq_write` |
| Безопасный рестарт | Прогоняет `xray run -test -config` до рестарта; при ошибке откатывает конфиг из бэкапа | `safe_restart_xray` |
| Миграции | Одноразовые миграции по marker-файлам: backup → правка → рестарт → маркер | `run_migration` |
| geo-базы | Кладёт расширенные `geoip.dat` и `geosite.dat` из релизов Loyalsoldier в `/usr/local/share/xray` | `install.sh` |

Не поддерживается и не заявляется: H2, WebSocket, SplitHTTP, подписки Clash/mihomo.

## Как это работает

Управляющий поток. Любая правка конфига проходит один и тот же путь:

```text
sudo xrayebator
      │
      ▼
xrayebator  (bash)
создание профиля · смена SNI/port/fingerprint · миграции · routing
      │
      ├─ backup_config ───────► /usr/local/etc/xray/backups/<timestamp>
      │
      ├─ safe_jq_write ───────► config.json  +  profiles/<name>.json
      │
      └─ safe_restart_xray
               │
               ├─ xray run -test -config  → ok ──► systemctl restart xray
               │
               └─ конфиг невалиден ───────────────► rollback из бэкапа,
                                                    Xray продолжает работать
                                                    на старом конфиге
```

Клиентский поток. От ссылки подписки до выхода в интернет:

```text
клиент (HAPP)
    │  https://<домен-или-ip>/sub/<32-hex-token>
    ▼
nginx  :443  (или :8443, если 443 занят)
    │  proxy_pass
    ▼
xrayebator-sub.service   127.0.0.1:8080
    │  читает profiles/*.json и сверяет маршруты с живым config.json
    ▼
список vless://  — из 7 маршрутов профиля HAPP получает 6
    │
    ▼
Reality-инбаунд на порту 30000-60000   (User=xray, CAP_NET_BIND_SERVICE)
    │
    ├─ домен из включённой bypass-группы ──► freedom  (напрямую, без VPN)
    │
    └─ весь остальной tcp/udp ────────────► direct
                                            ИЛИ cascade-upstream ──► зарубежный VPS
```

### Маршруты профиля

HAPP-флоу создаёт или переиспользует профиль из семи маршрутов:

| Маршрут | Транспорт | Назначение |
|---|---|---|
| `xhttp-legacy` | xhttp | HAPP-совместимый XHTTP-фолбэк, `decryption=none`, без PQ |
| `xhttp-pq` | xhttp | XHTTP с post-quantum шифрованием `mlkem768x25519plus` |
| `tcp-mux` | tcp | TCP Reality без Vision-flow, отдельный совместимый фолбэк |

Managed HAPP-профиль использует schema version 3 и семь маршрутов. В обычную HAPP-выдачу попадает
шесть; PQ-маршрут остаётся доступен через raw/profile path.
| `grpc` | grpc | gRPC Reality; чувствителен к HTTP/2 и SNI |
| `tcp-vision` | tcp | TCP Reality с `xtls-rprx-vision` |
| `tcp-utls-firefox` | tcp | TCP Vision с отпечатком Firefox |
| `tcp-xudp` | tcp | TCP Vision + XUDP, узкий фолбэк для жёстких мобильных сетей |

В подписку HAPP уходит шесть маршрутов из семи: если в профиле есть `xhttp-legacy`, то PQ-XHTTP не
отдаётся как XHTTP-кандидат. В самом profile JSON при этом остаются все семь.

Базовый client fingerprint для новых и обновлённых профилей — `firefox`. Явно выбранные отпечатки,
отличные от устаревшего `chrome`, при обновлении сохраняются.

Порядок маршрутов в подписке стабилен, но это не рейтинг «лучший → худший». Работоспособность
транспорта зависит от клиента, версии Xray-core внутри него и конкретной сети.

### Режимы публикации подписки

| Режим | Что получается | Когда использовать |
|---|---|---|
| Public TLS по IP VPS | `https://<ip>/sub/<token>` | Быстрый старт без домена. Сертификаты Let's Encrypt на IP короткоживущие, renew обязателен |
| Public TLS по домену | `https://sub.example.com/sub/<token>` | Рекомендуется для постоянного использования |
| Local-only debug | `http://127.0.0.1:8080/sub/<token>` | Только проверка с самого VPS или через SSH-туннель. С телефона напрямую не работает |

---

## Быстрый старт

### Требования

Жёсткие требования: Bash, права root (или sudo), apt-основанная Debian/Ubuntu-подобная система и
работающий systemd. Матрица проверки — Debian 12/13 и Ubuntu 22.04/24.04.

- RAM от 512 MB, рекомендуется 1 GB и больше
- 1 ядро CPU, рекомендуется 2 и больше
- 1 GB свободного места на диске

Установщик тянет пакеты `ca-certificates curl wget jq qrencode uuid-runtime ufw unzip openssl socat`.

> Установщик проверяет apt/systemd, но не форсирует матрицу версий релизов. До включения UFW он
> определяет активный SSH-порт; если определить или безопасно открыть его нельзя, неактивный UFW
> остаётся выключенным. Перед установкой на важный VPS сделайте снапшот.

### Установка

Скачайте скрипт, просмотрите его и только затем запустите локальный файл от root:

```bash
curl -fsSLo ./xrayebator-install.sh \
  https://raw.githubusercontent.com/howdeploy/Xrayebator/main/install.sh
less ./xrayebator-install.sh
sudo bash ./xrayebator-install.sh
```

> Установщик не меняет системные TCP- и sysctl-настройки, но самостоятельно управляет UFW. Разберитесь с разделами
> [Переменные окружения](docs/ru/configuration.md#переменные-окружения-установщика) и
> [Firewall и параметры хоста](docs/ru/configuration.md#firewall-и-параметры-хоста) ДО запуска, особенно
> если SSH висит на нестандартном порту.

### КОМЬЮНИТИ ПРОЕКТЫ

- **[Xrayebator OpenWrt/Cudy companion](https://github.com/slavytich23/xrayebator-openwrt-cudy)** —
  независимый набор для запуска Xray-клиента на OpenWrt/Cudy: безопасное включение с автооткатом,
  fail-closed маршрутизация, контроль здоровья и памяти туннеля и опциональный резервный интернет
  Windows. Это не официальный компонент Xrayebator.

### Подписка HAPP за пять шагов

1. Запустите меню:

   ```bash
   sudo xrayebator
   ```

2. Выберите `6) Подписка HAPP`.
3. Выберите режим публикации: по IP VPS — быстро и без домена, по домену — для постоянного
   использования.
4. Xrayebator создаст профиль `happ`, поднимет инбаунды, выпустит сертификат и покажет URL и QR-код.
5. Импортируйте в HAPP именно subscription URL или QR, а не отдельную ссылку `vless://`.

### FAQ: маршруты зелёные, но Telegram или другие приложения не работают

> **Требуется HAPP 3.3.6 или новее.** Если у маршрутов Xrayebator зелёный ping, но подключения не
> работают, полностью закройте все старые процессы HAPP, запустите ровно один актуальный экземпляр и
> обновите подписку. Зелёный ping запускает отдельный временный Xray-core и не подтверждает здоровье
> основного TUN. На Linux команда `ss -lntp | grep ':10808'` должна показывать основной core HAPP.

Актуальная версия публикует и активирует управляемый профиль `xrayebator-default` с Global Proxy и
Cloudflare DoH. Geo-базы скачиваются через тот же защищённый URL подписки, а не напрямую с GitHub.
После обновления сервера принудительно обновите подписку и один раз переподключитесь: HAPP
перезапишет старый одноимённый профиль, а красное предупреждение исчезнет после загрузки обеих
geo-баз. Сторонние routing-профили всё ещё могут переопределять подписку — на время проверки
отключите их.

Для ручного контроля SNI, транспорта или отдельного маршрута используйте `1) Создать новый профиль`.

---

## Десктоп-GUI

Помимо терминального меню есть опциональное десктоп-приложение (Electron + React, `src/`), которое
управляет VPS по SSH. Оно не заменяет bash-движок — на сервере все операции по-прежнему выполняет
`xrayebator`, а GUI лишь гоняет те же команды через SSH.

```text
десктоп-приложение (Electron · React)
    │  SSH + документированный CLI
    ▼
xrayebator (bash)   ──►  /usr/local/etc/xray/
```

Язык интерфейса (Русский / English / 简体中文) переключается в шапке главного экрана и запоминается
в `localStorage`. Терминальное меню остаётся русским.

Что умеет GUI:

| Страница | Операции |
|---|---|
| Dashboard | Карточки серверов со статусом доступности и установки; пустой экран предлагает «Развернуть новый сервер» или «Подключить существующий»; переключатель языка |
| Добавить сервер | Развернуть VPS с явным выбором email: `quickstart --email` или `quickstart --without-email`; сохранить сервер и публичную подписку |
| Подключить существующий | Импорт распознанной установки Xrayebator по SSH (пароль или ключ) через read-only `xrayebator inspect --json`; частичные установки сохраняются с диагностикой без автоисправления |
| Ключи сервера | Обновить публичную подписку, скопировать URL, показать ссылки `vless://` и QR-коды |
| Настройки сервера | SSH по паролю или приватному ключу, прямой root или sudo; список/создание/удаление профилей, смена fingerprint, SNI и порта, обновление или удаление Xrayebator |

Выбранные приватный ключ и успешно использованный SSH-пароль сохраняются через `keytar` в системном keychain и повторно используются при следующих SSH-операциях и после перезапуска приложения; в карточке сервера хранятся только несекретные credential id и отображаемое имя ключа. Отдельный sudo-пароль и passphrase зашифрованного ключа не сохраняются и запрашиваются заново. Если системный keychain недоступен, plaintext-фолбека нет: секрет остаётся в памяти main process до завершения текущего сеанса, а GUI предупреждает, что после перезапуска его нужно ввести снова. Также локально сохраняются `subscription_url`, ссылки `vless://` и закреплённый SSH host-key fingerprint. Это bearer/client credentials: защищайте локальные данные и при утечке отзывайте подписку через терминальный workflow.

GUI предоставляет только подмножество терминального меню. Bypass, `probe-test`, revoke подписки,
`happ-setup`, каскад, self-steal и логи/статус сервисов остаются терминальными операциями. Полная
граница возможностей, security model и packaging описаны в [справочнике Electron GUI](docs/ru/desktop-gui.md).

Сборка и запуск в dev-режиме:

```bash
npm install
npm run dev          # Electron + Vite dev server
npm run build        # скомпилировать renderer и main process
```

Проверки Electron: `npm test` гоняет 14 unit-файлов из `tests/`; `npm run typecheck` проверяет
TypeScript, включая строгие onboarding-контракты из `tests/type-contracts/`, а `npm run build`
собирает приложение. На нативном Windows POSIX-тест
`tests/unit/shell-command.test.ts` может падать из-за отсутствия `/bin/sh`; источник истины — Linux CI.
См. [Тестирование](docs/ru/testing.md#десктоп-gui) и [справочник Electron GUI](docs/ru/desktop-gui.md).

---

## Документация

| Документ | О чём |
|---|---|
| [Настройка](docs/ru/configuration.md) | Переменные окружения, firewall и параметры хоста, главное меню, команды, bypass, каскад, self-steal, домен и DNS |
| [Архитектура](docs/ru/architecture.md) | Дерево репозитория и состояния на сервере, инбаунд против профиля, внутренности подписки |
| [Безопасность](docs/ru/security.md) | Сервисный аккаунт и права, защита подписки, доступ к VPS по SSH |
| [Частые проблемы](docs/ru/troubleshooting.md) | Подписка не обновляется, XHTTP не работает, клиент не подключается и другие кейсы |
| [Тесты](docs/ru/testing.md) | Локальные проверки, что покрывает `validation/`, ручные проверки на живом сервере |

Английская и китайская версии документации — в [`docs/`](docs/) и [`docs/zh-CN/`](docs/zh-CN/).

---

## Известные ограничения

- Установщик требует Bash, root/sudo, apt-основанную Debian/Ubuntu-подобную систему и systemd.
  Матрица проверки — Debian 12/13 и Ubuntu 22.04/24.04; версии релизов жёстко не форсируются.
- До включения UFW установщик определяет активный SSH-порт. Если определить или безопасно открыть его
  нельзя, неактивный UFW остаётся выключенным. После проверки добавляется фиксированный список
  сервисных TCP-портов, а собственные правила записываются в `.ufw_owned`.
- `xrayebator-update` автоматически удаляет обнаруженный `/opt/AdGuardHome` как deprecated: сначала
  возвращает Xray DNS на DoH, затем останавливает сервис и удаляет файлы. Если AdGuard Home на этом
  VPS нужен — не обновляйтесь без снапшота.
- Основное состояние Xray, профили, маркеры, ключи и manager-скрипты принадлежат root; аккаунт
  `xray` читает нужные файлы и пишет runtime-логи в `/var/log/xray`. Сгенерированные метаданные вроде
  `.server_country` и rollback-пути могут иметь отдельные права, поэтому при аудите проверяйте конкретный файл.
- Ядро Xray проверяется по SHA-256 обязательно, а geo-базы Loyalsoldier скачиваются без сверки
  контрольной суммы.
- `xrayebator-uninstall` останавливает и отключает `xray`, удаляет бинарь `/usr/local/bin/xray` и
  geo-базы из `/usr/local/share/xray`, вычищает `/usr/local/etc/xray` и `/var/log/xray`, бинари
  `xrayebator`, `xrayebator-update`, `xrayebator-uninstall` и `subhttp.sh`, юниты `xray.service`,
  `xray@.service`, `xray.service.d` и `xrayebator-sub.service`, nginx-vhost'ы с его именами, свои
  сертификаты certbot и правила UFW, а также системного пользователя `xray`. Очистка nginx основана
  на путях/именах, а не на отдельном ownership manifest. Глобальное состояние Certbot, пакет nginx,
  чужие сертификаты certbot и правила UFW не трогаются. Domain ACME webroot
  `/var/www/xrayebator-domain-acme` может остаться и потребовать ручной очистки.
- Маршрут `tcp-mux` сохраняется для совместимости, но это не mux-пресет.
- H2, WebSocket, SplitHTTP и подписки Clash/mihomo не поддерживаются.
- Ёмкость по пользователям ничем не ограничена в интерфейсе, но упирается в CPU, RAM, канал VPS,
  число маршрутов и лимиты провайдера.
- Установщик и project updater используют свои validation/restart/rollback paths, отличные от runtime
  транзакции `safe_restart_xray`; после lifecycle update проверяйте Xray, DNS и подписку.

---

## Обновление и удаление

```bash
sudo xrayebator update                  # только ядро Xray-core
sudo xrayebator update dev              # self-update менеджера из ветки, затем ядро
sudo xrayebator-update [branch]         # полный lifecycle updater; без аргумента — выбор ветки
sudo xrayebator-uninstall               # снять сервис и конфигурацию
```

Названия похожи, смысл разный:

| | `sudo xrayebator update <branch>` | `sudo xrayebator-update [branch]` |
|---|---|---|
| С чего начинается | Self-update установленного менеджера | Полный project lifecycle updater |
| Откуда берёт | Canonical raw-файл менеджера для branch | `update.sh` workflow выбранной ветки |
| Основной результат | Self-update менеджера и обновление Xray-core | Скрипты менеджера, данные, интеграция подписки и refresh сервиса |
| Выбор ветки | Ветка обязательна явно | Без аргумента показывает `.current_branch`, затем спрашивает; с аргументом выбирает его |

Текущая ветка показывается updater'ом и хранится в `/usr/local/etc/xray/.current_branch`, но запуск
`xrayebator-update` без аргумента всё равно открывает выбор. Electron GUI вызывает `xrayebator update <branch>`,
а не полный project updater. После lifecycle update дождитесь миграций и проверьте Xray, DNS и подписку,
прежде чем обновлять клиент.

Что именно остаётся в системе после `xrayebator-uninstall` — см.
[Известные ограничения](#известные-ограничения).

---

## Клиенты

Импортируйте в клиент subscription URL, а не отдельную ссылку `vless://`. Raw routes через
`3) Подключиться по профилю` нужны для диагностики.

| Клиент | Статус | Комментарий |
|---|---|---|
| HAPP | Рекомендуется | Целевой клиент. Поддерживает подписку по URL и QR и ссылки VLESS |
| v2rayNG | Частично | Получает base64-подписку, HAPP-метаданные не использует |
| v2rayN | Частично | Подписки с VLESS работают, HAPP-специфика не используется |
| Shadowrocket | Вручную | Годится для raw VLESS, не основной клиент для подписки |
| sing-box · Hiddify · NekoBox · mihomo | Не целевые | Не рассчитывайте на PQ-XHTTP и HAPP-роутинг |

- Android: [HAPP](https://www.happ.su/) · [v2rayNG](https://github.com/2dust/v2rayNG) · [NekoBox](https://github.com/MatsuriDayo/NekoBoxForAndroid)
- iOS: [HAPP](https://www.happ.su/) · [Shadowrocket](https://apps.apple.com/app/shadowrocket/id932747118) · [V2Box](https://apps.apple.com/app/v2box-v2ray-client/id6446814690)
- Windows: [Throne](https://github.com/throneproj/Throne) · [v2rayN](https://github.com/2dust/v2rayN) · [NekoRay](https://github.com/MatsuriDayo/nekoray)
- macOS: [Throne](https://github.com/throneproj/Throne) · [V2RayXS](https://github.com/tzmax/V2RayXS) · [Qv2ray](https://github.com/Qv2ray/Qv2ray)
- Linux: [Throne](https://github.com/throneproj/Throne) · [v2rayA](https://github.com/v2rayA/v2rayA) · [Qv2ray](https://github.com/Qv2ray/Qv2ray)

Документация клиентов: [HAPP subscription](https://www.happ.su/main/faq/adding-configuration-subscription) ·
[формат подписки v2rayN](https://github.com/2dust/v2rayN/wiki/Description-of-subscription)

---

## Лицензия

MIT. Подробности в файле [LICENSE](LICENSE).

## Благодарности

- [XTLS/Xray-core](https://github.com/XTLS/Xray-core) — за протокол.
- [HAPP](https://www.happ.su/) — за целевой клиент и формат подписки.
- [2dust/v2rayNG](https://github.com/2dust/v2rayNG) и [2dust/v2rayN](https://github.com/2dust/v2rayN) — за клиенты и формат подписок.
- [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat) — за расширенные geo-базы.
- [Umalanif/xray-server-setup](https://github.com/Umalanif/xray-server-setup) — за референс с uTLS и автоматизацию.
- [ServerTechnologies/simple-xray-core](https://github.com/ServerTechnologies/simple-xray-core) — за быстрое развёртывание.
- Сообществу — за поддержку и тестирование.

## Поддержка проекта

Звезда на GitHub — самый простой способ поддержать проект.

Донат:

```text
EVM     0x7acE4442b92f2769c24484c78A13024B139E1A5b
Solana  FS9RBrG5yXJty3WNWgkBkfai6BfNoYxGMFeH1LQEpRZr
TON     UQA56zsOv3zvU5x-p7iNNDL8jHh9dt7Q7WlY_gfbaj4ZhcyT
BTC     34EznmkBGpBu4dUnzoHL5GBnpg2Rq86v4H
```

---

<div align="center">
<strong>Сделано для свободного интернета</strong>
</div>
