import { app, ipcMain, BrowserWindow, dialog } from 'electron'
import net from 'node:net'
import { basename, resolve } from 'node:path'
import { randomUUID } from 'node:crypto'
import { readFileSync, statSync } from 'node:fs'
import type {
  ImportServerPayload,
  ImportStep,
  ProfileCreateInput,
  ProfileExpireInput,
  ProfileFingerprintInput,
  ProfilePortInput,
  ProfileRevokeInput,
  ProfileSniInput,
  Server,
  ServerMaintenanceResult,
  SshAccessInput
} from '@shared/types'
import type { ServerConnectionMetadata, ServerStore } from './core/servers'
import { Deployer } from './core/deployer'
import { fetchSubscription, parseSubscription } from './core/subscription'
import { shellCommand } from './core/shell-command'
import { SshClient } from './core/ssh-client'
import { ProfileManager } from './core/profiles'
import { BackendManager } from './core/backend-manager'
import { ServerManager } from './core/server-manager'
import { ServerInspector } from './core/server-inspector'
import { probePortsFor } from './core/probe-ports'
import {
  createSshCredentials,
  resolvePrivateKey,
  resolveStoredSshPassword
} from './core/ssh-access'
import {
  createSshKeychain,
  createSshPasswordStore,
  MAX_PRIVATE_KEY_BYTES
} from './core/ssh-keychain'
import type { SshCredentials } from './core/ssh-client'

interface IpcContext {
  store: ServerStore
}

