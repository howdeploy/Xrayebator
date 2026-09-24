import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  createSshCredentials,
  resolvePrivateKey,
  resolveStoredSshPassword
} from '../../src/main/core/ssh-access'
import { formatHostKeyFingerprint } from '../../src/main/core/ssh-client'
import type { Server } from '../../src/shared/types'

const temporaryDirectories: string[] = []

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) {
    rmSync(directory, { recursive: true, force: true })
  }
})

const storedServer: Server = {
  id: 'server-1',
  name: 'server.example',
  host: 'server.example',
  port: 22,
  username: 'root',
  os: null,
  country: null,
  city: null,
  flag: null,
  createdAt: '2026-09-23T00:00:00.000Z',
  routesCount: null,
  subscriptionUrl: '',
  keys: [],
  privateKeyCredentialId: 'stored_credential_1234',
  privateKeyPath: null
}

const emptyKeychain = {
  save: async () => {},
  load: async () => null,
  remove: async () => {}
}

describe('SSH access', () => {
  it('использует SSH-пароль как sudo-пароль по умолчанию', () => {
    const credentials = createSshCredentials(
      { host: '203.0.113.10', port: 22 },
      {
        username: 'deploy',
        authMethod: 'password',
        password: 'ssh-secret',
        privilegeMode: 'sudo'
      },
      { approvedPrivateKeyPaths: new Set() }
    )

    expect(credentials.password).toBe('ssh-secret')
    expect(credentials.sudoPassword).toBe('ssh-secret')
    expect(credentials.privateKey).toBeUndefined()
  })

  it('читает только ключ, заранее выбранный через приложение', () => {
    const directory = mkdtempSync(join(tmpdir(), 'xrayebator-key-test-'))
    temporaryDirectories.push(directory)
    const path = resolve(directory, 'id_ed25519')
    writeFileSync(path, '-----BEGIN OPENSSH PRIVATE KEY-----\ntest\n-----END OPENSSH PRIVATE KEY-----\n')

    const credentials = createSshCredentials(
      { host: 'server.example', port: 2222 },
      {
        username: 'deploy',
        authMethod: 'privateKey',
        privateKeyPath: path,
        passphrase: 'key-secret',
        privilegeMode: 'sudo'
      },
      { approvedPrivateKeyPaths: new Set([path]) }
    )

    expect(credentials.privateKey?.toString('utf8')).toContain('OPENSSH PRIVATE KEY')
    expect(credentials.passphrase).toBe('key-secret')
    expect(credentials.sudoPassword).toBeUndefined()
  })

  it('отклоняет произвольный путь к приватному ключу из renderer payload', () => {
    expect(() =>
      createSshCredentials(
        { host: 'server.example', port: 22 },
        {
          username: 'root',
          authMethod: 'privateKey',
          privateKeyPath: '/etc/passwd',
          privilegeMode: 'root'
        },
        { approvedPrivateKeyPaths: new Set() }
      )
    ).toThrow('должен быть выбран через диалог приложения')
  })

  it('не позволяет сохранить непроверенный путь через парольный режим', () => {
    expect(() =>
      createSshCredentials(
        { host: 'server.example', port: 22 },
        {
          username: 'root',
          authMethod: 'password',
          password: 'secret',
          privateKeyPath: '/etc/passwd',
          privilegeMode: 'root'
        },
        { approvedPrivateKeyPaths: new Set() }
      )
    ).toThrow('должен быть выбран через диалог приложения')
  })

  it('resolves a selected key from keychain without a path', async () => {
    const key = Buffer.from('private-key')
    const keychain = { ...emptyKeychain, load: vi.fn().mockResolvedValue(key) }
    const resolved = await resolvePrivateKey(
      {
        username: 'root',
        authMethod: 'privateKey',
        privateKeyCredentialId: 'current_credential_1234',
        privilegeMode: 'root'
      },
      storedServer,
      new Set(),
      keychain
    )

    expect(resolved.privateKey).toEqual(key)
    expect(keychain.load).toHaveBeenCalledWith('current_credential_1234')
  })

  it('falls back to the saved key reference but rejects an arbitrary path', async () => {
    const key = Buffer.from('private-key')
    const keychain = { ...emptyKeychain, load: vi.fn().mockResolvedValue(key) }
    const resolved = await resolvePrivateKey(
      {
        username: 'root',
        authMethod: 'privateKey',
        privilegeMode: 'root'
      },
      storedServer,
      new Set(),
      keychain
    )
    expect(keychain.load).toHaveBeenCalledWith('stored_credential_1234')
    expect(resolved.privateKey).toEqual(key)

    await expect(
      resolvePrivateKey(
        {
          username: 'root',
          authMethod: 'privateKey',
          privateKeyPath: 'C:/private/id_ed25519',
          privilegeMode: 'root'
        },
        storedServer,
        new Set(),
        emptyKeychain
      )
    ).rejects.toThrow('выбран через диалог')
  })

  it('requires reselect when the saved credential is missing and never stores passphrase', async () => {
    const keychain = { ...emptyKeychain, load: vi.fn().mockResolvedValue(null), save: vi.fn() }
    await expect(
      resolvePrivateKey(
        {
          username: 'root',
          authMethod: 'privateKey',
          privateKeyCredentialId: 'missing_credential_1234',
          passphrase: 'one-time',
          privilegeMode: 'root'
        },
        storedServer,
        new Set(),
        keychain
      )
    ).rejects.toThrow('не найден в системном хранилище')
    expect(keychain.save).not.toHaveBeenCalled()
  })

  it('marks legacy file fallback as non-persisted and keeps approved credential reuse persisted', async () => {
    const directory = mkdtempSync(join(tmpdir(), 'xrayebator-key-fallback-'))
    temporaryDirectories.push(directory)
    const path = resolve(directory, 'id_ed25519')
    writeFileSync(path, '-----BEGIN OPENSSH PRIVATE KEY-----\ntest\n-----END OPENSSH PRIVATE KEY-----\n')

    const fallback = await resolvePrivateKey(
      {
        username: 'root',
        authMethod: 'privateKey',
        privateKeyCredentialId: 'expired_credential_123',
        privateKeyPath: path,
        privilegeMode: 'root'
      },
      null,
      new Set([path]),
      emptyKeychain
    )
    expect(fallback.privateKey?.toString()).toContain('OPENSSH PRIVATE KEY')
    expect(fallback.access.privateKeyPersisted).toBe(false)

    const reused = await resolvePrivateKey(
      {
        username: 'root',
        authMethod: 'privateKey',
        privateKeyCredentialId: 'stored_credential_1234',
        privilegeMode: 'root'
      },
      storedServer,
      new Set(),
      { ...emptyKeychain, load: vi.fn().mockResolvedValue(Buffer.from('key')) }
    )
    expect(reused.access.privateKeyPersisted).toBe(true)
  })

  it('formats sha256 host key as OpenSSH fingerprint', () => {
    expect(formatHostKeyFingerprint('00'.repeat(32))).toBe(
      `SHA256:${Buffer.alloc(32).toString('base64').replace(/=+$/, '')}`
    )
  })

  it('loads the saved SSH password when the form is empty', async () => {
    const passwordStore = { load: vi.fn().mockResolvedValue('saved-secret') }
    const access = await resolveStoredSshPassword(
      { username: 'root', authMethod: 'password', privilegeMode: 'root' },
      { ...storedServer, passwordCredentialId: 'password_credential_1234' },
      passwordStore
    )
    expect(passwordStore.load).toHaveBeenCalledWith('password_credential_1234')
    expect(access.password).toBe('saved-secret')
    expect(access.passwordPersisted).toBe(true)
  })

  it('prefers a newly entered SSH password over a saved credential', async () => {
    const passwordStore = { load: vi.fn().mockResolvedValue('old-secret') }
    const access = await resolveStoredSshPassword(
      {
        username: 'root',
        authMethod: 'password',
        password: 'new-secret',
        privilegeMode: 'root'
      },
      { ...storedServer, passwordCredentialId: 'password_credential_1234' },
      passwordStore
    )
    expect(passwordStore.load).not.toHaveBeenCalled()
    expect(access.password).toBe('new-secret')
  })

  it('asks for the password again when the saved keychain entry is missing', async () => {
    const passwordStore = { load: vi.fn().mockResolvedValue(null) }
    await expect(
      resolveStoredSshPassword(
        { username: 'root', authMethod: 'password', privilegeMode: 'root' },
        { ...storedServer, passwordCredentialId: 'missing_password_1234' },
        passwordStore
      )
    ).rejects.toThrow('не найден в системном хранилище')
  })
})
