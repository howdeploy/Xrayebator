# Расширенное добавление серверов — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** В локальной ветке `dev`, уже синхронизированной с `main`, добавить необязательный email при новом развёртывании, отдельный read-only импорт установленного Xrayebator и безопасное повторное использование SSH-ключей через системный keychain.

**Architecture:** Разделить задачу на четыре границы: pure helpers/contracts, keychain-backed credential resolution, server-side CLI/inspection, и Electron IPC/renderer. Существующие `SshClient`, host-key pinning, Bash-операции профилей и subscription fetch остаются источниками истины; новый импорт выполняет только read-only диагностику и делает idempotent upsert карточки по `host + port`.

**Tech Stack:** Bash + jq + systemd CLI; Electron main/preload; React 19 + TypeScript; `ssh2`; `electron-store`; `keytar`; Vitest; CSS Modules; i18next (`ru`, `en`, `zh`).

## Global Constraints

- Работа ведётся только в локальной ветке `dev`; перед началом она уже fast-forward-синхронизирована с актуальной `main` на `dbedd4c`.
- Push в `origin/dev` или `upstream/dev` не выполнять без отдельного подтверждения пользователя.
- Импорт поддерживает только распознаваемую установку Xrayebator; произвольный Xray не импортировать автоматически.
- Импорт не запускает `quickstart`, `happ-setup`, установщик, обновление, миграции, restart, firewall или исправление конфигурации.
- Email выбирается явно: режим `provided` вызывает `quickstart --email`, режим `without` вызывает `quickstart --without-email`; фиктивный email не подставлять.
- Приватный ключ хранится только в системном keychain через `keytar`; не записывать байты ключа в `electron-store`, renderer state, URL, shell command или логи.
- Passphrase и SSH/sudo-пароли не сохранять; passphrase вводится заново, когда ключ этого требует.
- Существующий host-key TOFU pinning не ослаблять: fingerprint закреплять только после успешной аутентификации, mismatch блокирует команды.
- При недоступном keychain не использовать plaintext-фолбек.
- Удалённые команды строить через существующий `shellCommand`/`shellQuote`; JSON stdout server-side CLI не загрязнять статусами.
- Все jq-изменения серверного `xrayebator` выполнять через существующие safe-write/rollback правила; read-only inspect не должен менять файлы.
- Bash-комментарии и сообщения остаются на русском; identifiers и TypeScript API — на английском; UI переводится во все три locale-файла.
- Сохранять текущий legacy `privateKeyPath` как временный migration fallback; не удалять пользовательский файл ключа автоматически.
- Изменения коммитить логическими блоками; после каждого блока запускать его тесты и делать локальный commit с причиной изменения.

---

## Карта файлов и границы

### Создать

- `src/main/core/ssh-keychain.ts` — минимальный main-process adapter над `keytar`, base64-кодирование, очистка Buffer и ошибки хранения.
- `src/main/core/server-inspector.ts` — SSH read-only инспектор, parser/normalizer inspection JSON и проверка публичной подписки.
- `src/renderer/src/pages/ImportServer.tsx` — UI мастера подключения существующей установки.
- `src/renderer/src/pages/ImportServer.module.css` — стили мастера импорта.
- `tests/unit/ssh-keychain.test.ts` — mock-тесты keychain adapter.
- `tests/unit/server-inspector.test.ts` — тесты parser/normalizer и статусов диагностики.
- `validation/test-quickstart-email-and-inspect.sh` — статические Bash-регрессии email-флагов и read-only inspect.

### Изменить

- `src/shared/types.ts` — email mode, keychain reference, diagnostics, import/deploy IPC contracts.
- `src/main/core/servers.ts` — persisted credential id, diagnostic state, same-endpoint upsert и безопасное удаление ссылок.
- `src/main/core/ssh-access.ts` — resolver с keychain-loaded Buffer и сохранением legacy path guard.
- `src/main/core/deployer.ts` — optional email validation/command arguments.
- `src/main/ipc-handlers.ts` — async credentials, keychain selection/import/remove, diagnostics/import handlers.
- `src/preload/index.ts` — expose typed methods for new IPC contracts.
- `src/renderer/src/App.tsx` — views `choice`/`import` и navigation.
- `src/renderer/src/pages/Dashboard.tsx`/`.module.css` — две onboarding-карточки и выбор при непустом Dashboard.
- `src/renderer/src/pages/AddServer.tsx`/`.module.css` — email mode selector и optional payload.
- `src/renderer/src/components/SshAccessForm.tsx`/`.module.css` — keychain reference, сохранённое имя ключа и import-only mode.
- `src/renderer/src/pages/ServerSettings.tsx` — использование сохранённого keychain credentials без повторного выбора и диагностика.
- `src/renderer/src/i18n/ru.json`, `en.json`, `zh.json` — все новые UI/error strings.
- `xrayebator` — `quickstart --without-email`, `inspect --json`, JSON schema и dispatch/help.
- `docs/desktop-gui.md`, `docs/ru/desktop-gui.md`, `docs/zh-CN/desktop-gui.md` — новые сценарии и protocol.
- `docs/security.md`, `docs/ru/security.md`, `docs/zh-CN/security.md` — keychain/passphrase/security boundary.

### Только проверить

- `package.json`/`package-lock.json` — `keytar` уже существует, новую зависимость не добавлять.
- `src/main/core/ssh-client.ts` — сохранить Buffer wipe в `close()` и host-key behavior; изменить только при необходимости для тестируемого resolver.
- `tests/unit/ssh-access.test.ts`, `ssh-client.test.ts`, `server-manager.test.ts` — расширить, не ломая существующие сценарии.

---

