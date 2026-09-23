import { describe, expect, it } from 'vitest'
import { buildQuickstartArgs } from '../../src/main/core/deployer'

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
