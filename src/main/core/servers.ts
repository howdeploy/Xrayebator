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
  privateKeyCredentialId?: string | null
  privateKeyName?: string | null
  privateKeyPersisted?: boolean | null
  passwordCredentialId?: string | null
  passwordPersisted?: boolean | null
}

export interface ServerStore {
  list: () => StoredServer[]
  get: (id: string) => StoredServer | undefined
  findByEndpoint: (host: string, port: number) => StoredServer | undefined
  add: (input: Omit<Server, 'id' | 'createdAt'>) => StoredServer
  upsertImported: (
    input: Omit<Server, 'id' | 'createdAt'>,
    connection: ServerConnectionMetadata
  ) => StoredServer
  updateKeys: (id: string, keys: VlessLink[]) => StoredServer | undefined
  updateConnection: (id: string, input: ServerConnectionMetadata) => StoredServer | undefined
  countCredentialReferences: (credentialId: string, exceptId?: string) => number
  clearCredentialReference: (id: string) => StoredServer | undefined
  countPasswordCredentialReferences: (credentialId: string, exceptId?: string) => number
  clearPasswordCredentialReference: (id: string) => StoredServer | undefined
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
    privateKeyName: server.privateKeyName ?? null,
    privateKeyCredentialId: server.privateKeyCredentialId ?? null,
    privateKeyPersisted: server.privateKeyPersisted ?? null,
    passwordCredentialId: server.passwordCredentialId ?? null,
    passwordPersisted: server.passwordPersisted ?? null,
    setupStatus: server.setupStatus ?? (server.subscriptionUrl ? 'ready' : 'unknown'),
    diagnostics: server.diagnostics ?? null,
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

    findByEndpoint(host: string, port: number): StoredServer | undefined {
      const server = store.get('servers').find(
        (candidate) => candidate.host.toLowerCase() === host.toLowerCase() && candidate.port === port
      )
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

    upsertImported(
      input: Omit<Server, 'id' | 'createdAt'>,
      connection: ServerConnectionMetadata
    ): StoredServer {
      const servers = store.get('servers')
      const index = servers.findIndex(
        (candidate) =>
          candidate.host.toLowerCase() === input.host.toLowerCase() && candidate.port === input.port
      )
      const existing = index >= 0 ? servers[index] : undefined
      const existingNormalized = existing
        ? normalizeServer(existing, store.get('hostKeys'))
        : undefined
      const imported: StoredServer = normalizeServer({
        ...input,
        name: input.name || existing?.name || input.host,
        username: connection.username,
        authMethod: connection.authMethod,
        privilegeMode: connection.privilegeMode,
        privateKeyPath:
          connection.privateKeyPath !== undefined
            ? connection.privateKeyPath
            : existing?.privateKeyPath ?? null,
        privateKeyName: connection.privateKeyName ?? existing?.privateKeyName ?? null,
        privateKeyPersisted: connection.privateKeyPersisted ?? existing?.privateKeyPersisted ?? null,
        privateKeyCredentialId:
          connection.privateKeyCredentialId ?? existing?.privateKeyCredentialId ?? null,
        passwordCredentialId:
          connection.passwordCredentialId ?? existing?.passwordCredentialId ?? null,
        passwordPersisted: connection.passwordPersisted ?? existing?.passwordPersisted ?? null,
        subscriptionUrl: input.subscriptionUrl || existing?.subscriptionUrl || '',
        keys: input.keys?.length ? input.keys : existing?.keys ?? [],
        routesCount: input.routesCount ?? existing?.routesCount ?? null,
        id: existing?.id ?? randomUUID(),
        createdAt: existing?.createdAt ?? new Date().toISOString(),
        hostKeyFingerprint: existingNormalized?.hostKeyFingerprint ?? input.hostKeyFingerprint ?? null
      }, store.get('hostKeys'))
      const next = [...servers]
      if (index >= 0) next[index] = imported
      else next.push(imported)
      store.set('servers', next)
      return imported
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
        privateKeyPath: input.privateKeyPath ?? servers[idx].privateKeyPath ?? null,
        privateKeyCredentialId:
          input.privateKeyCredentialId ?? servers[idx].privateKeyCredentialId ?? null,
        privateKeyName: input.privateKeyName ?? servers[idx].privateKeyName ?? null,
        privateKeyPersisted: input.privateKeyPersisted ?? servers[idx].privateKeyPersisted ?? null,
        passwordCredentialId:
          input.passwordCredentialId !== undefined
            ? input.passwordCredentialId
            : servers[idx].passwordCredentialId ?? null,
        passwordPersisted:
          input.passwordPersisted !== undefined
            ? input.passwordPersisted
            : servers[idx].passwordPersisted ?? null
      }
      const next = [...servers]
      next[idx] = updated
      store.set('servers', next)
      return normalizeServer(updated, store.get('hostKeys'))
    },

    countCredentialReferences(credentialId: string, exceptId?: string): number {
      return store
        .get('servers')
        .filter((server) => server.id !== exceptId && server.privateKeyCredentialId === credentialId)
        .length
    },

    clearCredentialReference(id: string): StoredServer | undefined {
      const servers = store.get('servers')
      const index = servers.findIndex((server) => server.id === id)
      if (index === -1) return undefined
      const updated = { ...servers[index], privateKeyCredentialId: null }
      const next = [...servers]
      next[index] = updated
      store.set('servers', next)
      return normalizeServer(updated, store.get('hostKeys'))
    },

    countPasswordCredentialReferences(credentialId: string, exceptId?: string): number {
      return store
        .get('servers')
        .filter((server) => server.id !== exceptId && server.passwordCredentialId === credentialId)
        .length
    },

    clearPasswordCredentialReference(id: string): StoredServer | undefined {
      const servers = store.get('servers')
      const index = servers.findIndex((server) => server.id === id)
      if (index === -1) return undefined
      const updated = { ...servers[index], passwordCredentialId: null, passwordPersisted: null }
      const next = [...servers]
      next[index] = updated
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
