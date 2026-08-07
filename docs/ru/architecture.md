# Архитектура

[← Назад к README](../../README.ru.md) · [English](../architecture.md) · [简体中文](../zh-CN/architecture.md)

Разделы: [Репозиторий](#репозиторий) · [Состояние на сервере](#состояние-на-сервере) ·
[Инбаунд против профиля](#инбаунд-против-профиля) ·
[Как работает подписка](#как-работает-подписка)

---

## Репозиторий

```text
Xrayebator/
├── xrayebator            # основное приложение: меню, профили, инбаунды, routing, миграции
├── install.sh            # установка ядра, сервиса, прав, geo-баз, лайфсайкл-команд
├── update.sh             # обновление самого Xrayebator из выбранной ветки
├── uninstall.sh          # снятие сервиса и конфигурации
├── validation/           # статические и локальные regression-тесты
├── docs/                 # документация: ru, en, zh-CN
├── sni_list.txt          # набор SNI-кандидатов
├── ascii_art.txt         # заголовок терминального интерфейса
├── CLAUDE.md             # рабочие правила и политики проекта
└── LICENSE
```

Основная логика управления живёт в одном файле `xrayebator`. Скрипты `install.sh`, `update.sh` и
`uninstall.sh` отвечают за жизненный цикл. Генерируемые `subhttp.sh`, конфиг nginx и systemd-юнит
образуют путь HAPP-подписки.

## Состояние на сервере

```text
/usr/local/bin/
├── xray                          # ядро
├── xrayebator                    # менеджер
├── subhttp.sh                       # backend подписки
├── xrayebator-update
└── xrayebator-uninstall

/usr/local/etc/xray/
├── config.json                   # инбаунды, outbounds, routing, DNS
├── profiles/<name>.json          # метаданные профиля: routes, sub_token, SNI, fingerprint
├── upstreams/cascade.json        # параметры upstream каскада
├── backups/config_<timestamp>_<op>.json          # бэкапы конфига перед каждой правкой
├── .private_key / .public_key    # ключи Reality, генерируются один раз при установке
├── .vless_decryption             # PQ-ключи для xhttp-pq
├── .vless_encryption
├── .subscription_mode            # режим публикации подписки
├── .subscription_domain          # домен подписки, DNS-запись сама его не меняет
├── .subscription_port            # 443 или 8443
├── .happ_defaults.env            # настройки HAPP, включая имя сервера в клиенте
├── .current_branch               # ветка, из которой обновляется Xrayebator
└── .xhttp_migrated, ...          # marker-файлы выполненных миграций

/usr/local/share/xray/            # geoip.dat и geosite.dat
/etc/systemd/system/xray.service.d/security.conf
/etc/systemd/system/xrayebator-sub.service
/etc/nginx/sites-available/xrayebator-sub
/etc/nginx/sites-available/xrayebator-selfsteal
```

## Инбаунд против профиля

Инбаунд — блок в `config.json`, привязанный к порту. Профиль — JSON-файл с метаданными для
пользователя. Несколько профилей могут жить на одном инбаунде, то есть на одном порту.

Из этого следует главное: SNI и fingerprint инбаунда общие для всех профилей на этом порту. Смена
SNI на порту затрагивает все профили, которые на нём висят.

## Как работает подписка

`xrayebator-sub.service` слушает `127.0.0.1:8080`, наружу его публикует nginx по HTTPS. Endpoint:

```text
https://<домен-или-ip>/sub/<32-hex-token>
```

Токен лежит в profile JSON как `sub_token`. При компрометации используйте `Revoke` в меню
подписки — токен меняется, старый URL умирает.

Название подписки в клиенте задаётся отдельно от имени профиля: `Подписка HAPP` → `Настройки HAPP` →
`HAPP_SERVER_NAME`. Так несколько VPS можно по-разному подписать в списке клиента, даже если
внутренний профиль на каждом называется `happ`. При пустом значении используется имя профиля.

Поведение по клиентам:

- HAPP получает plain-text список `vless://`, HAPP-заголовки и опциональный `happ://routing/onadd/...`;
- `v2rayNG` и `v2rayN` получают классический base64-body без HAPP-метаданных;
- профили без живого инбаунда не показываются в меню подписки, а их старые URL возвращают `410 Gone`.

## Правки конфига

Любое изменение проходит один и тот же путь:

```text
backup_config ────► /usr/local/etc/xray/backups/config_<timestamp>_<op>.json
safe_jq_write ────► временный файл в целевом каталоге → валидация → атомарный rename
safe_restart_xray ► xray run -test -config → systemctl restart
                    при ошибке — rollback из бэкапа, Xray работает на старом конфиге
```

Миграции выполняются один раз и отмечаются marker-файлами в `/usr/local/etc/xray/`. Схема одна:
маркер отсутствует → backup → правка → рестарт → создать маркер.
