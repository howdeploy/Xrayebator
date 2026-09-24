import { describe, expect, expectTypeOf, it, vi } from 'vitest'
import type {
  DeployStartPayload,
  ElectronAPI,
  ImportServerPayload,
  PrivateKeyReference,
  Server,
  ServerDiagnostics
} from '../../src/shared/types'

const fakeStore = vi.hoisted(() => ({
  data: { servers: [] as unknown[], hostKeys: {} as Record<string, string> }
}))

vi.mock('electron-store', () => ({
  default: class FakeStore {
    constructor(options: { defaults: { servers: unknown[]; hostKeys: Record<string, string> } }) {
      fakeStore.data = {
        servers: [...options.defaults.servers],
        hostKeys: { ...options.defaults.hostKeys }
      }
    }

    get(key: 'servers' | 'hostKeys'): unknown {
      return fakeStore.data[key]
    }

    set(key: 'servers' | 'hostKeys', value: unknown): void {
      fakeStore.data[key] = value as never
    }
  }
}))

import { createServerStore } from '../../src/main/core/servers'

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

const connection = {
  username: 'root',
  authMethod: 'privateKey' as const,
  privilegeMode: 'root' as const,
  privateKeyCredentialId: 'credential_12345678',
  privateKeyName: 'id_ed25519'
}

const baseServer: Omit<Server, 'id' | 'createdAt'> = {
  name: 'initial',
  host: 'server.example',
  port: 22,
  username: 'root',
  os: 'Debian',
  country: 'Germany',
  city: 'Berlin',
  flag: '🇩🇪',
  routesCount: 1,
  subscriptionUrl: 'https://server.example/sub/token',
  keys: [{ name: 'main', url: 'vless://main', transport: 'xhttp' }],
  authMethod: 'privateKey',
  privilegeMode: 'root',
  privateKeyCredentialId: 'credential_12345678',
  privateKeyName: 'id_ed25519',
  hostKeyFingerprint: 'SHA256:original'
}

describe('server store onboarding metadata', () => {
  it('upserts imported endpoints without duplicates and preserves valid saved credentials', () => {
    const store = createServerStore()
    const initial = store.add(baseServer)
    const createdAt = initial.createdAt

    const imported = store.upsertImported({
      ...baseServer,
      name: 'renamed',
      host: 'SERVER.EXAMPLE',
      subscriptionUrl: '',
      keys: [],
      setupStatus: 'partial',
      diagnostics: partialDiagnostics
    }, connection)

    expect(imported.id).toBe(initial.id)
    expect(imported.createdAt).toBe(createdAt)
    expect(imported.name).toBe('renamed')
    expect(imported.subscriptionUrl).toBe(baseServer.subscriptionUrl)
    expect(imported.keys).toEqual(baseServer.keys)
    expect(imported.privateKeyCredentialId).toBe(baseServer.privateKeyCredentialId)
    expect(imported.hostKeyFingerprint).toBe(baseServer.hostKeyFingerprint)
    expect(store.list()).toHaveLength(1)
  })

  it('preserves a saved SSH password credential when an import has no new password', () => {
    const store = createServerStore()
    const initial = store.add({
      ...baseServer,
      passwordCredentialId: 'password_credential_1234'
    } as Omit<Server, 'id' | 'createdAt'>)

    const updated = store.upsertImported(
      { ...baseServer, subscriptionUrl: '', keys: [] },
      connection
    )

    expect(updated.id).toBe(initial.id)
    expect((updated as Server & { passwordCredentialId?: string | null }).passwordCredentialId).toBe(
      'password_credential_1234'
    )
  })

  it('clears a stale password credential when the keychain cannot persist a replacement', () => {
    const store = createServerStore()
    const initial = store.add({
      ...baseServer,
      passwordCredentialId: 'password_credential_1234',
      passwordPersisted: true
    } as Omit<Server, 'id' | 'createdAt'>)

    const updated = store.updateConnection(initial.id, {
      username: 'root',
      authMethod: 'password',
      privilegeMode: 'root',
      passwordCredentialId: null,
      passwordPersisted: false
    })

    expect(updated?.passwordCredentialId).toBeNull()
    expect(updated?.passwordPersisted).toBe(false)
  })

  it('clears a stale SSH password reference after the keychain fails to save a replacement', () => {
    const store = createServerStore()
    const initial = store.add({
      ...baseServer,
      passwordCredentialId: 'password_credential_1234',
      passwordPersisted: true
    } as Omit<Server, 'id' | 'createdAt'>)
    const updated = store.updateConnection(initial.id, {
      username: 'root',
      authMethod: 'password',
      privilegeMode: 'root',
      passwordCredentialId: null,
      passwordPersisted: false
    })

    expect(updated?.passwordCredentialId).toBeNull()
    expect(updated?.passwordPersisted).toBe(false)
  })

  it('counts shared credential references and clears only the selected server reference', () => {
    const store = createServerStore()
    const first = store.add(baseServer)
    const second = store.add({ ...baseServer, host: 'other.example' })

    expect(store.countCredentialReferences('credential_12345678')).toBe(2)
    expect(store.countCredentialReferences('credential_12345678', first.id)).toBe(1)

    store.clearCredentialReference(first.id)

    expect(store.get(first.id)?.privateKeyCredentialId).toBeNull()
    expect(store.get(second.id)?.privateKeyCredentialId).toBe('credential_12345678')
    expect(store.countCredentialReferences('credential_12345678')).toBe(1)
  })
})

describe('shared onboarding contracts', () => {
  it('accepts diagnostics and import fixtures', () => {
    expect(importPayload.access.authMethod).toBe('privateKey')
    expect(partialDiagnostics.subscription).toBe('unreachable')
  })

  it('requires an explicit email mode for deployment', () => {
    expectTypeOf<DeployStartPayload['emailMode']>().toEqualTypeOf<'provided' | 'without'>()
  })

  it('selects keys through a credential reference rather than returning file paths', () => {
    expectTypeOf<Awaited<ReturnType<ElectronAPI['ssh']['selectPrivateKey']>>>()
      .toEqualTypeOf<PrivateKeyReference | null>()
  })
})
