import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it, vi } from 'vitest'

/**
 * Smoke-тест рендера страницы «Ключи»: проверяет, что подпись срока профиля
 * появляется в разметке ПЕРВОГО рендера — из кэша карточки сервера, а не после
 * ответа SSH.
 *
 * Регрессия, которую он держит (жалоба 2026-10-20): срок брался только из
 * `profiles`, который приходит по SSH, поэтому до ответа сервера абзац
 * «Действует до …» отсутствовал, а потом появлялся — карточка дёргалась, дорастая
 * на строку. Эффекты в SSR не выполняются, так что тест физически не может
 * получить `profiles` из сети: если подпись есть, значит она пришла из кэша.
 */
vi.mock('react-i18next', () => ({
  useTranslation: () => ({
    t: (key: string, opts?: Record<string, unknown>) =>
      opts && 'date' in opts ? `${key}:${String(opts.date)}` : key,
    i18n: { language: 'ru' }
  })
}))

// eslint-disable-next-line import/first
import { ServerKeys } from '../../src/renderer/src/pages/ServerKeys'
// eslint-disable-next-line import/first
import type { Server } from '../../src/shared/types'

const hysteriaLink = 'hysteria2://happ:secret@203.0.113.10:443/?sni=203.0.113.10&insecure=0#happ'

const server = {
  id: 'server-1',
  name: 'vps',
  host: '203.0.113.10',
  port: 22,
  authMethod: 'password',
  privilegeMode: 'root',
  setupStatus: 'ready',
  subscriptionUrl: 'https://203.0.113.10:8443/sub/token',
  keys: [],
  hysteria2Keys: [hysteriaLink],
  awgConfs: { work: '[Interface]\nPrivateKey = x\n' },
  profileExpiry: {
    happ: { expire: 1794000000, expire_date: '2026-11-16', expire_disabled: false },
    work: { expire: 0, expire_disabled: false }
  }
} as unknown as Server

function render(): string {
  return renderToStaticMarkup(createElement(ServerKeys, { server, onBack: () => {} }))
}

describe('ServerKeys render', () => {
  it('draws the cached expiry date on the first render, without any SSH round-trip', () => {
    const html = render()

    // hysteria2-карточка: имя профиля берётся из ссылки, срок — из кэша карточки.
    expect(html).toContain('keys.backendsExpiryDate:2026-11-16')
    // AWG-карточка: у профиля без срока рисуется «Бессрочно», а не пустая строка.
    expect(html).toContain('keys.backendsExpiryNone')
  })

  it('omits the expiry line for a profile absent from the cache', () => {
    const withoutWork = {
      ...server,
      awgConfs: { stranger: '[Interface]\nPrivateKey = x\n' }
    } as unknown as Server
    const html = renderToStaticMarkup(
      createElement(ServerKeys, { server: withoutWork, onBack: () => {} })
    )

    // stranger есть только в конфигах AWG, срока для него нет ни в кэше, ни в
    // списке профилей — «Бессрочно» тут было бы выдумкой.
    expect(html).toContain('AMNEZIAWG')
    expect(html).not.toContain('keys.backendsExpiryNone')
  })
})
