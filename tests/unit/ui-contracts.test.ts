import { describe, expect, it } from 'vitest'
import { isSshAccessReady, setTypedSshPassword } from '../../src/renderer/src/components/SshAccessForm'
import { buildDeployPayload, isDeployReady } from '../../src/renderer/src/pages/deploy-readiness'
import { shouldAutoConnectServer, accessSummary } from '../../src/renderer/src/pages/server-access'
import type { SshAccessInput } from '../../src/shared/types'

const readyAccess: SshAccessInput = {
  username: 'root',
  authMethod: 'password',
  password: 'secret',
  privilegeMode: 'root'
}

describe('deploy readiness', () => {
  it('treats a keychain-backed SSH password as complete access', () => {
    expect(
      isSshAccessReady({
        username: 'root',
        authMethod: 'password',
        passwordCredentialId: 'password_credential_1234',
        privilegeMode: 'root'
      })
    ).toBe(true)
  })

  it('allows deploying without email only in the explicit without mode', () => {
    expect(
      isDeployReady({ host: 'vps', port: '22', emailMode: 'without', email: '' }, readyAccess)
    ).toBe(true)
  })

  it('requires a valid email in provided mode', () => {
    expect(
      isDeployReady({ host: 'vps', port: '22', emailMode: 'provided', email: '' }, readyAccess)
    ).toBe(false)
    expect(
      isDeployReady({ host: 'vps', port: '22', emailMode: 'provided', email: 'bad' }, readyAccess)
    ).toBe(false)
    expect(
      isDeployReady(
        { host: 'vps', port: '22', emailMode: 'provided', email: 'a@b.co' },
        readyAccess
      )
    ).toBe(true)
  })

  it('requires host and ssh access regardless of email mode', () => {
    expect(
      isDeployReady({ host: '', port: '22', emailMode: 'without', email: '' }, readyAccess)
    ).toBe(false)
    expect(
      isDeployReady(
        { host: 'vps', port: '22', emailMode: 'without', email: '' },
        { username: '', authMethod: 'password', password: 'x', privilegeMode: 'root' }
      )
    ).toBe(false)
  })

  it('marks a manually typed password as needing re-persistence', () => {
    const stored: SshAccessInput = {
      username: 'root',
      authMethod: 'password',
      passwordCredentialId: 'password_credential_1234',
      passwordPersisted: true,
      privilegeMode: 'root'
    }
    const typed = setTypedSshPassword(stored, 'fresh-pass')
    expect(typed.password).toBe('fresh-pass')
    // A hand-typed password must overwrite the keychain entry, not be skipped as "already saved".
    expect(typed.passwordPersisted).toBe(false)
    // Clearing the field falls back to the saved credential untouched.
    expect(setTypedSshPassword(stored, '').passwordPersisted).toBe(true)
  })

  it('auto-connects only when a persisted credential is available', () => {
    expect(
      shouldAutoConnectServer({
        authMethod: 'password',
        passwordCredentialId: 'password_credential_1234'
      })
    ).toBe(true)
    expect(
      shouldAutoConnectServer({
        authMethod: 'privateKey',
        privateKeyCredentialId: 'key_credential_1234',
        privateKeyPersisted: true
      })
    ).toBe(true)
    expect(
      shouldAutoConnectServer({
        authMethod: 'privateKey',
        privateKeyCredentialId: 'session_key_1234',
        privateKeyPersisted: false
      })
    ).toBe(false)
    expect(shouldAutoConnectServer({ authMethod: 'password' })).toBe(false)
  })

  it('summarizes where the saved SSH secret lives for the server card', () => {
    expect(
      accessSummary({
        username: 'root',
        host: '203.0.113.10',
        port: 22,
        authMethod: 'password',
        passwordCredentialId: 'pw1',
        passwordPersisted: true
      })
    ).toEqual({ endpoint: 'root@203.0.113.10:22', secret: 'passwordSaved' })
    expect(
      accessSummary({
        username: 'ubuntu',
        host: 'example.com',
        port: 2222,
        authMethod: 'privateKey',
        privateKeyCredentialId: 'k1',
        privateKeyPersisted: false
      })
    ).toEqual({ endpoint: 'ubuntu@example.com:2222', secret: 'sessionOnly' })
    expect(
      accessSummary({ username: 'root', host: 'h', port: 22, authMethod: 'password' })
    ).toEqual({ endpoint: 'root@h:22', secret: 'notSaved' })
    expect(
      accessSummary({
        username: 'root',
        host: 'h',
        port: 22,
        authMethod: 'privateKey',
        privateKeyCredentialId: 'k1',
        privateKeyPersisted: true
      })
    ).toEqual({ endpoint: 'root@h:22', secret: 'keySaved' })
  })

  it('omits the email from the payload in without mode', () => {
    const payload = buildDeployPayload(
      { host: ' vps.example ', port: '2222', emailMode: 'without', email: 'leftover@x.io' },
      readyAccess
    )
    expect(payload).toMatchObject({ host: 'vps.example', port: 2222, emailMode: 'without' })
    expect(payload.email).toBeUndefined()
  })

  it('keeps deploy disabled until the DNS-01 set is complete', () => {
    const base = { host: 'vps', port: '22', emailMode: 'without' as const, email: '' }
    // Тумблер включён, но домена/токена нет: сервер вернул бы ok:false уже после
    // установки Xray, поэтому кнопка обязана остаться выключенной.
    expect(isDeployReady({ ...base, dns01Enabled: true }, readyAccess)).toBe(false)
    expect(
      isDeployReady({ ...base, dns01Enabled: true, dns01Domain: 'sub.example.com' }, readyAccess)
    ).toBe(false)
    expect(
      isDeployReady(
        {
          ...base,
          dns01Enabled: true,
          dns01Domain: 'sub.example.com',
          dns01Provider: 'cloudflare',
          dns01Token: 'short'
        },
        readyAccess
      )
    ).toBe(false)
    expect(
      isDeployReady(
        {
          ...base,
          dns01Enabled: true,
          dns01Domain: 'sub.example.com',
          dns01Provider: 'route53',
          dns01AwsKeyId: 'AKIAIOSFODNN7EXAMPLE',
          dns01AwsSecret: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'
        },
        readyAccess
      )
    ).toBe(true)
  })

  it('sends pq and dns01 only when the operator opted in', () => {
    const base = { host: 'vps', port: '22', emailMode: 'without' as const, email: '' }
    const plain = buildDeployPayload(base, readyAccess)
    expect(plain.pq).toBeUndefined()
    expect(plain.dns01).toBeUndefined()

    const optedIn = buildDeployPayload(
      {
        ...base,
        pq: true,
        dns01Enabled: true,
        dns01Domain: ' sub.example.com ',
        dns01Provider: 'cloudflare',
        dns01Token: 'abcdefghijklmnopqrst'
      },
      readyAccess
    )
    expect(optedIn.pq).toBe(true)
    expect(optedIn.dns01).toEqual({
      domain: 'sub.example.com',
      provider: 'cloudflare',
      token: 'abcdefghijklmnopqrst',
      awsKeyId: '',
      awsSecret: ''
    })
  })
})