## Task 1: Контракты email, diagnostics и keychain reference

**Files:**
- Modify: `src/shared/types.ts`
- Test: `tests/unit/server-store.test.ts` (создать)

**Interfaces:**
- Produces `EmailMode = 'provided' | 'without'`.
- Produces `PrivateKeyReference { credentialId: string; name: string }`.
- Produces `ServerDiagnostics` and `ServerSetupStatus`.
- Extends `Server` with optional `setupStatus`, `diagnostics`, `privateKeyName`, `privateKeyCredentialId`.
- Extends `SshAccessInput` with optional `privateKeyCredentialId` while retaining `privateKeyPath` for legacy migration.
- Changes `DeployStartPayload` to `{ host, port, emailMode, email?: string, access }`.
- Adds `ImportServerPayload`, `ImportResult`, `InspectionSnapshot`.

- [ ] **Step 1: Write failing type-level/store test**

Добавить тестовые fixture-объекты, которые компилируются только при наличии новых полей:

```ts
const partialDiagnostics: ServerDiagnostics = {
  manager: 'detected',
  xray: 'running',
  profiles: 'available',
  subscription: 'unreachable',
  inspectedAt: '2026-09-23T00:00:00.000Z'
}

const importPayload: ImportServerPayload = {
  host: '203.0.113.10',
  port: 22,
  access: {
    username: 'root',
    authMethod: 'privateKey',
    privateKeyCredentialId: 'cred-1',
    privilegeMode: 'root'
  }
}

expect(importPayload.access.authMethod).toBe('privateKey')
expect(partialDiagnostics.subscription).toBe('unreachable')
```

- [ ] **Step 2: Run the focused test to verify missing contracts fail**

Run: `npx vitest run tests/unit/server-store.test.ts`

Expected: FAIL because `ServerDiagnostics`/`ImportServerPayload`/`privateKeyCredentialId` do not exist.

- [ ] **Step 3: Add the shared contracts**

В `src/shared/types.ts` добавить точные union types:

```ts
export type EmailMode = 'provided' | 'without'
export type ServerSetupStatus = 'ready' | 'partial' | 'unknown'
export type DiagnosticState = 'detected' | 'missing' | 'invalid' | 'unknown'
export type XrayState = 'running' | 'stopped' | 'missing' | 'unknown'
export type ProfilesState = 'available' | 'empty' | 'missing' | 'unknown'
export type SubscriptionState = 'public' | 'localOnly' | 'missing' | 'unreachable' | 'unknown'

export interface PrivateKeyReference {
  credentialId: string
  name: string
}

export interface ServerDiagnostics {
  manager: DiagnosticState
  xray: XrayState
  profiles: ProfilesState
  subscription: SubscriptionState
  inspectedAt: string
}
```

Добавить `privateKeyCredentialId?: string | null`, `privateKeyName?: string | null`, `setupStatus?: ServerSetupStatus`, `diagnostics?: ServerDiagnostics | null` в `Server`; `privateKeyCredentialId?: string` в `SshAccessInput`; заменить deploy email на `emailMode` и optional `email`; добавить import/inspection interfaces и `ElectronAPI.ssh.selectPrivateKey` новый результат.

- [ ] **Step 4: Run focused tests and typecheck**

Run: `npx vitest run tests/unit/server-store.test.ts` и `npm run typecheck`

Expected: PASS for the fixture test; typecheck may still report missing implementations only if API signatures are changed prematurely. Fix only contract references in this task.

- [ ] **Step 5: Commit**

```text
git add src/shared/types.ts tests/unit/server-store.test.ts
git commit -m "feat: описать контракты onboarding и диагностики"
```

---

## Task 2: Системный keychain adapter

**Files:**
- Create: `src/main/core/ssh-keychain.ts`
- Create: `tests/unit/ssh-keychain.test.ts`
- Modify: `src/main/core/ssh-access.ts` only if shared constants are extracted

**Interfaces:**
- Produces `SshKeychain` with `save(credentialId: string, key: Buffer): Promise<void>`, `load(credentialId: string): Promise<Buffer | null>`, `remove(credentialId: string): Promise<void>`.
- Produces `createSshKeychain(keytarModule = keytar): SshKeychain` for dependency injection in tests.
- Uses service name `com.xrayebator.gui.ssh-key` and base64 account payload; no plaintext key in electron-store.

- [ ] **Step 1: Write failing mock tests**

```ts
it('сохраняет base64 в keytar и возвращает копию Buffer', async () => {
  const keytar = { setPassword: vi.fn(), getPassword: vi.fn().mockResolvedValue(Buffer.from('key').toString('base64')), deletePassword: vi.fn() }
  const keychain = createSshKeychain(keytar)
  await keychain.save('cred-1', Buffer.from('private-key'))
  expect(keytar.setPassword).toHaveBeenCalledWith(
    'com.xrayebator.gui.ssh-key',
    'cred-1',
    Buffer.from('private-key').toString('base64')
  )
  const loaded = await keychain.load('cred-1')
  expect(loaded?.toString()).toBe('key')
  expect(loaded).not.toBe(Buffer.from('key'))
})

it('не сохраняет ключ при размере выше лимита и пробрасывает ошибку keychain', async () => {
  const keytar = { setPassword: vi.fn().mockRejectedValue(new Error('keychain unavailable')) }
  await expect(createSshKeychain(keytar).save('cred-1', Buffer.alloc(1024 * 1024 + 1))).rejects.toThrow('слишком большой')
  await expect(createSshKeychain(keytar).save('cred-1', Buffer.from('key'))).rejects.toThrow('keychain unavailable')
})

it('удаляет только указанную запись', async () => {
  const keytar = { setPassword: vi.fn(), getPassword: vi.fn(), deletePassword: vi.fn().mockResolvedValue(true) }
  await createSshKeychain(keytar).remove('cred-1')
  expect(keytar.deletePassword).toHaveBeenCalledWith('com.xrayebator.gui.ssh-key', 'cred-1')
})
```

