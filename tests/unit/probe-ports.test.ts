import { describe, expect, it } from 'vitest'
import type { Server } from '../../src/shared/types'
import { probePortsFor } from '../../src/main/core/probe-ports'

function makeServer(overrides: Partial<Server> = {}): Server {
  return {
    id: 'srv',
    name: 'test',
    host: '1.2.3.4',
    port: 22,
    username: 'root',
    keys: [],
    subscriptionUrl: '',
    createdAt: '2026-01-01',
    ...overrides
  }
}

describe('probePortsFor', () => {
  it('собирает уникальные порты из vless-ключей', () => {
    const server = makeServer({
      keys: [
        { name: 'a', url: 'vless://uuid@1.2.3.4:49983?type=tcp#A', transport: 'tcp' },
        { name: 'b', url: 'vless://uuid@1.2.3.4:50311?type=tcp#B', transport: 'tcp' },
        { name: 'c', url: 'vless://uuid@1.2.3.4:49983?type=tcp#C', transport: 'tcp' }
      ]
    })
    expect(probePortsFor(server)).toEqual([49983, 50311])
  })

  it('добавляет порт из subscriptionUrl', () => {
    const server = makeServer({
      keys: [{ name: 'a', url: 'vless://uuid@1.2.3.4:49983?type=tcp#A', transport: 'tcp' }],
      subscriptionUrl: 'https://1.2.3.4:8443/sub/token'
    })
    expect(probePortsFor(server)).toEqual([49983, 8443])
  })

  it('использует порт из subscriptionUrl, если ключи пустые', () => {
    const server = makeServer({
      subscriptionUrl: 'https://1.2.3.4:8443/sub/token'
    })
    expect(probePortsFor(server)).toEqual([8443])
  })

  it('фолбэк на 443, когда нет никаких портов', () => {
    expect(probePortsFor(makeServer())).toEqual([443])
  })
})