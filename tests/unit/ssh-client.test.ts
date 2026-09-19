import { describe, expect, it, vi } from 'vitest'

const sshState = vi.hoisted(() => ({
  mode: 'ready' as 'ready' | 'authError',
  fingerprintHex: '11'.repeat(32)
}))

vi.mock('ssh2', async () => {
  const { EventEmitter } = await import('node:events')

  return {
    Client: class FakeClient extends EventEmitter {
      connect(config: {
        hostVerifier: (fingerprint: string) => boolean
      }): void {
        const accepted = config.hostVerifier(sshState.fingerprintHex)
        queueMicrotask(() => {
          if (!accepted) this.emit('error', new Error('Host denied'))
          else if (sshState.mode === 'authError') this.emit('error', new Error('Authentication failed'))
          else this.emit('ready')
        })
      }

      end(): void {}
    }
  }
})

import { formatHostKeyFingerprint, SshClient } from '../../src/main/core/ssh-client'

describe('SSH host key verification', () => {
  it('закрепляет fingerprint только после успешной аутентификации', async () => {
    sshState.mode = 'ready'
    const trusted = vi.fn()
    const authenticated = vi.fn()
    const client = new SshClient({
      host: 'server.example',
      port: 22,
      username: 'root',
      password: 'secret',
      privilegeMode: 'root',
      onHostKeyTrusted: trusted,
      onAuthenticated: authenticated
    })

    await client.connect()

    expect(trusted).toHaveBeenCalledWith(formatHostKeyFingerprint(sshState.fingerprintHex))
    expect(authenticated).toHaveBeenCalledOnce()
    client.close()
  })

  it('не закрепляет fingerprint, если аутентификация не завершилась', async () => {
    sshState.mode = 'authError'
    const trusted = vi.fn()
    const client = new SshClient({
      host: 'server.example',
      port: 22,
      username: 'root',
      password: 'wrong',
      privilegeMode: 'root',
      onHostKeyTrusted: trusted
    })

    await expect(client.connect()).rejects.toThrow('Authentication failed')
    expect(trusted).not.toHaveBeenCalled()
  })

  it('останавливает подключение при смене закреплённого fingerprint', async () => {
    sshState.mode = 'ready'
    const client = new SshClient({
      host: 'server.example',
      port: 22,
      username: 'root',
      password: 'secret',
      privilegeMode: 'root',
      expectedHostKeyFingerprint: formatHostKeyFingerprint('22'.repeat(32))
    })

    await expect(client.connect()).rejects.toThrow('SSH host key изменился')
  })
})
