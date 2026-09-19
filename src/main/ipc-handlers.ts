import { ipcMain, BrowserWindow, dialog } from 'electron'
import net from 'node:net'
import { basename, resolve } from 'node:path'
import type {
  ProfileCreateInput,
  ProfileFingerprintInput,
  ProfilePortInput,
  ProfileSniInput,
  Server,
  ServerMaintenanceResult,
  SshAccessInput
} from '@shared/types'
import type { ServerStore } from './core/servers'
import { Deployer } from './core/deployer'
import { fetchSubscription } from './core/subscription'
import { ProfileManager } from './core/profiles'
import { ServerManager } from './core/server-manager'
import { probePortsFor } from './core/probe-ports'
import { createSshCredentials, normalizeSshAccess } from './core/ssh-access'
import type { SshCredentials } from './core/ssh-client'

interface IpcContext {
  store: ServerStore
}

export function registerIpcHandlers({ store }: IpcContext): void {
  const approvedPrivateKeyPaths = new Set<string>()
  for (const server of store.list()) {
    if (server.privateKeyPath) approvedPrivateKeyPaths.add(resolve(server.privateKeyPath))
  }

  ipcMain.handle('ssh:selectPrivateKey', async () => {
    const selection = await dialog.showOpenDialog({
      title: 'Выберите приватный SSH-ключ',
      properties: ['openFile', 'dontAddToRecent']
    })
    if (selection.canceled || selection.filePaths.length === 0) return null
    const path = resolve(selection.filePaths[0])
    approvedPrivateKeyPaths.add(path)
    return { path, name: basename(path) }
  })

  const credentialsFor = (
    server: Pick<Server, 'id' | 'host' | 'port' | 'privateKeyPath' | 'hostKeyFingerprint'> | null,
    target: { host: string; port: number },
    accessInput: SshAccessInput
  ): { credentials: SshCredentials; access: SshAccessInput } => {
    if (!accessInput || typeof accessInput !== 'object') {
      throw new Error('Не указаны параметры SSH-доступа')
    }
    const access = normalizeSshAccess(accessInput, server?.privateKeyPath)
    const expectedHostKey =
      store.getHostKey(target.host, target.port) ?? server?.hostKeyFingerprint ?? undefined
    const credentials = createSshCredentials(target, access, {
      approvedPrivateKeyPaths,
      expectedHostKeyFingerprint: expectedHostKey,
      fallbackPrivateKeyPath: server?.privateKeyPath,
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
              privateKeyPath: access.privateKeyPath ?? null
            })
          }
        : undefined
    })
    return { credentials, access }
  }

  ipcMain.handle('servers:list', (): Server[] => store.list())
  ipcMain.handle('servers:get', (_e, id: string): Server | null => store.get(id) ?? null)
  ipcMain.handle('servers:remove', (_e, id: string): void => {
    const server = store.get(id)
    if (!server || !store.remove(id)) return
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
        const { credentials, access } = credentialsFor(null, target, payload.access)
        const result = await deployer.deploy({
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
          privateKeyPath: access.privateKeyPath ?? null,
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

  const profileManagerFor = (serverId: string, access: SshAccessInput): ProfileManager => {
    const server = store.get(serverId)
    if (!server) throw new Error('Сервер не найден')
    const { credentials } = credentialsFor(server, server, access)
    return new ProfileManager(credentials)
  }

  ipcMain.handle('profiles:list', async (_e, serverId: string, access: SshAccessInput) => {
    const manager = profileManagerFor(serverId, access)
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
      const manager = profileManagerFor(serverId, access)
      return manager.create(input)
    }
  )

  ipcMain.handle(
    'profiles:remove',
    async (_e, serverId: string, access: SshAccessInput, name: string) => {
      const manager = profileManagerFor(serverId, access)
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
      const manager = profileManagerFor(serverId, access)
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
      const manager = profileManagerFor(serverId, access)
      return manager.changeSni(input)
    }
  )

  ipcMain.handle('profiles:sniList', async (_e, serverId: string, access: SshAccessInput) => {
    const manager = profileManagerFor(serverId, access)
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
      const manager = profileManagerFor(serverId, access)
      return manager.changePort(input)
    }
  )

  const serverManagerFor = (serverId: string, access: SshAccessInput): ServerManager => {
    const server = store.get(serverId)
    if (!server) throw new Error('Сервер не найден')
    const { credentials } = credentialsFor(server, server, access)
    return new ServerManager(credentials)
  }

  ipcMain.handle(
    'server:update',
    async (_e, serverId: string, access: SshAccessInput): Promise<ServerMaintenanceResult> => {
      return serverManagerFor(serverId, access).update()
    }
  )

  ipcMain.handle(
    'server:uninstall',
    async (_e, serverId: string, access: SshAccessInput): Promise<ServerMaintenanceResult> => {
      return serverManagerFor(serverId, access).uninstall()
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
