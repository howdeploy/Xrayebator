import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { createSshCredentials } from '../../src/main/core/ssh-access'
import { formatHostKeyFingerprint } from '../../src/main/core/ssh-client'

const temporaryDirectories: string[] = []

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) {
    rmSync(directory, { recursive: true, force: true })
  }
})

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

  it('форматирует sha256 host key как OpenSSH fingerprint', () => {
    expect(formatHostKeyFingerprint('00'.repeat(32))).toBe(
      `SHA256:${Buffer.alloc(32).toString('base64').replace(/=+$/, '')}`
    )
  })
})
