import type { Server } from '@shared/types'
import { vlessPort } from '@shared/vless'

export function probePortsFor(server: Server): number[] {
  const ports = new Set<number>()
  for (const key of server.keys ?? []) {
    ports.add(vlessPort(key.url))
  }
  try {
    const url = new URL(server.subscriptionUrl)
    if (url.port) ports.add(Number(url.port))
  } catch {
    /* ignore malformed url */
  }
  if (ports.size === 0) ports.add(443)
  return [...ports]
}