- [ ] **Step 2: Run test to confirm failure**

Run: `npx vitest run tests/unit/ssh-keychain.test.ts`

Expected: FAIL because `ssh-keychain.ts` is absent.

- [ ] **Step 3: Implement adapter**

```ts
import keytar from 'keytar'

const SERVICE = 'com.xrayebator.gui.ssh-key'
const MAX_PRIVATE_KEY_BYTES = 1024 * 1024

type KeytarLike = Pick<typeof keytar, 'setPassword' | 'getPassword' | 'deletePassword'>

export interface SshKeychain {
  save(credentialId: string, key: Buffer): Promise<void>
  load(credentialId: string): Promise<Buffer | null>
  remove(credentialId: string): Promise<void>
}

export function createSshKeychain(api: KeytarLike = keytar): SshKeychain {
  const validateId = (id: string): void => {
    if (!/^[A-Za-z0-9_-]{8,128}$/.test(id)) throw new Error('Некорректный идентификатор SSH-ключа')
  }
  return {
    async save(id, key) {
      validateId(id)
      if (key.length < 1 || key.length > MAX_PRIVATE_KEY_BYTES) throw new Error('Приватный SSH-ключ слишком большой')
      await api.setPassword(SERVICE, id, key.toString('base64'))
    },
    async load(id) {
      validateId(id)
      const encoded = await api.getPassword(SERVICE, id)
      if (!encoded) return null
      const key = Buffer.from(encoded, 'base64')
      if (key.length < 1 || key.length > MAX_PRIVATE_KEY_BYTES) {
        key.fill(0)
        throw new Error('В keychain записан некорректный SSH-ключ')
      }
      return key
    },
    async remove(id) {
      validateId(id)
      await api.deletePassword(SERVICE, id)
    }
  }
}
```

В production-объекте keychain id генерировать `randomUUID().replace(/-/g, '')`, чтобы пройти валидацию. Не логировать id или key contents.

- [ ] **Step 4: Run focused tests and build**

Run: `npx vitest run tests/unit/ssh-keychain.test.ts` и `npm run typecheck`

Expected: PASS; native `keytar` не вызывается в unit tests благодаря injection.

- [ ] **Step 5: Commit**

```text
git add src/main/core/ssh-keychain.ts tests/unit/ssh-keychain.test.ts
git commit -m "feat: хранить SSH-ключи в системном keychain"
```

---

## Task 3: Store migration, key references and idempotent import upsert

**Files:**
- Modify: `src/main/core/servers.ts`
- Modify: `tests/unit/server-store.test.ts`

**Interfaces:**
- `ServerConnectionMetadata` gains `privateKeyCredentialId?: string | null` and `privateKeyName?: string | null`.
- `ServerStore` gains `findByEndpoint(host, port)`, `upsertImported(input, connection): StoredServer`, `countCredentialReferences(credentialId, exceptId?)`, `clearCredentialReference(id)`.
- `remove` remains synchronous for store mutation; IPC performs keychain cleanup after checking reference count.

- [ ] **Step 1: Add failing store tests**

```ts
it('upsert импортирует один endpoint без дубликата', () => {
  const store = createTestServerStore()
  const first = store.upsertImported({ host: 'server.example', port: 22, name: 'server.example', diagnostics: partialDiagnostics }, connection)
  const second = store.upsertImported({ host: 'server.example', port: 22, name: 'renamed', diagnostics: partialDiagnostics }, connection)
  expect(second.id).toBe(first.id)
  expect(store.list()).toHaveLength(1)
  expect(store.get(first.id)?.name).toBe('renamed')
})

it('не удаляет credential reference, если его использует другой сервер', () => {
  const store = createTestServerStore()
  store.add({ ...baseServer, privateKeyCredentialId: 'cred-1' })
  store.add({ ...baseServer, host: 'other.example', privateKeyCredentialId: 'cred-1' })
  expect(store.countCredentialReferences('cred-1')).toBe(2)
  expect(store.countCredentialReferences('cred-1', store.list()[0].id)).toBe(1)
})
```

- [ ] **Step 2: Run tests and confirm failure**

Run: `npx vitest run tests/unit/server-store.test.ts`

Expected: FAIL because methods are absent.

- [ ] **Step 3: Implement schema-safe store changes**

Расширить `StoredServer` через `Omit<Server, 'id' | 'createdAt'>`, нормализовать старые записи:

```ts
privateKeyCredentialId: server.privateKeyCredentialId ?? null,
privateKeyName: server.privateKeyName ?? null,
setupStatus: server.setupStatus ?? (server.subscriptionUrl ? 'ready' : 'unknown'),
diagnostics: server.diagnostics ?? null
```

`upsertImported` ищет `host.toLowerCase() + port`, сохраняет прежний `id`, `createdAt`, `hostKeyFingerprint`, обновляет diagnostic/server metadata и не затирает существующие keys/subscription URL пустыми значениями. `updateConnection` сохраняет `privateKeyCredentialId` и name.

- [ ] **Step 4: Run focused tests and typecheck**

Run: `npx vitest run tests/unit/server-store.test.ts` и `npm run typecheck`.

Expected: PASS.

- [ ] **Step 5: Commit**

```text
git add src/main/core/servers.ts tests/unit/server-store.test.ts
git commit -m "feat: сделать импорт сервера идемпотентным"
```

