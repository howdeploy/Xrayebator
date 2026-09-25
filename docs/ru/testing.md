# Тесты

[← Назад к README](../../README.ru.md) · [English](../testing.md) · [简体中文](../zh-CN/testing.md)

---

## Локальная проверка чекаута

```bash
bash -n xrayebator install.sh update.sh uninstall.sh
for test_file in validation/*.sh; do bash "$test_file" || exit; done
```

Две команды — минимальный гейт локальной проверки. `shellcheck` дополнительно рекомендуется, но не является
обязательным для CI (см. раздел ниже).

## Что покрывают тесты

В `validation/` лежат 26 статических и локальных регрессионных тестов:

| Тест | Что проверяет |
|---|---|
| `test-transaction-safety.sh` | Транзакционную безопасность операций с конфигом |
| `test-project-update-rollback.sh` | Откат неудачного обновления проекта |
| `test-xhttp-route-path-repair.sh` | Починку путей XHTTP-маршрутов при миграции |
| `test-multiroute-argument-preservation.sh` | Сохранение transport-аргументов multiroute-профиля |
| `test-happ-subscription-static.sh` | Обработчик HAPP-подписки |
| `test-subscription-server-name.sh` | Имя сервера подписки в клиенте |
| `test-fingerprint-subscription-sync.sh` | Синхронность маршрутов и подписки при смене fingerprint |
| `test-dead-stealth-route-pruning.sh` | Отсечение мёртвых stealth-маршрутов |
| `test-cascade-routing.sh` | Cascade routing |
| `test-cascade-upstream-import.sh` | Импорт upstream каскада из ссылки |
| `test-update-xray-core-sync.sh` | Синхронность обновления Xray-core |
| `test-vless-url-generation.sh` | Генерацию ссылок `vless://` |
| `test-installer-network-fallbacks.sh` | Сетевые fallback'и установщика |
| `test-bbr-removal-migration.sh` | Безопасное удаление удалённого BBR/TCP tuning на всех путях |
| `test-legacy-udp443-migration.sh` | Одноразовое удаление legacy правила блокировки UDP/443 |
| `test-main-menu-numbering.sh` | Нумерацию пунктов меню и их соответствие обработчикам |
| `test-main-readiness-regressions.sh` | Регрессии readyness после аудита: certbot-manifest, UFW manifest, nginx rollback, привилегии, SSH-порт |
| `test-sni-change-cli.sh` | CLI `sni-change`: JSON stdout, Reality, XHTTP host, синхронизацию, rollback |
| `test-port-change-cli.sh` | CLI `port-change`: сценарии unit/shared/move, неверный порт, multi-route `--route` |
| `test-bypass-cli.sh` | CLI `bypass`: JSON stdout, routing-правила, add с проверкой SNI |
| `test-apt-lock-race.sh` | Гонка apt-lock: `DPkg::Lock::Timeout` при установках, учёт воркера `unattended-upgrade` и бюджет 12 минут в quickstart |
| `test-quickstart-email-and-inspect.sh` | Явный email-режим `quickstart` (`--without-email` без фиктивного адреса) и read-only инварианты `inspect --json` |
| `test-quickstart-migration-parity.sh` | `quickstart` гоняет те же критичные миграции, что и `main_menu` |
| `test-quickstart-subscription-port.sh` | `quickstart` использует canonical helper базы подписки и не возвращается к несвязанному hardcode URL |
| `test-audit-functional.sh` | Функциональные regression-проверки аудита HowDeploy (P0/P1) |
| `test-audit-privilege-regressions.sh` | Regression границ привилегий |

> Статические тесты не заменяют проверку на disposable VPS: создание и удаление профиля, валидацию
> конфига, рестарт сервисов, rollback и реальное подключение клиента.

## Ручные проверки на живом сервере

```bash
sudo xrayebator probe-test                                    # доступность SNI с VPS
sudo /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
sudo systemctl status xray --no-pager -l
sudo systemctl status xrayebator-sub --no-pager -l
curl -sS -i http://127.0.0.1:8080/sub/                        # ожидается 404
jq -r '.routes[] | [.label,.transport,.port,(.pq_enabled // false)] | @tsv' \
  /usr/local/etc/xray/profiles/<profile>.json
```

