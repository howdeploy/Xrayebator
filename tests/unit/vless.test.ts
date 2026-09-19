import { describe, expect, it } from 'vitest'
import { vlessPort } from '../../src/shared/vless'

describe('vlessPort', () => {
  it('читает фактический порт из VLESS URL', () => {
    expect(vlessPort('vless://uuid@203.0.113.10:49983?type=tcp#phone')).toBe(49983)
  })

  it('поддерживает IPv6 authority', () => {
    expect(vlessPort('vless://uuid@[2001:db8::1]:8443?type=xhttp')).toBe(8443)
  })

  it('использует 443 для URL без порта или повреждённого значения', () => {
    expect(vlessPort('vless://uuid@example.com?type=tcp')).toBe(443)
    expect(vlessPort('not-a-vless-url')).toBe(443)
  })
})
