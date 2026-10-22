import { useEffect, useState } from 'react'
import { Dashboard } from './pages/Dashboard'
import { AddServer } from './pages/AddServer'
import { ImportServer } from './pages/ImportServer'
import { ServerKeys } from './pages/ServerKeys'
import { ServerPage, type ServerPageProps, type SettingsSection } from './pages/ServerSettings'
import type { Server } from '@shared/types'

type View =
  | { name: 'dashboard' }
  | { name: 'add' }
  | { name: 'import' }
  | { name: 'keys'; server: Server }
  /**
   * Один view на оба экрана сервера. Раньше «настройки» и «профили» были
   * разными view, и переключение между ними размонтировало страницу: она
   * заново поднимала SSH-сессию и перезагружала профили. Теперь экран
   * переключается пропсом `mode`, компонент остаётся смонтированным — один
   * SSH-запрос поднимает всё, что нужно обоим экранам.
   */
  | {
      name: 'server'
      server: Server
      mode: ServerPageProps['mode']
      editingAccess?: boolean
      section?: SettingsSection
    }

export default function App(): React.JSX.Element {
  const [view, setView] = useState<View>({ name: 'dashboard' })
  const [servers, setServers] = useState<Server[]>([])

  useEffect(() => {
    window.api.servers.list().then(setServers)
  }, [])

  const upsertServer = (server: Server): void => {
    setServers((prev) => {
      const others = prev.filter((s) => s.id !== server.id)
      return [...others, server]
    })
  }

  /** Обновляет карточку на месте, не меняя порядок на дашборде. */
  const replaceServer = (server: Server): void => {
    setServers((prev) => prev.map((s) => (s.id === server.id ? server : s)))
  }

  /**
   * Переход на страницу сервера со СВЕЖЕЙ карточкой из стора.
   *
   * Стор живёт своей жизнью: `profiles:list` пишет туда кэш ключей, сроков
   * профилей и ссылок форматов, `servers.list` читался один раз при старте —
   * поэтому `servers` в состоянии отстаёт. Раньше страница получала этот
   * устаревший объект и рисовалась без кэша: подписи сроков и карточки бэкендов
   * появлялись только после ответа SSH и дёргали разметку (жалоба 2026-10-20).
   * Чтение локального стора — единицы миллисекунд, поэтому делаем его ДО
   * навигации: страница монтируется уже с полным кэшем, без «дорастания».
   */
  const openServer = async (
    server: Server,
    target: 'keys' | 'settings' | 'profiles',
    editingAccess = false
  ): Promise<void> => {
    const fresh = (await window.api.servers.get(server.id).catch(() => undefined)) ?? server
    replaceServer(fresh)
    if (target === 'keys') {
      setView({ name: 'keys', server: fresh })
      return
    }
    setView({
      name: 'server',
      server: fresh,
      mode: target === 'profiles' ? 'profiles' : 'settings',
      editingAccess
    })
  }

  if (view.name === 'add') {
    return (
      <AddServer
        onDone={(server) => {
          upsertServer(server)
          setView({ name: 'keys', server })
        }}
        onBack={() => setView({ name: 'dashboard' })}
      />
    )
  }

  if (view.name === 'import') {
    return (
      <ImportServer
        onDone={(server) => {
          upsertServer(server)
          setView({ name: 'server', server, mode: 'settings' })
        }}
        onBack={() => setView({ name: 'dashboard' })}
      />
    )
  }

  if (view.name === 'keys') {
    return (
      <ServerKeys
        server={view.server}
        onBack={() => setView({ name: 'dashboard' })}
        onSettings={() => void openServer(view.server, 'settings')}
      />
    )
  }

  if (view.name === 'server') {
    return (
      <ServerPage
        server={view.server}
        mode={view.mode}
        editingAccess={view.editingAccess ?? false}
        initialSection={view.section}
        onBack={() => setView({ name: 'dashboard' })}
        onOpenProfiles={() =>
          setView({
            name: 'server',
            server: view.server,
            mode: 'profiles',
            editingAccess: view.editingAccess
          })
        }
        onOpenSettings={(section) =>
          setView({
            name: 'server',
            server: view.server,
            mode: 'settings',
            editingAccess: view.editingAccess,
            section
          })
        }
      />
    )
  }

  return (
    <Dashboard
      servers={servers}
      onAdd={() => setView({ name: 'add' })}
      onImport={() => setView({ name: 'import' })}
      onOpen={(server) => void openServer(server, 'keys')}
      onSettings={(server) => void openServer(server, 'settings')}
      onEditAccess={(server) => void openServer(server, 'settings', true)}
      onRemove={async (id) => {
        await window.api.servers.remove(id)
        setServers((prev) => prev.filter((s) => s.id !== id))
      }}
    />
  )
}
