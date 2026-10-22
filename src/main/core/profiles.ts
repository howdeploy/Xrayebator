import { SshClient, SshCredentials } from './ssh-client'
import { shellCommand } from './shell-command'
import { describeFailure, isUnknownCommandFailure, unknownCommandHint } from './cli-failure'
import type {
  ProfileExpireResult,
  ProfileLimitResult,
  ProfilePqInput,
  ProfilePqResult,
  ProfileRevokeResult,
  ServerProfile
} from '@shared/types'

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
        // Менеджер печатает причину в stdout (команда неизвестна, профиль не найден),
        // stderr при этом часто пуст — без разбора ошибка выглядела как «код 1: ».
        const reason = describeFailure(res)
        const hint = isUnknownCommandFailure(res) ? ` ${unknownCommandHint()}` : ''
        throw new Error(
          `xrayebator ${args[0] ?? ''} → код ${res.code}${reason ? `: ${reason}` : ''}.${hint}`
        )
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
    input: { name: string; transport: string; port?: number; count?: number; expire?: string }
  ): Promise<ProfileCreateOutput> {
    try {
      const args = ['profile-create', '--name', input.name, '--transport', input.transport]
      if (input.port) args.push('--port', String(input.port))
      if (input.count && input.count > 1) args.push('--count', String(input.count))
      if (input.expire) args.push('--expire', input.expire)
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

  async revoke(input: { name: string; full: boolean }): Promise<ProfileRevokeResult> {
    try {
      const args = ['profile-revoke', '--name', input.name]
      if (input.full) args.push('--full')
      const stdout = await this.run(args)
      const payload = extractJson(stdout) as {
        ok?: boolean
        name?: string
        full?: boolean
        sub_token?: string
        uuid?: string
        subscription_url?: string
        error?: string
      }
      return {
        ok: payload.ok === true,
        name: payload.name,
        full: payload.full,
        sub_token: payload.sub_token,
        uuid: payload.uuid,
        subscription_url: payload.subscription_url,
        error: payload.error
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      return { ok: false, error: message }
    }
  }

  async setExpire(input: {
    name: string
    expire: string | number | null
  }): Promise<ProfileExpireResult> {
    try {
      const value =
        input.expire === null || input.expire === undefined || input.expire === ''
          ? 'none'
          : String(input.expire)
      const stdout = await this.run([
        'profile-expire',
        '--name',
        input.name,
        '--expire',
        value
      ])
      const payload = extractJson(stdout) as {
        ok?: boolean
        name?: string
        expire?: number
        expired?: boolean
        error?: string
      }
      return {
        ok: payload.ok === true,
        name: payload.name,
        expire: payload.expire,
        expired: payload.expired,
        error: payload.error
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      return { ok: false, error: message }
    }
  }

  async setLimit(input: {
    name: string
    limit?: string | number | null
    reset?: boolean
  }): Promise<ProfileLimitResult> {    try {
      const args = ['profile-limit', '--name', input.name]
      if (input.limit !== undefined && input.limit !== null && input.limit !== '') {
        args.push('--limit', String(input.limit))
      }
      if (input.reset) args.push('--reset')
      const stdout = await this.run(args)
      const payload = extractJson(stdout) as {
        ok?: boolean
        name?: string
        traffic_limit?: number
        traffic_used?: number
        traffic_disabled?: boolean
        error?: string
      }
      return {
        ok: payload.ok === true,
        name: payload.name,
        traffic_limit: payload.traffic_limit,
        traffic_used: payload.traffic_used,
        traffic_disabled: payload.traffic_disabled,
        error: payload.error
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      return { ok: false, error: message }
    }
  }

  /**
   * Пост-квантовый маршрут (VLESS Encryption, mlkem768x25519plus). VLESS `decryption`
   * — свойство инбаунда, поэтому сервер поднимает для маршрута отдельный инбаунд/порт;
   * в v2ray/base64-подписке такой маршрут скрыт, клиенту нужен ML-KEM (HAPP, Xray 25.6+).
   */
  async addPq(input: ProfilePqInput): Promise<ProfilePqResult> {
    try {
      const stdout = await this.run([
        'profile-pq',
        '--name',
        input.name,
        '--transport',
        input.transport
      ])
      const payload = extractJson(stdout) as {
        ok?: boolean
        name?: string
        transport?: string
        port?: number
        pq?: boolean
        link?: string
        note?: string
        error?: string
      }
      return {
        ok: payload.ok === true,
        name: payload.name,
        transport: payload.transport,
        port: payload.port,
        pq: payload.pq,
        link: payload.link,
        note: payload.note,
        error: payload.error
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      return { ok: false, error: message }
    }
  }
}
