import { describe, expect, it } from 'vitest'
import {
  parseAwgConf,
  parseBackendStatus
} from '../../src/main/core/backend-manager'

describe('parseBackendStatus', () => {
  it('разбирает полный статус с обоими бэкендами и флагами 3.1', () => {
    const raw = JSON.stringify({
      ok: true,
      backends: {
        hysteria2: {
          installed: true,
          state: 'active',
          version: 'v2.12.3',
          port: 443,
          unit: 'hysteria-server.service',
          tls_mode: 'le 2.26.125.147',
          sni: '2.26.125.147',
          masquerade: '404',
          obfs: false,
          sub_body: true
        },
        awg: {
          installed: true,
          state: 'active',
          version: 'kernel-dkms',
          port: 45467,
          unit: 'awg-quick@awg0.service',
          subnet: '10.8.1.0/24',
          mtu: 1280,
          iface: 'ens3',
          sub_body: false,
          three_enabled: true,
          disable_cookies: false
        }
      }
    })
    const result = parseBackendStatus(raw)
    expect(result.ok).toBe(true)
    expect(result.backends.hysteria2?.state).toBe('active')
    expect(result.backends.hysteria2?.port).toBe(443)
    expect(result.backends.hysteria2?.sub_body).toBe(true)
    expect(result.backends.awg?.three_enabled).toBe(true)
    expect(result.backends.awg?.disable_cookies).toBe(false)
    expect(result.backends.awg?.port).toBe(45467)
  })

  it('пустой реестр — ok=true, backends пуст, бэкенды не установлены', () => {
    const result = parseBackendStatus('{"ok":true,"backends":{}}')
    expect(result.ok).toBe(true)
    expect(Object.keys(result.backends)).toHaveLength(0)
    expect(result.backends.hysteria2).toBeUndefined()
  })

  it('вычищает ANSI-статусы перед JSON (CLI печатает цветные статусы)', () => {
    const raw =
      '\u001b[0;36m  → Порт 443/udp открыт\u001b[0m\n' +
      '{"ok":true,"backends":{"hysteria2":{"installed":true,"state":"active"}}}'
    const result = parseBackendStatus(raw)
    expect(result.ok).toBe(true)
    expect(result.backends.hysteria2?.installed).toBe(true)
  })

  it('ошибка реестра — ok=false и error сохраняется', () => {
    const result = parseBackendStatus(
      '{"ok":false,"error":"registry_init_failed","backends":{}}'
    )
    expect(result.ok).toBe(false)
    expect(result.error).toBe('registry_init_failed')
  })

  it('некорректный JSON бросает ошибку (extractJson контракт)', () => {
    expect(() => parseBackendStatus('вышла ошибка без json')).toThrow()
  })
})

describe('parseAwgConf', () => {
  it('разбирает клиентский .conf с 3.1-ключами', () => {
    const conf = [
      '[Interface]',
      'PrivateKey = CLIENTPRIV=',
      'Address = 10.8.1.2/32',
      'MTU = 1280',
      'S3 = 37',
      'S4 = 28',
      'HeaderProtectionKey = k0Y0I/kkRqj/2ORku3BPD2b2PRMF2c8VnpPVNo4MPn8=',
      'RandomTrailers = on',
      '',
      '[Peer]',
      'PublicKey = SERVERPUB=',
      'AllowedIPs = 0.0.0.0/0, ::/0',
      'Endpoint = 2.26.125.147:45467',
      'PersistentKeepalive = 25'
    ].join('\n')
    const raw = JSON.stringify({ ok: true, name: 'happ', conf })
    const result = parseAwgConf(raw)
    expect(result.ok).toBe(true)
    expect(result.name).toBe('happ')
    expect(result.conf).toContain('HeaderProtectionKey = ')
    expect(result.conf).toContain('RandomTrailers = on')
    expect(result.conf).toContain('Endpoint = 2.26.125.147:45467')
  })

  it('отсутствие гранта — ok=false с сообщением сервера', () => {
    const raw = JSON.stringify({
      ok: false,
      error: 'Нет peer-гранта AWG для профиля happ'
    })
    const result = parseAwgConf(raw)
    expect(result.ok).toBe(false)
    expect(result.conf).toBeUndefined()
    expect(result.error).toContain('peer-гранта')
  })
})
