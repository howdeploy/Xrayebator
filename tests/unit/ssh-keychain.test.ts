import { describe, expect, it, vi } from 'vitest'
import type { KeychainApi } from '../../src/main/core/ssh-keychain'
import { createSshKeychain, createSshPasswordStore } from '../../src/main/core/ssh-keychain'

function mockApi(overrides: Partial<KeychainApi> = {}): KeychainApi {
  return {
    setPassword: vi.fn().mockResolvedValue(undefined),
    getPassword: vi.fn().mockResolvedValue(null),
    deletePassword: vi.fn().mockResolvedValue(true),
    ...overrides
  }
}

describe('SSH keychain', () => {
  it('saves a key as base64 and returns a fresh Buffer on load', async () => {
    const key = Buffer.from('-----BEGIN OPENSSH PRIVATE KEY-----\nsecret\n')
    const api = mockApi({
      getPassword: vi.fn().mockResolvedValue(key.toString('base64'))
    })
    const keychain = createSshKeychain(api)

    await keychain.save('credential_12345678', key)
    const loaded = await keychain.load('credential_12345678')

    expect(api.setPassword).toHaveBeenCalledWith(
      'com.xrayebator.gui.ssh-key',
      'credential_12345678',
      key.toString('base64')
    )
    expect(loaded?.toString()).toBe(key.toString())
    expect(loaded).not.toBe(key)
    expect(key.toString()).toContain('OPENSSH PRIVATE KEY')
  })

  it('rejects an oversized key before writing it to the OS keychain', async () => {
    const api = mockApi()
    const keychain = createSshKeychain(api)

    await expect(keychain.save('credential_12345678', Buffer.alloc(1024 * 1024 + 1))).rejects.toThrow(
      'слишком большой'
    )
    expect(api.setPassword).not.toHaveBeenCalled()
  })

  it('rejects malformed or oversized data returned by the keychain', async () => {
    const malformed = mockApi({ getPassword: vi.fn().mockResolvedValue('not base64!') })
    const keychain = createSshKeychain(malformed)
    await expect(keychain.load('credential_12345678')).rejects.toThrow('повреждён')

    const oversizedValue = Buffer.alloc(1024 * 1024 + 1).toString('base64')
    const oversized = mockApi({ getPassword: vi.fn().mockResolvedValue(oversizedValue) })
    await expect(createSshKeychain(oversized).load('credential_12345678')).rejects.toThrow(
      'слишком большой'
    )
  })

  it('returns null for a missing item and removes only the requested item', async () => {
    const api = mockApi({
      getPassword: vi.fn().mockResolvedValue(null),
      deletePassword: vi.fn().mockResolvedValue(true)
    })
    const keychain = createSshKeychain(api)

    await expect(keychain.load('credential_12345678')).resolves.toBeNull()
    await keychain.remove('credential_12345678')

    expect(api.deletePassword).toHaveBeenCalledWith(
      'com.xrayebator.gui.ssh-key',
      'credential_12345678'
    )
  })

  it('rejects malformed credential IDs and propagates keychain errors', async () => {
    const api = mockApi({ setPassword: vi.fn().mockRejectedValue(new Error('keychain locked')) })
    const keychain = createSshKeychain(api)

    await expect(keychain.load('../bad')).rejects.toThrow('идентификатор')
    await expect(keychain.save('credential_12345678', Buffer.from('key'))).rejects.toThrow(
      'keychain locked'
    )
  })
})

describe('SSH password store', () => {
  it('stores and reloads only the SSH password in a separate keychain namespace', async () => {
    const entries = new Map<string, string>()
    const api = mockApi({
      setPassword: vi.fn(async (service, account, value) => {
        entries.set(`${service}:${account}`, value)
      }),
      getPassword: vi.fn(async (service, account) => entries.get(`${service}:${account}`) ?? null)
    })
    const store = createSshPasswordStore(api)

    await store.save('password_12345678', 's3cret')
    const loaded = await store.load('password_12345678')

    expect(api.setPassword).toHaveBeenCalledWith(
      'com.xrayebator.gui.ssh-password',
      'password_12345678',
      's3cret'
    )
    expect(loaded).toBe('s3cret')
  })

  it('rejects line breaks but allows ordinary r and n characters', async () => {
    const api = mockApi()
    const store = createSshPasswordStore(api)
    await expect(store.save('password_12345678', 'spring')).resolves.toBeUndefined()
    await expect(store.save('password_12345678', 'line1\nline2')).rejects.toThrow('перевод строки')
  })

  it('ignores an empty password and removes only the requested item', async () => {
    const api = mockApi({ deletePassword: vi.fn().mockResolvedValue(true) })
    const store = createSshPasswordStore(api)

    await store.save('password_12345678', '')
    expect(api.setPassword).not.toHaveBeenCalled()

    await store.load('password_12345678')
    expect(api.getPassword).toHaveBeenCalledWith(
      'com.xrayebator.gui.ssh-password',
      'password_12345678'
    )

    await store.remove('password_12345678')
    expect(api.deletePassword).toHaveBeenCalledWith(
      'com.xrayebator.gui.ssh-password',
      'password_12345678'
    )
  })

  it('rejects malformed credential IDs', async () => {
    const store = createSshPasswordStore(mockApi())
    await expect(store.load('../bad')).rejects.toThrow('идентификатор')
  })
})