---

## Task 4: Асинхронное разрешение SSH credentials

**Files:**
- Modify: `src/main/core/ssh-access.ts`
- Modify: `src/main/ipc-handlers.ts`
- Modify: `src/shared/types.ts` if resolver types need export
- Modify: `tests/unit/ssh-access.test.ts`
- Modify: `tests/unit/ssh-client.test.ts` only if Buffer wipe assertion is added

**Interfaces:**
- `createSshCredentials` remains pure/synchronous for file-path inputs.
- Add `createSshCredentialsFromKey(target, access, keyBuffer, options): SshCredentials` to avoid mixing keychain I/O into validation.
- Add async main helper `resolvePrivateKey(access, server, approvedPaths, keychain): Promise<{ access: SshAccessInput; privateKey?: Buffer }>`.
- `credentialsFor` becomes `async` and returns `{ credentials, access }` after keychain load.

- [ ] **Step 1: Add failing resolver tests**

```ts
it('берёт ключ из keychain reference, не требуя path', async () => {
  const keychain = { load: vi.fn().mockResolvedValue(Buffer.from('key')), save: vi.fn(), remove: vi.fn() }
  const resolved = await resolvePrivateKey({ username: 'root', authMethod: 'privateKey', privateKeyCredentialId: 'cred-1', privilegeMode: 'root' }, server, new Set(), keychain)
  expect(resolved.privateKey?.toString()).toBe('key')
  expect(keychain.load).toHaveBeenCalledWith('cred-1')
})

it('не принимает произвольный renderer path', async () => {
  await expect(resolvePrivateKey({ username: 'root', authMethod: 'privateKey', privateKeyPath: 'C:/secret', privilegeMode: 'root' }, server, new Set(), keychain)).rejects.toThrow('выбран через диалог')
})

it('passphrase не попадает в keychain resolver', async () => {
  const access = { username: 'root', authMethod: 'privateKey', privateKeyCredentialId: 'cred-1', passphrase: 'one-time', privilegeMode: 'root' as const }
  const resolved = await resolvePrivateKey(access, server, new Set(), keychain)
  expect(resolved.access.passphrase).toBe('one-time')
  expect(keychain.save).not.toHaveBeenCalled()
})
```

- [ ] **Step 2: Run focused tests to confirm failure**

Run: `npx vitest run tests/unit/ssh-access.test.ts`

Expected: FAIL because async key resolver is absent.

- [ ] **Step 3: Implement resolution order**

Порядок: `access.privateKeyCredentialId`, затем `server.privateKeyCredentialId`, затем approved legacy `privateKeyPath`. Для keychain bytes вызвать `createSshCredentialsFromKey`; для legacy path — существующий `createSshCredentials`. Если keychain возвращает `null`, сообщить «SSH-ключ не найден в системном хранилище; выберите его заново» и не читать произвольный path.

В `ipc-handlers.ts` создать один `const keychain = createSshKeychain()` на регистрацию handlers. `ssh:selectPrivateKey` после native dialog читает/валидирует файл в main, генерирует credential id, сохраняет bytes в keychain и возвращает `{ credentialId, name }`; при ошибке не возвращать path как сохранённый secret. Для текущей операции renderer передаёт credential id, а main загружает bytes.

После успешного auth `store.updateConnection` сохраняет только id/name/method/privilege. `SshClient.close()` оставляет существующий `privateKey?.fill(0)`.

- [ ] **Step 4: Run SSH tests, typecheck and build**

Run: `npx vitest run tests/unit/ssh-access.test.ts tests/unit/ssh-client.test.ts`, `npm run typecheck`, `npm run build`.

Expected: PASS; known unrelated Windows `/bin/sh` test не смешивать с focused run.

- [ ] **Step 5: Commit**

```text
git add src/main/core/ssh-access.ts src/main/ipc-handlers.ts src/shared/types.ts tests/unit/ssh-access.test.ts tests/unit/ssh-client.test.ts
git commit -m "feat: разрешать SSH-ключ из системного хранилища"
```

---

## Task 5: Optional email в server-side quickstart

**Files:**
- Modify: `xrayebator`
- Create: `validation/test-quickstart-email-and-inspect.sh` (inspect part is completed in Task 6; add email assertions now)

**Interfaces:**
- `quickstart_command` accepts `--email VALUE` and `--without-email`.
- `--email` validates `^[^@]+@[^@]+\.[^@]+$`.
- `--without-email` sets `email_mode=without` and never passes `-m`.
- Certbot command in quickstart contains `--register-unsafely-without-email` only in without mode.

- [ ] **Step 1: Write static failing Bash checks**

В validation script проверять:

```bash
quickstart_block=$(tr -d '\r' < xrayebator | sed -n '/^quickstart_command()/,/^happ_setup_command()/p')
grep -Fq -- '--without-email' <<< "$quickstart_block"
grep -Fq -- '--register-unsafely-without-email' <<< "$quickstart_block"
grep -Fq -- ' -m "$email" ' <<< "$quickstart_block"
! grep -Fq 'email="noreply@' <<< "$quickstart_block"
```

До реализации тест должен завершиться ненулевым кодом.

- [ ] **Step 2: Run the failing validation**

Run: `bash validation/test-quickstart-email-and-inspect.sh`

Expected: FAIL on missing `--without-email`.

- [ ] **Step 3: Implement explicit email mode**

В начале `quickstart_command` добавить:

```bash
local email="" email_mode="provided"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --email) email="$2"; email_mode="provided"; shift 2 ;;
    --without-email) email=""; email_mode="without"; shift ;;
    *) shift ;;
  esac
done
if [[ "$email_mode" == "provided" ]] && { [[ -z "$email" ]] || ! [[ "$email" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; }; then
  echo '{"ok":false,"error":"Некорректный email"}'
  return 1
fi
```

