import { describe, expect, it } from 'vitest'
import { buildQuickstartArgs } from '../../src/main/core/deployer'
import { maskSubscriptionUrl } from '../../src/main/core/server-inspector'

describe('deploy console redaction', () => {
  it('masks the subscription token before it can reach the deploy console', () => {
    const url = 'https://203.0.113.10:8443/sub/0123456789abcdef0123456789abcdef'
    const masked = maskSubscriptionUrl(url)
    // Токен — bearer credential: в консоль попадает только его начало и конец.
    expect(masked).not.toContain('0123456789abcdef0123456789abcdef')
    expect(masked).toBe('https://203.0.113.10:8443/sub/0123…cdef')
  })
})

describe('quickstart argument builder', () => {
  it('passes the email when the mode is provided', () => {
    expect(buildQuickstartArgs({ emailMode: 'provided', email: 'a@example.com' })).toEqual([
      'quickstart',
      '--email',
      'a@example.com'
    ])
  })

  it('passes --without-email when the mode is without', () => {
    expect(buildQuickstartArgs({ emailMode: 'without' })).toEqual(['quickstart', '--without-email'])
  })

  it('ignores an email payload in without mode (no fake address, no -m)', () => {
    expect(buildQuickstartArgs({ emailMode: 'without', email: 'leftover@example.com' })).toEqual([
      'quickstart',
      '--without-email'
    ])
  })

  it('rejects an empty or invalid email only in provided mode', () => {
    expect(() => buildQuickstartArgs({ emailMode: 'provided', email: '' })).toThrow(/email/i)
    expect(() => buildQuickstartArgs({ emailMode: 'provided', email: 'not-an-email' })).toThrow(
      /email/i
    )
    expect(() => buildQuickstartArgs({ emailMode: 'provided', email: 'a@b.c\nevil' })).toThrow(
      /email/i
    )
    expect(() => buildQuickstartArgs({ emailMode: 'provided' })).toThrow(/email/i)
  })
})
