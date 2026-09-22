import { describe, expect, it } from 'vitest'
import type {
  ImportServerPayload,
  ServerDiagnostics
} from '../../src/shared/types'

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

describe('shared onboarding contracts', () => {
  it('accepts diagnostics and import fixtures', () => {
    expect(importPayload.access.authMethod).toBe('privateKey')
    expect(partialDiagnostics.subscription).toBe('unreachable')
  })
})