Около certbot-вызова собрать `certbot_email_args=()` и добавить либо `-m "$email"`, либо `--register-unsafely-without-email`; вызвать `"$certbot_bin" certonly ... "${certbot_email_args[@]}" ...`. Не применять изменение к интерактивным domain/self-steal меню.

Обновить help dispatch с двумя примерами.

- [ ] **Step 4: Run syntax and validation**

Run: `bash -n xrayebator` и `bash validation/test-quickstart-email-and-inspect.sh`.

Expected: PASS for email assertions.

- [ ] **Step 5: Commit**

```text
git add xrayebator validation/test-quickstart-email-and-inspect.sh
git commit -m "feat: разрешить quickstart без email"
```

---

## Task 6: Read-only server inspection CLI и inspector adapter

**Files:**
- Modify: `xrayebator`
- Modify: `src/main/core/server-inspector.ts`
- Create: `tests/unit/server-inspector.test.ts`
- Modify: `validation/test-quickstart-email-and-inspect.sh`

**Interfaces:**
- Remote command: `xrayebator inspect --json`.
- JSON fields: `ok`, `recognized`, `os`, `manager`, `xray`, `profiles`, `profile_count`, `route_count`, `subscription_installed`, `subscription_mode`, `subscription_domain`, `subscription_port`, `subscription_url`, `country`, `city`, `flag`, `error`.
- `ServerInspector.inspect(): Promise<InspectionSnapshot>` executes one elevated read-only command and parses JSON.
- `normalizeInspection(snapshot, fetchedKeys): ServerDiagnostics + Partial<Server>` is pure.

- [ ] **Step 1: Write parser and static safety tests first**

```ts
it('нормализует готовую публичную установку', () => {
  const result = normalizeInspection({ ok: true, recognized: true, xray: 'running', profiles: 'available', subscription_mode: 'ip_tls', subscription_url: 'https://203.0.113.10:8443/sub/token', profile_count: 1, route_count: 7, ...baseInspection }, [{ name: 'route', url: 'vless://x', transport: 'xhttp' }])
  expect(result.setupStatus).toBe('ready')
  expect(result.subscriptionUrl).toContain('https://')
  expect(result.routesCount).toBe(1)
})

it('не считает local-only URL рабочей подпиской', () => {
  const result = normalizeInspection({ ...baseInspection, subscription_mode: 'local_only', subscription_url: 'http://127.0.0.1:8080/sub/token' }, [])
  expect(result.setupStatus).toBe('partial')
  expect(result.subscriptionUrl).toBe('')
  expect(result.diagnostics?.subscription).toBe('localOnly')
})
```

В validation добавить проверки:

```bash
inspect_block=$(tr -d '\r' < xrayebator | sed -n '/^inspect_command()/,/^quickstart_command()/p')
grep -Fq 'inspect --json' <(tr -d '\r' < xrayebator)
grep -Fq 'systemctl is-active' <<< "$inspect_block"
! grep -Eq 'apt-get|safe_jq_write|systemctl restart|open_firewall_port|install_subscription_server' <<< "$inspect_block"
```

- [ ] **Step 2: Run failing tests**

Run: `npx vitest run tests/unit/server-inspector.test.ts` и `bash validation/test-quickstart-email-and-inspect.sh`.

Expected: FAIL because parser/CLI are absent.

- [ ] **Step 3: Implement Bash `inspect_command`**

Добавить функцию перед `quickstart_command`, которая:

1. выставляет `TERM=dumb`, `XRAYEBATOR_NONINTERACTIVE=1`;
2. проверяет `/usr/local/bin/xrayebator` через текущий dispatch only after command is already running (сам факт запуска — marker, дополнительно проверить `/usr/local/etc/xray`);
3. читает `/etc/os-release`, `command -v xray`, `config.json`, `profiles/*.json`;
4. получает service states только через `systemctl is-active --quiet` без restart;
5. читает существующие subscription markers и строит URL только при валидном token/base;
6. печатает один `jq -n` JSON в stdout;
7. всё диагностическое сообщение отправляет в stderr.

Добавить dispatch case `inspect) inspect_command "$@" ;;` и help. Не вызывать migration/helper, который пишет состояние.

- [ ] **Step 4: Implement TypeScript inspector and parser**

`ServerInspector` использует `SshClient`, выполняет `shellCommand('xrayebator', ['inspect', '--json'])` с `{ elevated: true }`, вызывает `extractJson` из `profiles.ts`, проверяет `recognized`, и в `finally` закрывает client. При наличии непустого non-local URL вызывает injected `fetchSubscription`; fetch error переводит subscription в `unreachable`, но не отменяет import.

`normalizeInspection` не принимает `127.0.0.1`, `localhost`, `http://` или `local_only` за public URL. `ready` только если manager detected, xray running, profiles available и subscription public; иначе `partial`, а при manager missing/invalid — `unknown`/ошибка import.

- [ ] **Step 5: Run validation and unit tests**

Run: `bash -n xrayebator`, `bash validation/test-quickstart-email-and-inspect.sh`, `npx vitest run tests/unit/server-inspector.test.ts`, `npm run typecheck`.

Expected: PASS; inspect test must prove no mutating command strings appear in the function.

- [ ] **Step 6: Commit**

```text
git add xrayebator src/main/core/server-inspector.ts tests/unit/server-inspector.test.ts validation/test-quickstart-email-and-inspect.sh
git commit -m "feat: добавить read-only диагностику Xrayebator"
```

