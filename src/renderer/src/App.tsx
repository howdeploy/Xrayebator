import { useEffect, useState } from 'react'
import { Dashboard } from './pages/Dashboard'
import { AddServer } from './pages/AddServer'
import { ServerKeys } from './pages/ServerKeys'
import { ServerSettings } from './pages/ServerSettings'
import type { Server } from '@shared/types'

type View =
  | { name: 'dashboard' }
  | { name: 'add' }
  | { name: 'keys'; server: Server }
  | { name: 'settings'; server: Server }

export default function App(): React.JSX.Element {
  const [view, setView] = useState<View>({ name: 'dashboard' })
  const [servers, setServers] = useState<Server[]>([])

  useEffect(() => {
    window.api.servers.list().then(setServers)
  }, [])

  if (view.name === 'add') {
    return (
      <AddServer
        onDone={(server) => {
          setServers((prev) => [...prev, server])
          setView({ name: 'keys', server })
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
      />
    )
  }

  if (view.name === 'settings') {
    return (
      <ServerSettings
        server={view.server}
        onBack={() => setView({ name: 'dashboard' })}
      />
    )
  }

  return (
    <Dashboard
      servers={servers}
      onAdd={() => setView({ name: 'add' })}
      onOpen={(server) => setView({ name: 'keys', server })}
      onSettings={(server) => setView({ name: 'settings', server })}
      onRemove={async (id) => {
        await window.api.servers.remove(id)
        setServers((prev) => prev.filter((s) => s.id !== id))
      }}
    />
  )
}
