# Архитектура

[← Назад к README](../../README.ru.md) · [English](../architecture.md) · [简体中文](../zh-CN/architecture.md)

Разделы: [Репозиторий](#репозиторий) · [Состояние на сервере](#состояние-на-сервере) ·
[Инбаунд против профиля](#инбаунд-против-профиля) · [Как работает подписка](#как-работает-подписка) ·
[Пути обновления](#пути-обновления) · [Десктоп-GUI](#десктоп-gui)

---

## Репозиторий

```text
Xrayebator/
├── xrayebator                  # Bash-приложение: меню, профили, инбаунды, routing, миграции
├── install.sh                  # первичная установка, сервис, зависимости и права
├── update.sh                   # полный lifecycle update проекта
├── uninstall.sh                # удаление сервиса и состояния
├── src/                        # активный Electron + React + TypeScript десктоп-GUI
│   ├── main/                   # SSH, деплой, профили, подписка и менеджеры сервера
│   ├── preload/                # contextBridge, доступный renderer
│   ├── renderer/               # Dashboard, AddServer, ServerKeys, ServerSettings
│   └── shared/                 # общие TypeScript-типы и VLESS-помощники
├── tests/                      # Electron/Vitest unit-тесты
├── resources/                  # ресурсы сборки Electron
│   └── icons/                  # иконки приложения
├── electron-builder.yml        # конфигурация packaging и extraResources
├── electron.vite.config.ts     # конфигурация сборки main, preload и renderer
├── package.json                # скрипты и зависимости Electron
├── gui-legacy/                 # архивный PySide6 GUI и его тесты
├── validation/                 # Bash-статические и локальные регрессионные тесты
├── docs/                       # техническая документация на русском, английском и китайском
├── sni_list.txt                # SNI-кандидаты, используемые Bash-приложением
├── ascii_art.txt               # заголовок терминального интерфейса
└── LICENSE
```

Вся серверная логика управления живёт в `xrayebator`. `install.sh`, `update.sh` и `uninstall.sh`
отвечают за установку и жизненный цикл. Генерируемые `subhttp.sh`, конфиг nginx и systemd-юнит
образуют путь HAPP-подписки. Активное десктоп-приложение в `src/` — это SSH-фронтенд к
Bash-управлению, а не вторая реализация сервера.

## Состояние на сервере

```text
/usr/local/bin/
├── xray                          # бинарник Xray-core
├── xrayebator                    # точка входа менеджера
├── subhttp.sh                    # сгенерированный HTTP-handler подписки
├── xrayebator-update             # полный project updater
└── xrayebator-uninstall          # точка входа удаления

/usr/local/etc/xray/
├── config.json                   # инбаунды, outbounds, routing и DNS
├── profiles/<name>.json          # метаданные профиля и токен подписки
├── upstreams/cascade.json        # параметры upstream каскада
├── backups/                      # бэкапы конфига перед runtime-мутациями
├── .private_key / .public_key    # ключи Reality
├── .vless_decryption / .vless_encryption
├── .subscription_*               # маркеры режима, адреса, домена и порта подписки
├── .happ_defaults.env            # настройки отображения и routing HAPP
├── .current_branch               # ветка менеджера для lifecycle-обновлений
└── маркеры миграций              # записи выполненных одноразовых миграций

/usr/local/share/xray/             # geoip.dat и geosite.dat
/var/log/xray/                     # каталог логов, куда пишет сервис Xray
/etc/systemd/system/xray.service.d/security.conf
/etc/systemd/system/xrayebator-sub.service
/etc/nginx/sites-available/xrayebator-sub
```

`/usr/local/etc/xray/` — состояние менеджера, принадлежащее root. Xray работает от непривилегированного
аккаунта `xray` и читает нужные ему файлы; он не владеет и не пишет состояние менеджера.
`/var/log/xray/` — отдельный каталог для логов времени выполнения. Принадлежащие root скрипты и
маркеры не могут быть подменены сервисным аккаунтом.

## Инбаунд против профиля

Инбаунд — блок в `config.json` на уровне порта. Профиль — JSON-файл, содержащий один или несколько
маршрутов. Несколько профилей могут делить один инбаунд и порт.

Порт и SNI — свойства общего инбаунда. Изменение SNI или порта может изменить все профили,
использующие этот инбаунд; используйте отдельные порты, когда нужны независимые значения SNI.
Сгенерированный profile JSON синхронизируется после изменения SNI или порта на уровне инбаунда.

Fingerprint Reality — клиентское значение, хранящееся на профиль или маршрут. Его изменение меняет
ссылку клиента для выбранного маршрута, не редактирует инбаунд и не требует перезапуска Xray.
Для XHTTP SNI маршрута также отражается в transport host, чтобы оба значения оставались согласованными.

## Как работает подписка

`xrayebator-sub.service` слушает `127.0.0.1:8080`; nginx публикует сгенерированный
`/usr/local/bin/subhttp.sh` handler по HTTPS. Handler читает состояние менеджера и метаданные
профиля и возвращает subscription body для конкретного клиента.

База URL строится из сохранённых маркеров подписки:

```text
https://<domain>/sub/<32-hex-token>       # public TLS на 443
https://<domain>:8443/sub/<32-hex-token>  # public TLS на другом порту
http://127.0.0.1:8080/sub/<token>         # local-only запасной
```

Интерактивная настройка HAPP может выбрать публичный порт, а `_subscription_base_url` сохраняет этот
выбор. Нон-интерактивные IP-TLS пути `quickstart --email <address>` и `quickstart --without-email`
создают nginx, сертификат и маркеры на `8443`, затем возвращают JSON с `subscription_url` для endpoint.
Без email Certbot регистрирует ACME-аккаунт без контактного адреса: уведомления о продлении и восстановление
по email недоступны. Токен хранится в профиле как `sub_token`; revoke меняет его и аннулирует старый URL.

Новый стандартный managed HAPP-профиль — schema-v3 профиль из семи маршрутов, включая `xhttp-legacy`
и post-quantum XHTTP route. Публикуемый список HAPP содержит шесть VLESS-маршрутов, потому что
PQ-маршрут остаётся доступен через raw/profile path. Helper может переиспользовать старый профиль с
минимум семью живыми маршрутами, поэтому проверяйте фактические labels/schema; миграции не добавляют
недостающие маршруты в существующий профиль. Профиль без живых маршрутов возвращает `410 Gone`, а
частично устаревший multi-route может вернуть оставшиеся маршруты и `200`.

Handler также отдаёт защищённые токеном `geoip.dat` и `geosite.dat`, необходимые для управляемого
HAPP routing profile. HAPP получает routing metadata, а v2rayNG и v2rayN — совместимое VLESS-тело
без HAPP-only метаданных.

## Пути обновления

Похожие названия команд имеют разные обязанности:

| Команда | Обязанность |
|---|---|
| `sudo xrayebator update` | Обновляет только Xray-core из XTLS release channel, валидирует и перезапускает ядро через core-update path |
| `sudo xrayebator update <branch>` | Загружает менеджер из canonical репозитория (ветка branch), продолжает свежим скриптом и обновляет Xray-core |
| `sudo xrayebator-update [branch]` | Запускает `update.sh` workflow: скрипты менеджера, данные, интеграцию подписки и refresh сервиса, как реализовано в этом скрипте |

Без аргумента `xrayebator-update` показывает интерактивный выбор ветки; текущая ветка из
`.current_branch` отображается, но не выбирается автоматически. Electron GUI использует средний путь
(`xrayebator update <branch>`) для обновления в Server Settings; он не использует полный терминальный
update workflow.

## Правки конфига

Для runtime-мутаций, которыми владеет `xrayebator`, нормальная транзакция выглядит так:

```text
backup_config ────► /usr/local/etc/xray/backups/config_<timestamp>_<op>.json
safe_jq_write ────► временный файл → валидация → атомарный rename
safe_restart_xray ► xray run -test -config → systemctl restart
                     при ошибке — rollback из бэкапа, Xray работает на старом конфиге
```

Миграции выполняются однократно и отмечаются marker-файлами в `/usr/local/etc/xray/`. Обычная
последовательность: маркер отсутствует → backup → правка → валидированный рестарт, если конфиг
изменился → создать маркер. Установщик и lifecycle updater имеют собственные последовательности
валидации и рестарта; не каждая установка или рестарт обновления является вызовом `safe_restart_xray`.

## Десктоп-GUI

Активное десктоп-приложение (`src/`) — контролируемый CLI-фронтенд поверх SSH. Оно может выполнять
деплой через `quickstart`, обновлять и показывать сохранённую подписку, управлять профилями и
вызывать операции SNI, fingerprint, порта, обновления и удаления. Оно намеренно предоставляет
только подмножество интерактивного Bash-меню и никогда не редактирует `config.json` напрямую.

См. [Electron Desktop GUI](desktop-gui.md) для полной границы возможностей, модели безопасности SSH,
карты команд и деталей сборки и тестов.