import type { VlessLink } from '@shared/types'

function decodeBase64(input: string): string {
  return Buffer.from(input.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString(
    'utf8'
  )
}

export function parseVlessLine(line: string): VlessLink | null {
  const trimmed = line.trim()
  if (!trimmed.startsWith('vless://')) return null

  const hashIdx = trimmed.indexOf('#')
  const payload = hashIdx === -1 ? trimmed : trimmed.slice(0, hashIdx)
  const fragment = hashIdx === -1 ? '' : trimmed.slice(hashIdx + 1)
  const name = fragment ? decodeURIComponent(fragment) : ''

  const afterScheme = payload.slice('vless://'.length)
  const atIdx = afterScheme.indexOf('@')
  if (atIdx === -1) return null

  const queryStart = afterScheme.indexOf('?')
  const authority = queryStart === -1 ? afterScheme : afterScheme.slice(0, queryStart)
  const query = queryStart === -1 ? '' : afterScheme.slice(queryStart + 1)

  const hostPort = authority.slice(atIdx + 1)
  const lastColon = hostPort.lastIndexOf(':')
  if (lastColon === -1) return null
  const host = hostPort.slice(0, lastColon)
  const port = hostPort.slice(lastColon + 1)

  const params = new URLSearchParams(query)
  const type = params.get('type')

  let transport: VlessLink['transport'] = 'tcp'
  if (type === 'grpc') transport = 'grpc'
  else if (type === 'xhttp') transport = 'xhttp'

  return {
    name: name || `${host}:${port}`,
    url: trimmed,
    transport
  }
}

export function parseSubscription(body: string): VlessLink[] {
  const lines = body.split(/\r?\n/)
  const links: VlessLink[] = []

  for (const line of lines) {
    if (line.startsWith('vless://')) {
      const link = parseVlessLine(line)
      if (link) links.push(link)
      continue
    }

    // Иные строки могут содержать base64-блок со списком vless://
    const candidate = line.trim()
    if (candidate && !candidate.includes('://') && candidate.length > 40) {
      try {
        const decoded = decodeBase64(candidate)
        if (decoded.includes('vless://')) {
          for (const inner of decodeBase64(candidate).split(/\r?\n/)) {
            const link = parseVlessLine(inner)
            if (link) links.push(link)
          }
        }
      } catch {
        // не base64 — пропускаем
      }
    }
  }

  return links
}

export async function fetchSubscription(
  url: string,
  timeoutMs = 15000
): Promise<VlessLink[]> {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), timeoutMs)

  try {
    const res = await fetch(url, {
      signal: controller.signal,
      headers: { 'User-Agent': 'Xrayebator/0.1' }
    })
    if (!res.ok) {
      throw new Error(`HTTP ${res.status} ${res.statusText}`)
    }
    const body = await res.text()
    return parseSubscription(body)
  } finally {
    clearTimeout(timer)
  }
}
