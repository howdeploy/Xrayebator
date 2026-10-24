import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it, vi } from 'vitest'

/**
 * Smoke-тест рендера ServerSettings: до него экран проверялся только типами и
 * статикой, поэтому ошибка в разметке ловилась лишь руками в Electron.
 *
 * Эффекты в SSR не выполняются, поэтому window.api не нужен: тест проверяет именно
 * разметку первого рендера (экран подключения) и контракт панелей-разделов.
 */
vi.mock('react-i18next', () => ({
  useTranslation: () => ({
    t: (key: string) => key,
    i18n: { language: 'ru' }
  })
}))

// eslint-disable-next-line import/first
import {
  ServerPage,
  SETTINGS_SECTIONS,
  sectionPaneProps
} from '../../src/renderer/src/pages/ServerSettings'
// eslint-disable-next-line import/first
import type { Server } from '../../src/shared/types'

const server = {
  id: 'server-1',
  name: 'vps',
  host: '203.0.113.10',
  port: 22,
  authMethod: 'password',
  privilegeMode: 'root',
  setupStatus: 'ready'
} as unknown as Server

function render(mode: 'settings' | 'profiles' = 'settings'): string {
  return renderToStaticMarkup(createElement(ServerPage, { server, mode, onBack: () => {} }))
}

describe('ServerSettings render', () => {
  it('renders the connection gate without crashing', () => {
    const html = render()
    expect(html).toContain('settings.hint')
    expect(html).toContain('settings.connect')
    // До подключения навигация по разделам не нужна: она появляется в рабочем режиме.
    expect(html).not.toContain('role="tablist"')
  })

  it('renders the profiles page as its own screen with its own title', () => {
    // Список профилей переехал на отдельную страницу: у неё свой заголовок и
    // тот же гейт подключения, а вкладок-панелей до подключения нет.
    const html = render('profiles')
    expect(html).toContain('settings.listTitle')
    expect(html).not.toContain('settings.title')
    expect(html).toContain('settings.connect')
    expect(html).not.toContain('role="tablist"')
  })
})

describe('settings sections', () => {
  it('lists all three sections with distinct ids', () => {
    const ids = SETTINGS_SECTIONS.map((s) => s.id)
    // Защита SSH живёт блоком внутри «Безопасность и TLS»: это серверная настройка
    // рядом с подпиской, а отдельная вкладка под неё была бы лишним кликом.
    expect(ids).toEqual(['create', 'backends', 'subscription'])
    expect(new Set(SETTINGS_SECTIONS.map((s) => s.labelKey)).size).toBe(3)
  })

  it('hides the inactive panes instead of unmounting them', () => {
    // Контракт: панель всегда в DOM (иначе терялись бы введённые значения), неактивная
    // — скрыта атрибутом hidden и связана с вкладкой через aria.
    for (const id of ['create', 'backends', 'subscription'] as const) {
      const active = sectionPaneProps(id, id)
      expect(active.hidden).toBe(false)
      expect(active.id).toBe(`pane-${id}`)
      expect(active.role).toBe('tabpanel')
      expect(active['aria-labelledby']).toBe(`tab-${id}`)

      const inactive = sectionPaneProps(id, 'profiles')
      expect(inactive.hidden).toBe(id !== 'profiles')
    }
  })
})
