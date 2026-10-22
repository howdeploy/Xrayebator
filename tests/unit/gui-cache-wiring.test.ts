import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * Страж проводки кэша на странице «Ключи».
 *
 * Это НЕ поведенческий тест: поведение первого рендера проверяет
 * `server-keys-render.test.ts`, а стор — `server-store.test.ts`. Здесь закреплено
 * то, что легко откатить незаметно при рефакторинге навигации:
 *
 *  1. `App` открывает страницу сервера со СВЕЖЕЙ карточкой из стора, а не с
 *     объектом из списка, прочитанного один раз при старте. Именно из-за этого
 *     кэш сроков и бэкендов игнорировался: `profiles:list` писал в стор, а
 *     страница получала устаревшую копию, рисовалась пустой и «дорастала», когда
 *     приходил ответ SSH (жалоба 2026-10-20).
 *  2. Подпись срока берётся через кэш (`expiryFor`), а не через поиск в свежем
 *     списке профилей напрямую.
 *  3. `profiles:list` действительно персистит сроки в карточку сервера.
 */
function source(path: string): string {
  return readFileSync(resolve(process.cwd(), path), 'utf8')
}

describe('GUI wiring: server card cache', () => {
  const app = source('src/renderer/src/App.tsx')

  it('opens a server page with the card re-read from the store', () => {
    // Переход со страницы «Серверы» и из «Ключей» обязан идти через openServer,
    // который перечитывает карточку из стора перед навигацией.
    expect(app).toContain('window.api.servers.get(server.id)')
    expect(app).toContain("onOpen={(server) => void openServer(server, 'keys')}")
    expect(app).toContain("onSettings={(server) => void openServer(server, 'settings')}")
    expect(app).toContain("onEditAccess={(server) => void openServer(server, 'settings', true)}")
    expect(app).toContain("onSettings={() => void openServer(view.server, 'settings')}")
    // Ветка «Ключей» получает уже перечитанную копию, а не объект из списка.
    expect(app).toContain("if (target === 'keys') {")
    expect(app).toContain("setView({ name: 'keys', server: fresh })")
    // Исключение по делу: AddServer/ImportServer отдают объект, который main только
    // что вернул из создания/импорта — он свежий по определению (кэш пуст, потому
    // что сервер новый), перечитывать стор там нечего.
    expect(app).toContain('onDone={(server) => {')
  })

  it('resolves the expiry line through the cache, not through a direct profile lookup', () => {
    const keys = source('src/renderer/src/pages/ServerKeys.tsx')

    expect(keys).toContain('const expiryFor = (name: string)')
    expect(keys).toContain('expiryCache[name]')
    // Срок рисуется по имени профиля (для hysteria2 имя приходит из ссылки, для
    // AWG — из ключа конфига), а не по объекту профиля из свежего списка.
    expect(keys).toContain('expiryLine(name)')
    expect(keys).toContain('expiryLine(user)')
  })

  it('persists profile expiry whenever the profile list is fetched', () => {
    const ipc = source('src/main/ipc-handlers.ts')

    expect(ipc).toContain('store.updateProfileExpiry(')
    expect(ipc).toContain('profileExpiryFromProfiles(')
  })
})
