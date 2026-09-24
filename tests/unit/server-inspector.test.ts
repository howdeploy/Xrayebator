import { describe, expect, it } from 'vitest'
import type { InspectionSnapshot, VlessLink } from '../../src/shared/types'
import {
  maskSubscriptionUrl,
  normalizeInspection,
  subscriptionProbeTarget
} from '../../src/main/core/server-inspector'

const baseInspection: InspectionSnapshot = {
  ok: true,
  recognized: true,
  os: 'Debian GNU/Linux 12',
  manager: 'detected',
  xray: 'running',
  profiles: 'available',
  profile_count: 1,
  route_count: 7,
  subscription_installed: true,
  subscription_mode: 'ip_tls',
  subscription_domain: '203.0.113.10',
  subscription_port: 8443,
  subscription_url: 'https://203.0.113.10:8443/sub/token',
  country: 'Germany',
  city: 'Frankfurt',
  flag: 'DE'
}

const routes: VlessLink[] = [{ name: 'route', url: 'vless://x', transport: 'xhttp' }]

describe('normalizeInspection', () => {
  it('normalizes a ready public installation', () => {
    const result = normalizeInspection(baseInspection, routes)
    expect(result.setupStatus).toBe('ready')
    expect(result.subscriptionUrl).toBe('https://203.0.113.10:8443/sub/token')
    expect(result.keys).toHaveLength(1)
    expect(result.routesCount).toBe(1)
    expect(result.diagnostics.subscription).toBe('public')
    expect(result.diagnostics.manager).toBe('detected')
    expect(result.os).toBe('Debian GNU/Linux 12')
    expect(result.country).toBe('Germany')
  })

  it('does not treat local-only URLs as working subscriptions', () => {
    const result = normalizeInspection(
      {
        ...baseInspection,
        subscription_mode: 'local_only',
        subscription_url: 'http://127.0.0.1:8080/sub/token'
      },
      null
    )
    expect(result.setupStatus).toBe('partial')
    expect(result.subscriptionUrl).toBe('')
    expect(result.keys).toEqual([])
    expect(result.diagnostics.subscription).toBe('localOnly')
  })

  it('keeps import successful but partial when the public URL is unreachable', () => {
    const result = normalizeInspection(baseInspection, 'unreachable')
    expect(result.setupStatus).toBe('partial')
    expect(result.subscriptionUrl).toBe('https://203.0.113.10:8443/sub/token')
    expect(result.keys).toEqual([])
    expect(result.diagnostics.subscription).toBe('unreachable')
  })

  it('reports partial for stopped Xray or empty profiles', () => {
    expect(
      normalizeInspection({ ...baseInspection, xray: 'stopped' }, routes).setupStatus
    ).toBe('partial')
    expect(
      normalizeInspection({ ...baseInspection, profiles: 'empty', profile_count: 0 }, routes)
        .setupStatus
    ).toBe('partial')
  })

  it('refuses to import unrecognized installations', () => {
    expect(() =>
      normalizeInspection(
        { ...baseInspection, recognized: false, manager: 'missing' },
        null
      )
    ).toThrow()
  })

  it('masks the subscription token before the URL can reach any console', () => {
    expect(maskSubscriptionUrl('https://203.0.113.10:8443/sub/0123456789abcdef0123456789abcdef')).toBe(
      'https://203.0.113.10:8443/sub/0123…cdef'
    )
    // без токена в URL — без изменений
    expect(maskSubscriptionUrl('https://example.com')).toBe('https://example.com')
  })

  it('skips probing without a public URL', () => {
    expect(
      subscriptionProbeTarget({ ...baseInspection, subscription_url: null })
    ).toBeNull()
    expect(subscriptionProbeTarget(baseInspection)).toBe(
      'https://203.0.113.10:8443/sub/token'
    )
    expect(
      subscriptionProbeTarget({
        ...baseInspection,
        subscription_mode: 'local_only',
        subscription_url: 'http://127.0.0.1:8080/sub/token'
      })
    ).toBeNull()
  })
})
