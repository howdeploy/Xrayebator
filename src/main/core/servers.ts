import Store from 'electron-store'
import { randomUUID } from 'node:crypto'
import type { Server, SshAuthMethod, SshPrivilegeMode, VlessLink } from '@shared/types'

interface StoredServer extends Omit<Server, 'id' | 'createdAt'> {
  id: string
  createdAt: string
}

interface ServersSchema {
  servers: StoredServer[]
  hostKeys: Record<string, string>
}

export interface ServerConnectionMetadata {
  username: string
  authMethod: SshAuthMethod
  privilegeMode: SshPrivilegeMode
  privateKeyPath?: string | null
}

export interface ServerStore {
  list: () => StoredServer[]
  get: (id: string) => StoredServer | undefined
  add: (input: Omit<Server, 'id' | 'createdAt'>) => StoredServer
  updateKeys: (id: string, keys: VlessLink[]) => StoredServer | undefined
  updateConnection: (id: string, input: ServerConnectionMetadata) => StoredServer | undefined
  getHostKey: (host: string, port: number) => string | undefined
  trustHostKey: (host: string, port: number, fingerprint: string) => void
  forgetHostKey: (host: string, port: number) => void
  remove: (id: string) => boolean
}

function hostKeyId(host: string, port: number): string {
  return JSON.stringify([host.toLowerCase(), port])
}

function normalizeServer(server: StoredServer, hostKeys: Record<string, string>): StoredServer {
  return {
    ...server,
    authMethod: server.authMethod ?? 'password',
    privilegeMode: server.privilegeMode ?? 'root',
    privateKeyPath: server.privateKeyPath ?? null,
    hostKeyFingerprint:
      hostKeys[hostKeyId(server.host, server.port)] ?? server.hostKeyFingerprint ?? null,
    keys: server.keys ?? []
  }
}

export function createServerStore(): ServerStore {
  const store = new Store<ServersSchema>({
    name: 'xrayebator',
    defaults: { servers: [], hostKeys: {} }
  })

  return {
    list(): StoredServer[] {
      const hostKeys = store.get('hostKeys')
      return store.get('servers').map((server) => normalizeServer(server, hostKeys))
    },

    get(id: string): StoredServer | undefined {
      const server = store.get('servers').find((s) => s.id === id)
      return server ? normalizeServer(server, store.get('hostKeys')) : undefined
    },

    add(input: Omit<Server, 'id' | 'createdAt'>): StoredServer {
      const server = normalizeServer({
        ...input,
        id: randomUUID(),
        createdAt: new Date().toISOString(),
        keys: input.keys ?? []
      }, store.get('hostKeys'))
      store.set('servers', [...store.get('servers'), server])
      return server
    },

    updateKeys(id: string, keys: VlessLink[]): StoredServer | undefined {
      const servers = store.get('servers')
      const idx = servers.findIndex((s) => s.id === id)
      if (idx === -1) return undefined
      const updated: StoredServer = { ...servers[idx], keys }
      const next = [...servers]
      next[idx] = updated
      store.set('servers', next)
      return updated
    },

    updateConnection(id: string, input: ServerConnectionMetadata): StoredServer | undefined {
      const servers = store.get('servers')
      const idx = servers.findIndex((s) => s.id === id)
      if (idx === -1) return undefined
      const updated: StoredServer = {
        ...servers[idx],
        username: input.username,
        authMethod: input.authMethod,
        privilegeMode: input.privilegeMode,
        privateKeyPath: input.privateKeyPath ?? servers[idx].privateKeyPath ?? null
      }
      const next = [...servers]
      next[idx] = updated
      store.set('servers', next)
      return normalizeServer(updated, store.get('hostKeys'))
    },

    getHostKey(host: string, port: number): string | undefined {
      return store.get('hostKeys')[hostKeyId(host, port)]
    },

    trustHostKey(host: string, port: number, fingerprint: string): void {
      const key = hostKeyId(host, port)
      const hostKeys = store.get('hostKeys')
      const expected = hostKeys[key]
      if (expected && expected !== fingerprint) {
        throw new Error(
          `SSH host key изменился для ${host}:${port}. Ожидался ${expected}, получен ${fingerprint}.`
        )
      }
      if (!expected) store.set('hostKeys', { ...hostKeys, [key]: fingerprint })

      const servers = store.get('servers')
      let changed = false
      const next = servers.map((server) => {
        if (server.host.toLowerCase() !== host.toLowerCase() || server.port !== port) return server
        if (server.hostKeyFingerprint === fingerprint) return server
        changed = true
        return { ...server, hostKeyFingerprint: fingerprint }
      })
      if (changed) store.set('servers', next)
    },

    forgetHostKey(host: string, port: number): void {
      const key = hostKeyId(host, port)
      const hostKeys = { ...store.get('hostKeys') }
      delete hostKeys[key]
      store.set('hostKeys', hostKeys)

      const servers = store.get('servers')
      const next = servers.map((server) =>
        server.host.toLowerCase() === host.toLowerCase() && server.port === port
          ? { ...server, hostKeyFingerprint: null }
          : server
      )
      store.set('servers', next)
    },

    remove(id: string): boolean {
      const servers = store.get('servers')
      const next = servers.filter((s) => s.id !== id)
      if (next.length === servers.length) return false
      store.set('servers', next)
      return true
    }
  }
}
