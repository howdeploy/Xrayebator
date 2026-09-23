import { app, ipcMain, BrowserWindow, dialog } from 'electron'
import net from 'node:net'
import { basename, resolve } from 'node:path'
import { randomUUID } from 'node:crypto'
import { readFileSync, statSync } from 'node:fs'
import type {
  ImportServerPayload,
  ImportStep,
  ProfileCreateInput,
  ProfileFingerprintInput,
  ProfilePortInput,
  ProfileSniInput,
  Server,
  ServerMaintenanceResult,
  SshAccessInput
} from '@shared/types'
import type { ServerConnectionMetadata, ServerStore } from './core/servers'
import { Deployer } from './core/deployer'
import { fetchSubscription } from './core/subscription'
import { ProfileManager } from './core/profiles'
import { ServerManager } from './core/server-manager'
import { ServerInspector } from './core/server-inspector'
import { probePortsFor } from './core/probe-ports'
import { createSshCredentials, normalizeSshAccess, resolvePrivateKey } from './core/ssh-access'
import { createSshKeychain, MAX_PRIVATE_KEY_BYTES } from './core/ssh-keychain'
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

  const credentialsFor = async (
    server: Pick<
      Server,
      | 'id'
      | 'host'
      | 'port'
      | 'privateKeyPath'
      | 'privateKeyCredentialId'
      | 'privateKeyName'
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
    const access = normalizeSshAccess(resolved.access, server?.privateKeyPath)
    const expectedHostKey =
      store.getHostKey(target.host, target.port) ?? server?.hostKeyFingerprint ?? undefined
    const credentials = createSshCredentials(target, access, {
      approvedPrivateKeyPaths,
      expectedHostKeyFingerprint: expectedHostKey,
      fallbackPrivateKeyPath: server?.privateKeyPath,
      privateKey,
      onHostKeyTrusted: (fingerprint) => {
        store.trustHostKey(target.host, target.port, fingerprint)
      },
      onAuthenticated: server
        ? () => {
            if (expectedHostKey) store.trustHostKey(target.host, target.port, expectedHostKey)
            store.updateConnection(server.id, {
              username: access.username,
              authMethod: access.authMethod,
              privilegeMode: access.privilegeMode,
              privateKeyPath: access.privateKeyPersisted ? null : access.privateKeyPath ?? null,
              privateKeyCredentialId: access.privateKeyCredentialId ?? null,
              privateKeyName: access.privateKeyName ?? null,
              privateKeyPersisted: access.privateKeyPersisted ?? null
            })
          }
        : undefined
    })
    return { credentials, access }
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

  ipcMain.handle('subscription:fetch', async (_e, serverId: string) => {
    const server = store.get(serverId)
    if (!server) throw new Error('Сервер не найден')
    const keys = await fetchSubscription(server.subscriptionUrl)
    store.updateKeys(serverId, keys)
    return { serverId, subscriptionUrl: server.subscriptionUrl, keys }
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
    emitStep('ssh')
    const target = { host: payload.host, port: payload.port }
    const { credentials, access } = await credentialsFor(null, target, payload.access)
    emitStep('inspect')
    const inspector = new ServerInspector(credentials, async (url) => {
      emitStep('subscription')
      return fetchSubscription(url)
    })
    const result = await inspector.inspect()
    emitStep('save')

    const connection: ServerConnectionMetadata = {
      username: access.username,
      authMethod: access.authMethod,
      privilegeMode: access.privilegeMode,
      privateKeyPath: access.privateKeyPersisted ? null : access.privateKeyPath ?? null,
      privateKeyCredentialId: access.privateKeyCredentialId ?? null,
      privateKeyName: access.privateKeyName ?? null,
      privateKeyPersisted: access.privateKeyPersisted ?? null
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
    async (_e, serverId: string, access: SshAccessInput): Promise<ServerMaintenanceResult> => {
      return (await serverManagerFor(serverId, access)).update()
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