---

## Task 7: Deployer optional email and main-process import IPC

**Files:**
- Modify: `src/main/core/deployer.ts`
- Modify: `src/main/ipc-handlers.ts`
- Modify: `src/preload/index.ts`
- Modify: `src/shared/types.ts`
- Modify: `tests/unit/deployer.test.ts` (создать)
- Modify: `tests/unit/ipc-contracts.test.ts` (создать, pure payload tests)

**Interfaces:**
- `DeployInput = { emailMode: EmailMode; email?: string; credentials }`.
- `Deployer.deploy` validates email only for `provided`, then invokes `quickstart --email` or `quickstart --without-email`.
- `ServerInspector` is constructed with credentials and injected subscription fetch.
- IPC `servers:import` returns `ImportResult`; no private key bytes in payload/response.

- [ ] **Step 1: Write failing deploy argument tests**

```ts
it('строит quickstart с email', () => expect(buildQuickstartArgs({ emailMode: 'provided', email: 'a@example.com' })).toEqual(['quickstart', '--email', 'a@example.com']))
it('строит quickstart без email', () => expect(buildQuickstartArgs({ emailMode: 'without' })).toEqual(['quickstart', '--without-email']))
it('отклоняет email только в provided mode', () => expect(() => buildQuickstartArgs({ emailMode: 'provided', email: '' })).toThrow('email'))
```

Добавить pure `buildQuickstartArgs` export из deployer, чтобы не мокать SSH весь unit test.

- [ ] **Step 2: Run failing test**

Run: `npx vitest run tests/unit/deployer.test.ts`

Expected: FAIL because helper/signature absent.

- [ ] **Step 3: Implement deploy command selection**

В `Deployer.deploy` убрать unconditional `if (!input.email)`; использовать `buildQuickstartArgs`, передать args через существующий `shellCommand`, сохранить parsing/result behavior. `emailMode='without'` не должен иметь `email` в логах.

- [ ] **Step 4: Add async IPC keychain/import handlers**

В `registerIpcHandlers`:

- создать keychain adapter;
- сделать `credentialsFor` async;
- `ssh:selectPrivateKey` сохраняет bytes и возвращает только `{ credentialId, name }`;
- `servers:import` валидирует `authMethod === 'privateKey'`, вызывает `ServerInspector`, выполняет optional subscription fetch, upsert store, сохраняет connection metadata и emits/returns result;
- не сохранять imported server при `recognized=false`;
- при частичной установке сохранить карточку без мёртвого subscription URL;
- при duplicate endpoint обновить одну карточку;
- `servers:remove` после store removal удаляет credential из keychain только при `countCredentialReferences === 0`;
- сохранить существующее host-key cleanup.

Expose in preload:

```ts
ssh: { selectPrivateKey: () => Promise<PrivateKeyReference | null> }
servers: { import: (payload: ImportServerPayload) => Promise<ImportResult> }
```

- [ ] **Step 5: Run tests, typecheck and build**

Run: `npx vitest run tests/unit/deployer.test.ts tests/unit/ipc-contracts.test.ts tests/unit/ssh-access.test.ts`, `npm run typecheck`, `npm run build`.

Expected: PASS.

- [ ] **Step 6: Commit**

```text
git add src/main/core/deployer.ts src/main/ipc-handlers.ts src/preload/index.ts src/shared/types.ts tests/unit/deployer.test.ts tests/unit/ipc-contracts.test.ts
 git commit -m "feat: подключить email mode и импорт через IPC"
```

---

## Task 8: UI выбора сценария и optional email

**Files:**
- Modify: `src/renderer/src/App.tsx`
- Modify: `src/renderer/src/pages/Dashboard.tsx`
- Modify: `src/renderer/src/pages/Dashboard.module.css`
- Modify: `src/renderer/src/pages/AddServer.tsx`
- Modify: `src/renderer/src/pages/AddServer.module.css`
- Modify: `src/renderer/src/i18n/ru.json`, `en.json`, `zh.json`
- Create/modify: `tests/unit/ui-contracts.test.ts` only for pure email readiness helper if useful

**Interfaces:**
- App view union gains `{ name: 'choice' }` and `{ name: 'import' }`.
- Dashboard receives `onAdd`, which opens choice; empty dashboard renders two cards.
- AddServer uses `EmailMode`, passes `{ emailMode, email: emailMode === 'provided' ? trimmed : undefined }`.

- [ ] **Step 1: Add pure failing readiness test**

Export `isDeployReady(form, access)` and test:

```ts
expect(isDeployReady({ host: 'vps', port: '22', emailMode: 'without', email: '' }, readyAccess)).toBe(true)
expect(isDeployReady({ host: 'vps', port: '22', emailMode: 'provided', email: '' }, readyAccess)).toBe(false)
expect(isDeployReady({ host: 'vps', port: '22', emailMode: 'provided', email: 'bad' }, readyAccess)).toBe(false)
```

- [ ] **Step 2: Run focused test and confirm failure**

Run: `npx vitest run tests/unit/ui-contracts.test.ts`

Expected: FAIL until helper exists.

- [ ] **Step 3: Implement navigation and Dashboard cards**

В `App.tsx` добавить `choice` view с двумя buttons/cards и `import` view. Успешный import добавляет/заменяет server in state и открывает `settings`, а не `keys`.

В `Dashboard.tsx`:

- при `servers.length === 0` показывать две карточки;
- при наличии серверов верхняя `+ Add` открывает choice;
- использовать icons `Rocket`, `Link2`, `Server` из lucide;
- сохранить существующие cards/actions/delete dialog.

