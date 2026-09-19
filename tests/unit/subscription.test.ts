import { describe, expect, it } from 'vitest'
import {
  parseVlessLine,
  parseSubscription,
  fetchSubscription
} from '../../src/main/core/subscription'

describe('parseVlessLine', () => {
  it('парсит tcp vless-ссылку', () => {
    const link = parseVlessLine(
      'vless://abc123@185.23.45.6:443?type=tcp&security=reality#Frankfurt'
    )
    expect(link).not.toBeNull()
    expect(link!.transport).toBe('tcp')
    expect(link!.name).toBe('Frankfurt')
    expect(link!.url).toContain('vless://')
  })

  it('распознаёт grpc транспорт', () => {
    const link = parseVlessLine(
      'vless://abc123@host:443?type=grpc&serviceName=test#GRPC'
    )
    expect(link!.transport).toBe('grpc')
  })

  it('распознаёт xhttp транспорт', () => {
    const link = parseVlessLine(
      'vless://abc123@host:443?type=xhttp&path=/x#XHTTP'
    )
    expect(link!.transport).toBe('xhttp')
  })

  it('возвращает null для не-vless строки', () => {
    expect(parseVlessLine('vmess://abc')).toBeNull()
  })

  it('декодирует кириллическое имя из фрагмента', () => {
    const name = encodeURIComponent('Москва')
    const link = parseVlessLine(`vless://a@h:443?type=tcp#${name}`)
    expect(link!.name).toBe('Москва')
  })

  it('сохраняет региональный флаг в начале имени (HAPP рисует кружок флага)', () => {
    const name = encodeURIComponent('🇱🇻 Latvia · happ-tcp-xudp')
    const link = parseVlessLine(`vless://a@h:443?type=tcp#${name}`)
    expect(link!.name.startsWith('🇱🇻')).toBe(true)
    expect(link!.name).toBe('🇱🇻 Latvia · happ-tcp-xudp')
  })
})

describe('parseSubscription', () => {
  it('разбирает списки vless-строк', () => {
    const body = [
      'vless://a@h1:443?type=tcp#One',
      'vless://b@h2:443?type=grpc#Two',
      ''
    ].join('\n')
    const links = parseSubscription(body)
    expect(links).toHaveLength(2)
    expect(links.map((l) => l.transport)).toEqual(['tcp', 'grpc'])
  })

  it('декодирует base64-блок', () => {
    const inner = 'vless://a@h1:443?type=tcp#A\nvless://b@h2:443?type=xhttp#B'
    const base64 = Buffer.from(inner).toString('base64')
    const links = parseSubscription(base64)
    expect(links).toHaveLength(2)
  })
})

describe('fetchSubscription', () => {
  it('бросает ошибку при HTTP-ошибке', async () => {
    const url = 'https://example.invalid/sub'
    await expect(fetchSubscription(url, 500)).rejects.toThrow()
  })
})
