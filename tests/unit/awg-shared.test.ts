import { describe, expect, it } from 'vitest'
import { inflateSync } from 'node:zlib'
import {
  buildAwgVpnConfig,
  buildAwgVpnUrl,
  parseAwgClientConf,
  parseAwgConfMap,
  stripAwgComments
} from '../../src/shared/awg'

const CONF = [
  '# Xrayebator: транспорт AmneziaWG (AWG 3.1) — НЕ через V2Ray/HAPP.',
  '# Профиль: happ.',
  '[Interface]',
  'PrivateKey = PRIV=',
  'Address = 10.8.1.2/32',
  'HeaderProtectionKey = HPK=',
  '',
  '[Peer]',
  'PublicKey = SERVERPUB=',
  'Endpoint = 2.26.125.147:45467',
  'AllowedIPs = 0.0.0.0/0, ::/0'
].join('\n')

describe('stripAwgComments', () => {
  it('убирает комментарии-шапку и сохраняет секции', () => {
    const clean = stripAwgComments(CONF)
    expect(clean.startsWith('[Interface]')).toBe(true)
    expect(clean).not.toContain('# Xrayebator')
    expect(clean).toContain('[Peer]')
    expect(clean).toContain('Endpoint = 2.26.125.147:45467')
  })
})

describe('parseAwgClientConf', () => {
  it('извлекает Endpoint и Address как поля ключа', () => {
    const fields = parseAwgClientConf(CONF)
    expect(fields.endpoint).toBe('2.26.125.147:45467')
    expect(fields.address).toBe('10.8.1.2/32')
  })

  it('возвращает пустые поля для мусорного конфига', () => {
    const fields = parseAwgClientConf('мусор')
    expect(fields.endpoint).toBe('')
    expect(fields.address).toBe('')
  })
})

const FULL_CONF = [
  '[Interface]',
  'PrivateKey = PRIVKEYBASE64=',
  'Address = 10.8.1.2/32',
  'DNS = 1.1.1.1, 1.0.0.1',
  'MTU = 1280',
  'Jc = 5',
  'Jmin = 10',
  'Jmax = 50',
  'S1 = 146',
  'S2 = 120',
  'S3 = 49',
  'S4 = 12',
  'H1 = 1',
  'H2 = 2',
  'H3 = 3',
  'H4 = 4',
  'HeaderProtectionKey = HPKBASE64=',
  'RandomTrailers = on',
  '',
  '[Peer]',
  'PublicKey = SERVERPUB=',
  'PresharedKey = PSKBASE64=',
  'AllowedIPs = 0.0.0.0/0, ::/0',
  'Endpoint = 2.26.125.147:45467',
  'PersistentKeepalive = 25'
].join('\n')

describe('parseAwgConfMap', () => {
  it('разбирает key=value и пропускает секции', () => {
    const map = parseAwgConfMap(FULL_CONF)
    expect(map['Jc']).toBe('5')
    expect(map['Endpoint']).toBe('2.26.125.147:45467')
    expect(map['PresharedKey']).toBe('PSKBASE64=')
    expect(Object.keys(map).some((k) => k.startsWith('['))).toBe(false)
  })
})

describe('buildAwgVpnUrl', () => {
  it('строит сжатый vpn:// с контейнером amnezia-awg2 и полным last_config', async () => {
    const url = await buildAwgVpnUrl(FULL_CONF, 'happ', {
      clientPubKey: 'CLIENTPUB='
    })
    expect(url.startsWith('vpn://')).toBe(true)
    const payload64 = url.slice('vpn://'.length)
    expect(payload64).not.toContain('+')
    expect(payload64).not.toContain('/')
    expect(payload64.endsWith('=')).toBe(false)

    // qCompress: 4 байта BE-размера + zlib
    const raw = Buffer.from(payload64, 'base64')
    expect(raw.readUInt32BE(0)).toBeGreaterThan(0)
    const payload = JSON.parse(
      inflateSync(raw.subarray(4)).toString('utf8')
    ) as Record<string, unknown>
    expect(payload['defaultContainer']).toBe('amnezia-awg2')
    expect(payload['hostName']).toBe('2.26.125.147')
    expect(payload['dns1']).toBe('1.1.1.1')

    const containers = payload['containers'] as Array<Record<string, unknown>>
    expect(containers[0]['container']).toBe('amnezia-awg2')
    const awg = containers[0]['awg'] as Record<string, unknown>
    // серверные junk-поля дублируются на уровне awg-объекта (AwgServerConfig::toJson)
    expect(awg['Jc']).toBe('5')
    expect(awg['S1']).toBe('146')
    expect(awg['H1']).toBe('1')
    expect(awg['I1']).toBe('')
    expect(awg['protocol_version']).toBe('3.1')
    expect(awg['subnet_address']).toBe('10.8.1.0')
    expect(awg['RekeyAfterTime']).toBe('100-120')
    expect(awg['ContentPaddingAddition']).toBe('10-100')
    expect(awg['isThirdPartyConfig']).toBe(true)
    expect(awg['transport_proto']).toBe('udp')

    const last = JSON.parse(awg['last_config'] as string) as Record<string, unknown>
    expect(last['protocol_version']).toBe('3.1')
    expect(last['client_ip']).toBe('10.8.1.2')
    expect(last['client_priv_key']).toBe('PRIVKEYBASE64=')
    expect(last['client_pub_key']).toBe('CLIENTPUB=')
    expect(last['clientId']).toBe('CLIENTPUB=')
    expect(last['psk_key']).toBe('PSKBASE64=')
    expect(last['server_pub_key']).toBe('SERVERPUB=')
    expect(last['port']).toBe(45467)
    expect(last['allowed_ips']).toEqual(['0.0.0.0/0', '::/0'])
    expect(last['config']).not.toContain('#')
    expect(last['RekeyAfterTime']).toBe('100-120')
    expect(last['RandomTrailers']).toBe('on')
  })

  it('выживает кириллицу в имени профиля (UTF-8 → qCompress → base64url)', async () => {
    const url = await buildAwgVpnUrl(FULL_CONF, 'Тест-профиля')
    const raw = Buffer.from(url.slice(6), 'base64')
    const payload = JSON.parse(
      inflateSync(raw.subarray(4)).toString('utf8')
    ) as Record<string, unknown>
    expect(payload['description']).toBe('Тест-профиля')
  })

  it('всегда ставит protocol_version 3.1 и добавляет range-поля даже без HPK', async () => {
    const minimal = [
      '[Interface]',
      'PrivateKey = P=',
      'Address = 10.8.1.2/32',
      '[Peer]',
      'PublicKey = S=',
      'Endpoint = 1.2.3.4:51820'
    ].join('\n')
    const cfg = buildAwgVpnConfig(minimal)
    expect(cfg['defaultContainer']).toBe('amnezia-awg2')
    const awg = (cfg['containers'] as Array<Record<string, unknown>>)[0]['awg'] as Record<
      string,
      unknown
    >
    expect(awg['protocol_version']).toBe('3.1')
    expect(awg['RekeyAfterTime']).toBe('100-120')
    const last = JSON.parse(awg['last_config'] as string) as Record<string, unknown>
    expect(last['protocol_version']).toBe('3.1')
    expect('HeaderProtectionKey' in last).toBe(false)
  })
})