В CSS сделать обе карточки одинакового веса, primary accent только у «Развернуть», secondary outline у «Подключить существующий», responsive one-column under 760px; не использовать отдельный чёрный/новый brand color.

- [ ] **Step 4: Implement email mode selector in AddServer**

Заменить unconditional email field на two-option accessible radio-like buttons. Default `provided`; `without` renders warning panel. `isDisabled` uses `isDeployReady`. Ensure `startDeploy` emits optional email, not empty string.

Добавить localization keys:

```json
"deploy": {
  "emailMode": "Email for Let's Encrypt",
  "emailProvided": "Add an email",
  "emailProvidedHint": "Recommended for renewal and account notices",
  "emailWithout": "Continue without email",
  "emailWithoutHint": "Certificate works, but Let's Encrypt cannot send notices or recovery mail",
  "withoutEmailWarning": "Without an email, renewal notices and ACME account recovery are unavailable."
}
```

Перевести эти ключи естественно в `ru.json` и `zh.json`; не оставлять русские тексты в EN/中文.

- [ ] **Step 5: Run tests, typecheck and build**

Run: `npx vitest run tests/unit/ui-contracts.test.ts`, `npm run typecheck`, `npm run build`.

Expected: PASS.

- [ ] **Step 6: Commit**

```text
git add src/renderer/src/App.tsx src/renderer/src/pages/Dashboard.tsx src/renderer/src/pages/Dashboard.module.css src/renderer/src/pages/AddServer.tsx src/renderer/src/pages/AddServer.module.css src/renderer/src/i18n tests/unit/ui-contracts.test.ts
git commit -m "feat: разделить сценарии нового и существующего сервера"
```

---

## Task 9: Мастер импорта и повторный доступ к Server Settings

**Files:**
- Create: `src/renderer/src/pages/ImportServer.tsx`
- Create: `src/renderer/src/pages/ImportServer.module.css`
- Modify: `src/renderer/src/components/SshAccessForm.tsx`
- Modify: `src/renderer/src/components/SshAccessForm.module.css`
- Modify: `src/renderer/src/pages/ServerSettings.tsx`
- Modify: `src/renderer/src/pages/ServerKeys.tsx`
- Modify: `src/renderer/src/i18n/ru.json`, `en.json`, `zh.json`

**Interfaces:**
- Import form always sets `authMethod: 'privateKey'`, uses `privateKeyCredentialId`, and passes root/sudo mode.
- `SshAccessForm` props gain `allowedAuthMethods?: SshAuthMethod[]`, `keyReference?: PrivateKeyReference | null`, `onKeySelected?: (reference) => void`.
- Server Settings initializes saved key reference, calls API without path/password, and only asks passphrase when user supplies it for the current operation.

- [ ] **Step 1: Add failing pure import payload tests**

```ts
it('import payload не содержит password/privateKey bytes', () => {
  const payload = buildImportPayload({ host: 'vps', port: '22', access: { username: 'root', privateKeyCredentialId: 'cred-1', privilegeMode: 'root' } })
  expect(payload.access.authMethod).toBe('privateKey')
  expect(payload.access).not.toHaveProperty('password')
  expect(payload.access).not.toHaveProperty('privateKey')
})
```

- [ ] **Step 2: Run failing test**

Run: `npx vitest run tests/unit/ui-contracts.test.ts`

Expected: FAIL until import helper/form exists.

- [ ] **Step 3: Implement ImportServer form**

Форма повторяет host/port layout AddServer, но использует `SshAccessForm` с `allowedAuthMethods={['privateKey']}`. При выборе ключа `window.api.ssh.selectPrivateKey()` возвращает `{ credentialId, name }`; renderer хранит только reference. Кнопка disabled без host, username, credential id или valid port.

При submit вызвать `window.api.servers.import`, показать этапы SSH → recognize → inspect → subscription → save, ошибки вывести без секретов. При `result.serverId` запросить `servers.get`, вызвать `onDone(server)`.

- [ ] **Step 4: Update SshAccessForm and ServerSettings**

Вместо отображения только `privateKeyPath` показывать `privateKeyName`/basename; сохранять `privateKeyCredentialId` в access state. Для старых server cards разрешить path fallback только после native dialog approval. При `load`, `create`, `update`, `uninstall`, profile actions использовать saved credential id и не требовать повторного выбора файла.

Обновить note:

- ключ хранится в системном keychain;
- passphrase не сохраняется;
- парольный доступ остаётся session-only;
- если keychain запись потеряна, предложить выбрать ключ заново.

В `ServerKeys` при `subscriptionUrl === ''` показывать `keys.none`/diagnostic message вместо попытки fetch пустого URL.

- [ ] **Step 5: Run typecheck/build and focused tests**

Run: `npx vitest run tests/unit/ui-contracts.test.ts tests/unit/ssh-access.test.ts`, `npm run typecheck`, `npm run build`.

Expected: PASS.

- [ ] **Step 6: Commit**

```text
git add src/renderer/src/pages/ImportServer.tsx src/renderer/src/pages/ImportServer.module.css src/renderer/src/components/SshAccessForm.tsx src/renderer/src/components/SshAccessForm.module.css src/renderer/src/pages/ServerSettings.tsx src/renderer/src/pages/ServerKeys.tsx src/renderer/src/i18n
git commit -m "feat: добавить мастер импорта существующего сервера"
```

---

## Task 10: Diagnostics в карточке и документация