Если UFW уже активен, сравните numbered rules до и после операции: установка не должна повторно
включать firewall или менять политику по умолчанию.

## Десктоп-GUI

У GUI (`src/`) свои Vitest unit-тесты в `tests/`.

```bash
npm run typecheck     # проверка TypeScript: main, preload, renderer, shared
npm test              # Vitest unit-тесты
```

Файлы тестов:

| Тест | Что проверяет |
|---|---|
| `tests/unit/subscription.test.ts` | Извлечение ссылки подписки и ключей профиля |
| `tests/unit/probe-ports.test.ts` | Зондажи доступности для статусной точки Dashboard |
| `tests/unit/extractJson.test.ts` | Разбор JSON из вывода `xrayebator` |
| `tests/unit/countryFlag.test.ts` | Флаг страны для карточек серверов |
| `tests/unit/vless.test.ts` | Парсинг `vless://` URL |
| `tests/unit/shell-command.test.ts` | POSIX-безопасное quoting аргументов shell |
| `tests/unit/ssh-access.test.ts` | Валидация параметров SSH-доступа и порядок разрешения ключа из keychain |
| `tests/unit/ssh-client.test.ts` | SSH-соединение и host-key verification |
| `tests/unit/ssh-keychain.test.ts` | Сохранение/чтение/удаление ключей в системном keychain с guard'ами размера (mock keytar) |
| `tests/unit/server-manager.test.ts` | Валидация безопасных веток для обновления |
| `tests/unit/server-store.test.ts` | Идемпотентный импорт upsert по host+port, подсчёт ссылок на credential |
| `tests/unit/server-inspector.test.ts` | Нормализация диагностики: публичная vs local-only/unreachable подписка, partial- и refuse-import состояния |
| `tests/unit/deployer.test.ts` | Аргументы quickstart: режимы provided/without email без фиктивного адреса |
| `tests/unit/ui-contracts.test.ts` | Готовность deployment и формирование payload при выборе email-режима |

`npm run typecheck` дополнительно проверяет `tsconfig.contracts.json` — он компилирует строгие onboarding-контракты из `tests/type-contracts/` (обязательный `emailMode`, keychain-ссылка в выборщике ключа, открытый import API); Vitest-транспиляция такие регрессии типов не ловит.

Примечание: `tests/unit/shell-command.test.ts` намеренно вызывает `/bin/sh` и завершается ошибкой
(`status=null`) на Windows, где POSIX `/bin/sh` отсутствует. Полный suite следует запускать на Linux
(включая CI Ubuntu в `release.yml`), где все тесты проходят.

## CI workflow

Три независимых workflow:

- **ci-linux.yml** — Bash validation: `bash -n` всех скриптов + все 26 `validation/test-*.sh` на
  ubuntu-24.04. Запускается на push в `main`, `dev`, `experimental` и на pull request.
- **release.yml** — Electron сборка (Windows/macOS/Linux). Запускается только на теги `v*` и manual
  dispatch. Сначала `preflight`: проверяет наличие текста релиза `docs/releases/<tag>.en.md` и
  способность секрета `AP3X0` создавать релизы (пробным черновиком, который сразу удаляется), — чтобы
  неприятность всплыла за секунды, а не после трёх сборок. Обе проверки предупреждающие: релиз выйдет
  в любом случае. Затем `npm run typecheck`, `npm test`, `npm run build` на ubuntu и
  `electron-builder --publish never` на всех трёх платформах. Если `preflight` подтвердил, что
  `AP3X0` может публиковать, релиз выходит от владельца этого токена; иначе — от
  `github-actions[bot]` через встроенный `GITHUB_TOKEN`: автор релиза фиксируется при создании и
  назад не переключается.
- **gui-release.yml** — legacy PySide6 GUI: ruff + pytest + wheel build. Запускается на PR и теги
  `gui-v*`.