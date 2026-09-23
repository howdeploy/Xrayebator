import { describe, expect, it } from 'vitest'
import { buildDeployPayload, isDeployReady } from '../../src/renderer/src/pages/deploy-readiness'
import type { SshAccessInput } from '../../src/shared/types'

const readyAccess: SshAccessInput = {
  username: 'root',
  authMethod: 'password',
  password: 'secret',
  privilegeMode: 'root'
}

describe('deploy readiness', () => {
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

  it('omits the email from the payload in without mode', () => {
    const payload = buildDeployPayload(
      { host: ' vps.example ', port: '2222', emailMode: 'without', email: 'leftover@x.io' },
      readyAccess
    )
    expect(payload).toMatchObject({ host: 'vps.example', port: 2222, emailMode: 'without' })
    expect(payload.email).toBeUndefined()
  })
})