**Files:**
- Modify: `src/renderer/src/pages/Dashboard.tsx`/`.module.css`
- Modify: `src/renderer/src/pages/ServerSettings.tsx`/`.module.css`
- Modify: `src/renderer/src/i18n/ru.json`, `en.json`, `zh.json`
- Modify: `docs/desktop-gui.md`
- Modify: `docs/ru/desktop-gui.md`
- Modify: `docs/zh-CN/desktop-gui.md`
- Modify: `docs/security.md`
- Modify: `docs/ru/security.md`
- Modify: `docs/zh-CN/security.md`

**Interfaces:**
- Dashboard displays `ready`/`partial` state without hiding existing actions.
- Settings displays component diagnostics and inspected timestamp.

- [ ] **Step 1: Add diagnostics copy and test fixture**

Добавить localization keys for manager/xray/profiles/subscription states in all locales and a test ensuring every new RU key exists in EN and ZH. Test should compare a fixed list of paths, not arbitrary JSON shape.

- [ ] **Step 2: Render non-invasive status**

В server card добавить compact status chip:

- ready → success “Ready”;
- partial → warning “Partially configured”;
- unknown → neutral “Imported”.

В settings после подключения показать diagnostic list; не делать автоматических repair calls. Existing buttons update/uninstall remain explicit actions.

- [ ] **Step 3: Update docs**

В docs описать:

- две onboarding cards и import scope;
- read-only inspection and partial state;
- optional email and ACME consequences;
- `quickstart --without-email`;
- keytar/system keychain boundary, no plaintext fallback, passphrase session-only;
- subscription URL/VLESS links remain bearer credentials;
- legacy GUI keyring claims do not describe active Electron GUI.

Синхронизировать смысл во всех трёх языках; command names и security guarantees не переводить по-разному.

- [ ] **Step 4: Run locale/docs checks**

Run: `npm run typecheck`, `npm run build`, `git diff --check`.

Expected: PASS; no missing translation key test.

- [ ] **Step 5: Commit**

```text
git add src/renderer/src/pages/Dashboard.tsx src/renderer/src/pages/Dashboard.module.css src/renderer/src/pages/ServerSettings.tsx src/renderer/src/pages/ServerSettings.module.css src/renderer/src/i18n docs/desktop-gui.md docs/ru/desktop-gui.md docs/zh-CN/desktop-gui.md docs/security.md docs/ru/security.md docs/zh-CN/security.md
git commit -m "docs: описать импорт и безопасное хранение SSH-ключей"
```

---

## Task 11: Полная верификация и security audit

**Files:**
- Modify only files with verified test failures.
- Add no feature code in this task.

- [ ] **Step 1: Verify repository and branch**

Run:

```text
git status --short --branch
git log --oneline --decorate -12
git diff upstream/main...HEAD --stat
```

Expected: branch is `dev`, no uncommitted changes before verification, no push performed, and history contains the design plus logical implementation commits.

- [ ] **Step 2: Run Bash syntax and validation**

Run:

```text
bash -n xrayebator
bash -n install.sh
bash -n update.sh
bash -n uninstall.sh
bash validation/test-quickstart-email-and-inspect.sh
bash validation/test-quickstart-migration-parity.sh
bash validation/test-quickstart-subscription-port.sh
bash validation/test-main-readiness-regressions.sh
```

Expected: all selected Bash checks pass.

- [ ] **Step 3: Run TypeScript checks and tests**

Run:

```text
npm run typecheck
npm test
npm run build
```

Expected: typecheck/build pass. On Windows, if `tests/unit/shell-command.test.ts` fails solely because `/bin/sh` is absent, record the existing `38 passed / 1 failed` caveat and do not weaken the test; Linux CI remains authoritative.

- [ ] **Step 4: Perform manual secret audit**

Run searches:

```text
grep -R "privateKey" src/main src/preload src/shared src/renderer --include='*.ts' --include='*.tsx'
grep -R "setPassword\|getPassword\|deletePassword" src/main --include='*.ts'
grep -R "console\.log\|onLog" src/main/core --include='*.ts'
```

Confirm manually:

- only keychain adapter calls `keytar`;
- no private-key Buffer crosses preload/renderer;
- no passphrase is persisted by store or keychain;
- `SshClient.close()` wipes the operation Buffer;
- keychain failure has no plaintext fallback;
- inspect does not mutate server state;
- host-key mismatch returns before command execution;
- subscription fetch failure creates partial state, not a fake URL.

- [ ] **Step 5: Review final diff and commit any verified fix**

Run `git diff upstream/main...HEAD --check` and inspect every changed file. If a concrete defect is found, add a focused regression test first, fix it, rerun the relevant command, and commit with the root cause.

- [ ] **Step 6: Final local status report**

Use `get_goal`, verify all objective conditions, then update the goal to `complete` only if tests, typecheck/build, docs and local commits are complete. Report commit hashes, test caveats, branch synchronization point and explicitly state that no push was performed.

---

## Plan self-review

- **Spec coverage:** Tasks 1–4 cover contracts, keychain, store migration and SSH reuse; Tasks 5–6 cover optional email and read-only inspect; Tasks 7–9 cover IPC and both UI flows; Task 10 covers diagnostics/locales/docs; Task 11 covers full verification/security audit.
- **No placeholders:** There are no `TBD`, `TODO`, or unspecified implementation branches; each task defines files, interfaces, tests, commands and commit message.
- **Type consistency:** `PrivateKeyReference`, `EmailMode`, `ServerDiagnostics`, `ImportServerPayload`, `ImportResult`, and `SshKeychain` are introduced before consumers; later tasks use the same names and fields.
- **Safety check:** No task stores passphrase, SSH password, or private-key bytes outside keychain/main-process operation memory; import remains read-only and local-only URLs are never treated as public credentials.
- **Scope check:** The plan intentionally excludes arbitrary Xray import, auto-repair and terminal features; these are outside the approved design.
