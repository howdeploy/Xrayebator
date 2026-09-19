import { SshClient, SshCredentials } from './ssh-client'
import { shellCommand } from './shell-command'
import type { ServerProfile } from '@shared/types'

export interface ProfileListOutput {
  ok: boolean
  profiles: ServerProfile[]
  error?: string
}

export interface ProfileCreateOutput {
  ok: boolean
  names: string[]
  errors: string[]
}

export interface ProfileDeleteOutput {
  ok: boolean
  name?: string
  error?: string
}

export interface ProfileFingerprintOutput {
  ok: boolean
  name?: string
  fingerprint?: string
  route?: string
  error?: string
}

export interface ProfileSniOutput {
  ok: boolean
  name?: string
  sni?: string
  port?: number
  transport?: string
  route?: string
  affected?: string[]
  unchanged?: boolean
  reconnect?: boolean
  error?: string
}

export interface ProfilePortOutput {
  ok: boolean
  name?: string
  port?: number
  old_port?: number
  transport?: string
  route?: string
  unchanged?: boolean
  reconnect?: boolean
  warning?: string
  firewall_warning?: boolean
  error?: string
}

export interface SniListOutput {
  ok: boolean
  snis?: { sni: string; category: string; priority: string }[]
  error?: string
}

export function extractJson(raw: string): unknown {
  // Серверный CLI может печатать ANSI-статусы (backup_config, open_firewall_port,
  // safe_restart_xray) в stdout перед JSON. \033[0;36m содержит '[', из-за чего
  // парсер раньше матчил ANSI-код вместо JSON и падал с «пустым ответом».
  // Вычищаем ESC-последовательности и ищем первый валидный сбалансированный блок.
  const clean = raw.replace(/\u001b\[[0-9;]*[a-zA-Z]/g, '')

  for (let start = 0; start < clean.length; start++) {
    const open = clean[start]
    if (open !== '[' && open !== '{') continue
    const close = open === '[' ? ']' : '}'
    let depth = 0
    let inString = false
    let escaped = false
    for (let i = start; i < clean.length; i++) {
      const ch = clean[i]
      if (inString) {
        if (escaped) escaped = false
        else if (ch === '\\') escaped = true
        else if (ch === '"') inString = false
        continue
      }
      if (ch === '"') {
        inString = true
      } else if (ch === open) {
        depth++
      } else if (ch === close) {
        depth--
        if (depth === 0) {
          try {
            return JSON.parse(clean.slice(start, i + 1))
          } catch {
            break
          }
        }
      }
    }
  }

  const snippet = clean.trim().replace(/\s+/g, ' ').slice(0, 120)
  throw new Error(
    snippet
      ? `Сервер вернул пустой ответ (вывод: ${snippet})`
      : 'Сервер вернул пустой ответ'
  )
}

export class ProfileManager {
  constructor(private readonly creds: SshCredentials) {}

  private async run(args: readonly string[]): Promise<string> {
    const client = new SshClient(this.creds)
    try {
      await client.connect()
      const command = shellCommand('xrayebator', args)
      const res = await client.exec(command, { elevated: true })
      if (res.code !== 0) {
        throw new Error(`xrayebator ${args[0] ?? ''} → код ${res.code}: ${res.stderr.trim()}`)
      }
      return res.stdout
    } finally {
      client.close()
    }
  }

  async list(): Promise<ProfileListOutput> {
    try {
      const stdout = await this.run(['profiles'])
      const payload = extractJson(stdout)
      const profiles = Array.isArray(payload) ? (payload as unknown as ServerProfile[]) : []
      return { ok: true, profiles }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      return { ok: false, profiles: [], error: message }
    }
  }

  async create(
    input: { name: string; transport: string; port?: number; count?: number }
  ): Promise<ProfileCreateOutput> {
    try {
      const args = ['profile-create', '--name', input.name, '--transport', input.transport]
      if (input.port) args.push('--port', String(input.port))
      if (input.count && input.count > 1) args.push('--count', String(input.count))
      const stdout = await this.run(args)
      const payload = extractJson(stdout) as {
        ok?: boolean
        names?: string[]
        errors?: string[]
        error?: string
      }
      return {
        ok: payload.ok === true,
        names: payload.names ?? [],
        errors: payload.error ? [payload.error] : (payload.errors ?? [])
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      return { ok: false, names: [], errors: [message] }
    }
  }

  async remove(name: string): Promise<ProfileDeleteOutput> {
    try {
      const stdout = await this.run(['profile-delete', '--name', name])
      const payload = extractJson(stdout) as {
        ok?: boolean
        name?: string
        error?: string
      }
      return { ok: payload.ok === true, name: payload.name, error: payload.error }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      return { ok: false, error: message }
    }
  }

  async changeFingerprint(input: {
    name: string
    route?: number
    fingerprint: string
  }): Promise<ProfileFingerprintOutput> {
    try {
      const args = ['fp-change', '--name', input.name]
      if (typeof input.route === 'number') args.push('--route', String(input.route))
      args.push('--fp', input.fingerprint)
      const stdout = await this.run(args)
      const payload = extractJson(stdout) as {
        ok?: boolean
        name?: string
        fingerprint?: string
        route?: string
        error?: string
      }
      return {
        ok: payload.ok === true,
        name: payload.name,
        fingerprint: payload.fingerprint,
        route: payload.route,
        error: payload.error
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      return { ok: false, error: message }
    }
  }

  async changeSni(input: {
    name: string
    route?: number
    sni: string
  }): Promise<ProfileSniOutput> {
    try {
      const args = ['sni-change', '--name', input.name]
      if (typeof input.route === 'number') args.push('--route', String(input.route))
      args.push('--sni', input.sni)
      const stdout = await this.run(args)
      const payload = extractJson(stdout) as {
        ok?: boolean
        name?: string
        sni?: string
        port?: number
        transport?: string
        route?: string
        affected?: string[]
        unchanged?: boolean
        reconnect?: boolean
        error?: string
      }
      return {
        ok: payload.ok === true,
        name: payload.name,
        sni: payload.sni,
        port: payload.port,
        transport: payload.transport,
        route: payload.route,
        affected: payload.affected,
        unchanged: payload.unchanged,
        reconnect: payload.reconnect,
        error: payload.error
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      return { ok: false, error: message }
    }
  }

  async sniList(): Promise<SniListOutput> {
    try {
      const stdout = await this.run(['sni-list'])
      const payload = extractJson(stdout) as {
        ok?: boolean
        snis?: { sni: string; category: string; priority: string }[]
        error?: string
      }
      return {
        ok: payload.ok === true,
        snis: payload.snis ?? [],
        error: payload.error
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      return { ok: false, snis: [], error: message }
    }
  }

  async changePort(input: {
    name: string
    route?: number
    port: number | 'random'
  }): Promise<ProfilePortOutput> {
    try {
      const args = ['port-change', '--name', input.name]
      if (typeof input.route === 'number') args.push('--route', String(input.route))
      args.push('--port', String(input.port))
      const stdout = await this.run(args)
      const payload = extractJson(stdout) as {
        ok?: boolean
        name?: string
        port?: number
        old_port?: number
        transport?: string
        route?: string
        unchanged?: boolean
        reconnect?: boolean
        warning?: string
        firewall_warning?: boolean
        error?: string
      }
      return {
        ok: payload.ok === true,
        name: payload.name,
        port: payload.port,
        old_port: payload.old_port,
        transport: payload.transport,
        route: payload.route,
        unchanged: payload.unchanged,
        reconnect: payload.reconnect,
        warning: payload.warning,
        firewall_warning: payload.firewall_warning,
        error: payload.error
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      return { ok: false, error: message }
    }
  }
}