export function registerIpcHandlers({ store }: IpcContext): void {
  const approvedPrivateKeyPaths = new Set<string>()
  for (const server of store.list()) {
    if (server.privateKeyPath) approvedPrivateKeyPaths.add(resolve(server.privateKeyPath))
  }

  const keychain = createSshKeychain()
  const passwordStore = createSshPasswordStore()
  const transientKeys = new Map<string, Buffer>()
  const credentialStore = {
    save: keychain.save,
    load: async (credentialId: string): Promise<Buffer | null> => {
      // Fallback key (OS keychain unavailable): one in-memory copy for the whole
      // app session, issued as a fresh copy per SSH operation. The original is
      // never returned to the renderer and is dropped at app exit.
      const transient = transientKeys.get(credentialId)
      if (transient) return Buffer.from(transient)
      return keychain.load(credentialId)
    },
    remove: keychain.remove
  }
  app.on('before-quit', () => {
    for (const key of transientKeys.values()) key.fill(0)
    transientKeys.clear()
  })

  ipcMain.handle('ssh:selectPrivateKey', async () => {
    const selection = await dialog.showOpenDialog({
      title: 'Выберите приватный SSH-ключ',
      properties: ['openFile', 'dontAddToRecent']
    })
    if (selection.canceled || selection.filePaths.length === 0) return null

    const path = resolve(selection.filePaths[0])
    const stat = statSync(path)
    if (!stat.isFile() || stat.size < 1 || stat.size > MAX_PRIVATE_KEY_BYTES) {
      throw new Error('Файл приватного SSH-ключа пустой или слишком большой')
    }

    const temporaryKey = readFileSync(path)
    const credentialId = randomUUID().replace(/-/g, '')
    try {
      await keychain.save(credentialId, temporaryKey)
      return { credentialId, name: basename(path), persisted: true }
    } catch {
      // Keychain unavailable: keep a session-only in-memory copy (never returned to
      // the renderer, never written to disk); the UI is told reuse is unavailable.
      const temporaryCredentialId = randomUUID().replace(/-/g, '')
      transientKeys.set(temporaryCredentialId, Buffer.from(temporaryKey))
      return { credentialId: temporaryCredentialId, name: basename(path), persisted: false }
    } finally {
      temporaryKey.fill(0)
    }
  })

  const persistSshPassword = async (
    access: SshAccessInput,
    existingCredentialId?: string | null
  ): Promise<void> => {
    if (access.authMethod !== 'password' || !access.password || access.passwordPersisted === true) {
      return
    }
    const credentialId = existingCredentialId ?? access.passwordCredentialId ?? randomUUID().replace(/-/g, '')
    try {
      await passwordStore.save(credentialId, access.password)
      access.passwordCredentialId = credentialId
      access.passwordPersisted = true
    } catch {
      // OS keychain failure is non-fatal to the current authenticated session; no file fallback.
      access.passwordCredentialId = undefined
      access.passwordPersisted = false
    }
  }

  const credentialsFor = async (
    server: Pick<
      Server,
      | 'id'
      | 'host'
      | 'port'
      | 'privateKeyPath'
      | 'privateKeyCredentialId'
      | 'privateKeyName'
       | 'passwordCredentialId'
       | 'passwordPersisted'
      | 'hostKeyFingerprint'
    > | null,
    target: { host: string; port: number },
    accessInput: SshAccessInput
  ): Promise<{ credentials: SshCredentials; access: SshAccessInput }> => {
    if (!accessInput || typeof accessInput !== 'object') {
      throw new Error('Не указаны параметры SSH-доступа')
    }
    const resolved = await resolvePrivateKey(accessInput, server, approvedPrivateKeyPaths, credentialStore)
    const privateKey = resolved.privateKey
    const resolvedAccess = await resolveStoredSshPassword(resolved.access, server, passwordStore)
    const expectedHostKey =
      store.getHostKey(target.host, target.port) ?? server?.hostKeyFingerprint ?? undefined
    const credentials = createSshCredentials(target, resolvedAccess, {
      approvedPrivateKeyPaths,
      expectedHostKeyFingerprint: expectedHostKey,
      fallbackPrivateKeyPath: server?.privateKeyPath,
      privateKey,
      onHostKeyTrusted: (fingerprint) => {
        store.trustHostKey(target.host, target.port, fingerprint)
      },
      onAuthenticated: server
        ? async () => {
            if (expectedHostKey) store.trustHostKey(target.host, target.port, expectedHostKey)
            await persistSshPassword(resolvedAccess, server.passwordCredentialId)
            store.updateConnection(server.id, {
              username: resolvedAccess.username,
              authMethod: resolvedAccess.authMethod,
              privilegeMode: resolvedAccess.privilegeMode,
              privateKeyPath: resolvedAccess.privateKeyPersisted ? null : resolvedAccess.privateKeyPath ?? null,
              privateKeyCredentialId: resolvedAccess.privateKeyCredentialId ?? null,
              privateKeyName: resolvedAccess.privateKeyName ?? null,
              privateKeyPersisted: resolvedAccess.privateKeyPersisted ?? null,
              passwordCredentialId: resolvedAccess.passwordCredentialId ?? null,
              passwordPersisted: resolvedAccess.passwordPersisted ?? null
            })
          }
        : undefined
    })
    return { credentials, access: resolvedAccess }
  }

  ipcMain.handle('servers:list', (): Server[] => store.list())
  ipcMain.handle('servers:get', (_e, id: string): Server | null => store.get(id) ?? null)
  ipcMain.handle('servers:remove', async (_e, id: string): Promise<void> => {
    const server = store.get(id)
    if (!server || !store.remove(id)) return
    const credentialId = server.privateKeyCredentialId
    if (credentialId) {
      // Ключ удаляем из keychain только когда на него не ссылается другая карточка.
      if (store.countCredentialReferences(credentialId) === 0) {
        const transient = transientKeys.get(credentialId)
        if (transient) {
          transient.fill(0)
          transientKeys.delete(credentialId)
        } else {
          try {
            await keychain.remove(credentialId)
          } catch {
            // Ключ уже отсутствует или хранилище недоступно — карточка всё равно удалена.
          }
        }
      }
    }
    const passwordCredentialId = server.passwordCredentialId
    if (
      passwordCredentialId &&
      store.countPasswordCredentialReferences(passwordCredentialId) === 0
    ) {
      try {
        await passwordStore.remove(passwordCredentialId)
      } catch {
        // Ключница недоступна или запись уже удалена; карточка всё равно удалена.
      }
    }
    const sameEndpointRemains = store
      .list()
      .some(
        (candidate) =>
          candidate.host.toLowerCase() === server.host.toLowerCase() &&
          candidate.port === server.port
      )
    if (!sameEndpointRemains) store.forgetHostKey(server.host, server.port)
  })

  ipcMain.handle('servers:check', (_e, id: string): Promise<boolean> => {
    const server = store.get(id)
    if (!server) return Promise.resolve(false)
    return checkServerReachable(server)
  })
  ipcMain.handle('servers:forgetHostKey', (_e, id: string): void => {
    const server = store.get(id)
    if (!server) throw new Error('Сервер не найден')
    store.forgetHostKey(server.host, server.port)
  })

  ipcMain.on('deploy:start', (event, payload) => {
    const win = BrowserWindow.fromWebContents(event.sender)
    if (!win) return

    const emit = (channel: string, data: unknown): void => {
      if (!win.isDestroyed()) win.webContents.send(channel, data)
    }

    const deployer = new Deployer(
      (step, message) => {
        emit('deploy:event', { type: 'step', step, status: 'running', label: message })
      },
      (text) => {
        emit('deploy:event', { type: 'log', text })
      }
    )

    ;(async () => {
      try {
        const target = { host: payload.host, port: payload.port }
        const { credentials, access } = await credentialsFor(null, target, payload.access)
        const result = await deployer.deploy({
          emailMode: payload.emailMode === 'without' ? 'without' : 'provided',
          email: payload.email,
          credentials
        })
        await persistSshPassword(access)

        const server = store.add({
          name: payload.host,
          host: payload.host,
          port: payload.port,
          username: access.username,
          os: result.os,
          country: result.country,
          city: result.city,
          flag: result.flag,
          routesCount: result.keys.length,
          subscriptionUrl: result.subscriptionUrl,
          keys: result.keys,
          authMethod: access.authMethod,
          privilegeMode: access.privilegeMode,
          privateKeyPath: access.privateKeyPersisted ? null : access.privateKeyPath ?? null,
          privateKeyCredentialId: access.privateKeyCredentialId ?? null,
          privateKeyName: access.privateKeyName ?? null,
          privateKeyPersisted: access.privateKeyPersisted ?? null,
          passwordCredentialId: access.passwordCredentialId ?? null,
          passwordPersisted: access.passwordPersisted ?? null,
          setupStatus: result.degraded ? 'partial' : 'ready',
          degraded: result.degraded,
          hostKeyFingerprint: store.getHostKey(payload.host, payload.port) ?? null
        })

        emit('deploy:event', {
          type: 'done',
          payload: {
            serverId: server.id,
            subscriptionUrl: result.subscriptionUrl,
            keys: result.keys
          }
        })
      } catch (err) {
        emit('deploy:event', {
          type: 'error',
          message: err instanceof Error ? err.message : String(err)
        })
      }
    })()
  })

  // http_tls-fallback: ключи грузятся curl'ом на самом server'е (loopback).
  // Переиспользуем resolveStoredSshPassword через credentialsFor — как SSH-страницы.
  const fetchSubscriptionViaServer = async (
    serverId: string,
    url: string
  ): Promise<{ keys: ReturnType<typeof parseSubscription>; hysteria2Links: string[] }> => {
    const server = store.get(serverId)
    if (!server) throw new Error('Сервер не найден')
    const access: SshAccessInput = {
      username: server.username,
      authMethod: server.authMethod ?? 'password',
      passwordCredentialId: server.passwordCredentialId ?? undefined,
      passwordPersisted: server.passwordPersisted ?? false,
      privilegeMode: server.privilegeMode ?? 'root'
    }
    const { credentials } = await credentialsFor(server, server, access)
    const client = new SshClient(credentials)
    try {
      await client.connect()
      const res = await client.exec(
        shellCommand('curl', ['-sS', '--connect-timeout', '5', '--max-time', '30', url])
      )
      if (res.code !== 0 || !res.stdout.trim()) {
        throw new Error(
          `Subscription недоступна локально на сервере (curl код ${res.code}): ${res.stderr.trim() || 'пусто'}`
        )
      }
      const keys = parseSubscription(res.stdout)
      if (!keys.length) throw new Error('Subscription вернул пустой список ключей')
      return { keys, hysteria2Links: [] }
    } finally {
      client.close()
    }
  }

  ipcMain.handle('subscription:fetch', async (_e, serverId: string) => {
    const server = store.get(serverId)
    if (!server) throw new Error('Сервер не найден')
    // http_tls-fallback: публичный URL недоступен с клиента — ключи тянутся
    // curl'ом на самом server'е (loopback 127.0.0.1:8080).
    const { keys, hysteria2Links } = server.degraded
      ? await fetchSubscriptionViaServer(serverId, server.subscriptionUrl)
      : await fetchSubscription(server.subscriptionUrl)
    store.updateKeys(serverId, keys)
    // hysteria2-ключи персистятся рядом с vless — страница «Ключи» открывается мгновенно.
    const updated = store.updateBackendKeys(serverId, { hysteria2Keys: hysteria2Links })
    return {
      serverId,
      subscriptionUrl: server.subscriptionUrl,
      keys,
      hysteria2Links: updated?.hysteria2Keys ?? hysteria2Links
    }
  })

  ipcMain.handle('servers:import', async (event, payload: ImportServerPayload) => {
    if (!payload || typeof payload !== 'object') throw new Error('Некорректный запрос импорта')
    if (!payload.access) {
      throw new Error('Не указаны параметры SSH-доступа')
    }
    const emitStep = (step: ImportStep): void => {
      if (!event.sender.isDestroyed()) {
        event.sender.send('servers:importEvent', { step })
      }
    }
    const emitLog = (text: string): void => {
      if (!event.sender.isDestroyed()) {
        event.sender.send('servers:importEvent', { log: text })
      }
    }
    emitStep('ssh')
    const target = { host: payload.host, port: payload.port }
    const { credentials, access } = await credentialsFor(null, target, payload.access)
    emitStep('inspect')
    const inspector = new ServerInspector(
      credentials,
      async (url) => {
        emitStep('subscription')
        const fetched = await fetchSubscription(url)
        return fetched.keys
      },
      emitLog
    )
    const result = await inspector.inspect()
    await persistSshPassword(access)
    emitStep('save')
    emitLog('card: сервер сохранён в списке, открываю панель настроек')

    const connection: ServerConnectionMetadata = {
      username: access.username,
      authMethod: access.authMethod,
      privilegeMode: access.privilegeMode,
      privateKeyPath: access.privateKeyPersisted ? null : access.privateKeyPath ?? null,
      privateKeyCredentialId: access.privateKeyCredentialId ?? null,
      privateKeyName: access.privateKeyName ?? null,
      privateKeyPersisted: access.privateKeyPersisted ?? null,
      passwordCredentialId: access.passwordCredentialId ?? null,
      passwordPersisted: access.passwordPersisted ?? null
    }

    const server = store.upsertImported(
      {
        name: payload.host,
        host: payload.host,
        port: payload.port,
        username: access.username,
        os: result.os,
        country: result.country,
        city: result.city,
        flag: result.flag,
        routesCount: result.routesCount,
        subscriptionUrl: result.subscriptionUrl,
        keys: result.keys,
        setupStatus: result.setupStatus,
        diagnostics: result.diagnostics,
        hostKeyFingerprint: store.getHostKey(payload.host, payload.port) ?? null
      },
      connection
    )

    return { serverId: server.id, diagnostics: result.diagnostics, keys: result.keys }
  })

  const profileManagerFor = async (
    serverId: string,
    access: SshAccessInput
  ): Promise<ProfileManager> => {
    const server = store.get(serverId)
    if (!server) throw new Error('Сервер не найден')
    const { credentials } = await credentialsFor(server, server, access)
    return new ProfileManager(credentials)
  }

  ipcMain.handle('profiles:list', async (_e, serverId: string, access: SshAccessInput) => {
    const manager = await profileManagerFor(serverId, access)
    const result = await manager.list()
    if (!result.ok) throw new Error(result.error ?? 'Не удалось получить список профилей')
    return result
  })

  ipcMain.handle(
    'profiles:create',
    async (
      _e,
      serverId: string,
      access: SshAccessInput,
      input: ProfileCreateInput
    ) => {
      const manager = await profileManagerFor(serverId, access)
      return manager.create(input)
    }
  )

  ipcMain.handle(
    'profiles:remove',
    async (_e, serverId: string, access: SshAccessInput, name: string) => {
      const manager = await profileManagerFor(serverId, access)
      return manager.remove(name)
    }
  )

  ipcMain.handle(
    'profiles:changeFingerprint',
    async (
      _e,
      serverId: string,
      access: SshAccessInput,
      input: ProfileFingerprintInput
    ) => {
      const manager = await profileManagerFor(serverId, access)
      return manager.changeFingerprint(input)
    }
  )

  ipcMain.handle(
    'profiles:changeSni',
    async (
      _e,
      serverId: string,
      access: SshAccessInput,
      input: ProfileSniInput
    ) => {
      const manager = await profileManagerFor(serverId, access)
      return manager.changeSni(input)
    }
  )

  ipcMain.handle('profiles:sniList', async (_e, serverId: string, access: SshAccessInput) => {
    const manager = await profileManagerFor(serverId, access)
    return manager.sniList()
  })

  ipcMain.handle(
    'profiles:changePort',
    async (
      _e,
      serverId: string,
      access: SshAccessInput,
      input: ProfilePortInput
    ) => {
      const manager = await profileManagerFor(serverId, access)
      return manager.changePort(input)
    }
  )

  ipcMain.handle(
    'profiles:revoke',
    async (_e, serverId: string, access: SshAccessInput, input: ProfileRevokeInput) => {
      const manager = await profileManagerFor(serverId, access)
      return manager.revoke(input)
    }
  )

  ipcMain.handle(
    'profiles:setExpire',
    async (_e, serverId: string, access: SshAccessInput, input: ProfileExpireInput) => {
      const manager = await profileManagerFor(serverId, access)
      return manager.setExpire(input)
    }
  )

  const backendManagerFor = async (
    serverId: string,
    access: SshAccessInput
  ): Promise<BackendManager> => {
    const server = store.get(serverId)
    if (!server) throw new Error('Сервер не найден')
    const { credentials } = await credentialsFor(server, server, access)
    return new BackendManager(credentials)
  }

  // Кэш AWG-конфигов персистится в карточке сервера (server.awgConfs) —
  // страница «Ключей» показывает их мгновенно и обновляет в фоне.
  ipcMain.handle('backends:status', async (_e, serverId: string, access: SshAccessInput) => {
    const manager = await backendManagerFor(serverId, access)
    const result = await manager.status()
    if (!result.ok) throw new Error(result.error ?? 'Не удалось получить статус бэкендов')
    return result
  })

  ipcMain.handle(
    'backends:hysteria2Grant',
    async (_e, serverId: string, access: SshAccessInput, name: string) => {
      if (!name) throw new Error('Не указано имя профиля')
      const manager = await backendManagerFor(serverId, access)
      return manager.hysteria2Grant(name)
    }
  )

  ipcMain.handle(
    'backends:awgGrant',
    async (_e, serverId: string, access: SshAccessInput, name: string) => {
      if (!name) throw new Error('Не указано имя профиля')
      const manager = await backendManagerFor(serverId, access)
      const result = await manager.awgGrant(name)
      if (result.ok) store.updateBackendKeys(serverId, { awgConfs: {} })
      return result
    }
  )

  ipcMain.handle(
    'backends:awgConf',
    async (_e, serverId: string, access: SshAccessInput, name: string) => {
      if (!name) throw new Error('Не указано имя профиля')
      const manager = await backendManagerFor(serverId, access)
      const result = await manager.awgConf(name)
      if (!result.ok) throw new Error(result.error ?? 'Не удалось получить конфиг AWG')
      if (result.conf) {
        const current = store.get(serverId)
        store.updateBackendKeys(serverId, {
          awgConfs: { ...(current?.awgConfs ?? {}), [name]: result.conf }
        })
      }
      return result
    }
  )

  ipcMain.handle(
    'backends:awg31',
    async (_e, serverId: string, access: SshAccessInput, on: boolean) => {
      const manager = await backendManagerFor(serverId, access)
      const result = await manager.awg31(Boolean(on))
      if (result.ok) store.updateBackendKeys(serverId, { awgConfs: {} })
      return result
    }
  )

  ipcMain.handle(
    'backends:hysteria2Install',
    async (_e, serverId: string, access: SshAccessInput, grantAll: boolean) => {
      const manager = await backendManagerFor(serverId, access)
      return manager.hysteria2Install(Boolean(grantAll))
    }
  )

  ipcMain.handle('backends:hysteria2Uninstall', async (_e, serverId: string, access: SshAccessInput) => {
    const manager = await backendManagerFor(serverId, access)
    return manager.hysteria2Uninstall()
  })

  ipcMain.handle(
    'backends:awgInstall',
    async (_e, serverId: string, access: SshAccessInput, grantAll: boolean) => {
      const manager = await backendManagerFor(serverId, access)
      return manager.awgInstall(Boolean(grantAll))
    }
  )

  ipcMain.handle('backends:awgUninstall', async (_e, serverId: string, access: SshAccessInput) => {
    const manager = await backendManagerFor(serverId, access)
    const result = await manager.awgUninstall()
    if (result.ok) store.updateBackendKeys(serverId, { awgConfs: {} })
    return result
  })

  ipcMain.handle(
    'backends:hysteria2Subbody',
    async (_e, serverId: string, access: SshAccessInput, on: boolean) => {
      const manager = await backendManagerFor(serverId, access)
      return manager.hysteria2Subbody(Boolean(on))
    }
  )

  ipcMain.handle(
    'backends:hysteria2Link',
    async (_e, serverId: string, access: SshAccessInput, name: string) => {
      if (!name) throw new Error('Не указано имя профиля')
      const manager = await backendManagerFor(serverId, access)
      const result = await manager.hysteria2Link(name)
      if (!result.ok) throw new Error(result.error ?? 'Не удалось получить hysteria2-ссылку')
      return result
    }
  )

  const serverManagerFor = async (
    serverId: string,
    access: SshAccessInput
  ): Promise<ServerManager> => {
    const server = store.get(serverId)
    if (!server) throw new Error('Сервер не найден')
    const { credentials } = await credentialsFor(server, server, access)
    return new ServerManager(credentials)
  }

  ipcMain.handle(
    'server:update',
    async (
      _e,
      serverId: string,
      access: SshAccessInput,
      branch?: string
    ): Promise<ServerMaintenanceResult> => {
      return (await serverManagerFor(serverId, access)).update(branch)
    }
  )

  ipcMain.handle(
    'server:uninstall',
    async (_e, serverId: string, access: SshAccessInput): Promise<ServerMaintenanceResult> => {
      return (await serverManagerFor(serverId, access)).uninstall()
    }
  )
}

function checkServerReachable(server: Server): Promise<boolean> {
  const ports = probePortsFor(server)
  const deadline = Date.now() + 7000
  return tryConnectPorts(server.host, ports, deadline)
}

function tcpReachable(host: string, port: number, timeoutMs: number): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = net.connect(port, host)
    socket.setTimeout(timeoutMs)
    let done = false
    const finish = (ok: boolean): void => {
      if (done) return
      done = true
      socket.destroy()
      resolve(ok)
    }
    socket.once('connect', () => finish(true))
    socket.once('timeout', () => finish(false))
    socket.once('error', () => finish(false))
  })
}

async function tryConnectPorts(host: string, ports: number[], deadline: number): Promise<boolean> {
  for (const port of ports) {
    if (Date.now() > deadline) return false
    const remaining = Math.max(300, deadline - Date.now())
    if (await tcpReachable(host, port, remaining)) return true
  }
  return false
}
