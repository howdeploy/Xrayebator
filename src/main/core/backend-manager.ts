import { SshClient, SshCredentials } from './ssh-client'
import { shellCommand } from './shell-command'
import { describeFailure, isUnknownCommandFailure, unknownCommandHint } from './cli-failure'
import { extractJson } from './profiles'
import type {
  AwgConfResult,
  BackendGrantResult,
  BackendSimpleResult,
  BackendStatusResult,
  BackendToggleResult,
  Hysteria2LinkResult,
  Hysteria2SubbodyResult
} from '@shared/types'

/**
 * Разбор вывода `xrayebator backend-status`. Реестр может быть пустым объектом
 * ({}) — тогда оба бэкенда считаются не установленными.
 */
export function parseBackendStatus(raw: string): BackendStatusResult {
  const payload = extractJson(raw) as {
    ok?: boolean
    backends?: Record<string, unknown>
    error?: string
  }
  const backends: BackendStatusResult['backends'] = {}
  for (const [type, value] of Object.entries(payload.backends ?? {})) {
    if (value && typeof value === 'object') {
      backends[type] = value as BackendStatusResult['backends'][string]
    }
  }
  return { ok: payload.ok === true, backends, error: payload.error }
}

/**
 * Разбор вывода `xrayebator awg-conf --name N`. Поле conf — полный текст
 * клиентского .conf (секреты уровня оператора: приватный ключ клиента,
 * preshared key, серверные junk-параметры и HeaderProtectionKey).
 */
export function parseAwgConf(raw: string): AwgConfResult {
  const payload = extractJson(raw) as {
    ok?: boolean
    name?: string
    conf?: string
    error?: string
  }
  return {
    ok: payload.ok === true,
    name: payload.name,
    conf: typeof payload.conf === 'string' ? payload.conf : undefined,
    error: payload.error
  }
}

/**
 * Менеджер опциональных бэкендов (Hysteria 2, AmneziaWG 3.1). Тонкий SSH-фронт
 * к JSON-командам xrayebator — GUI не знает про сервер больше, чем отдают эти
 * команды. Модель этапа 2: бэкенды живут одновременно, доступ транспорта
 * определяется грантами конкретного профиля.
 */
export class BackendManager {
  constructor(private readonly creds: SshCredentials) {}

  private async run(args: readonly string[]): Promise<string> {
    const client = new SshClient(this.creds)
    try {
      await client.connect()
      const command = shellCommand('xrayebator', args)
      const res = await client.exec(command, { elevated: true })
      if (res.code !== 0) {
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

  /** Сводный статус реестра бэкендов (установлены/активны/порты/флаги). */
  async status(): Promise<BackendStatusResult> {
    try {
      return parseBackendStatus(await this.run(['backend-status']))
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      return { ok: false, backends: {}, error: message }
    }
  }

  /**
   * Выдать/обновить грант Hysteria 2 профилю. Серверный конфиг регенерируется
   * из всех профилей; выданным клиентам ничего перекачивать не нужно (их
   * credы остаются в силе, меняется только server.yaml).
   */
  async hysteria2Grant(name: string): Promise<BackendGrantResult> {
    try {
      const stdout = await this.run(['hysteria2-grant', '--name', name])
      const payload = extractJson(stdout) as { ok?: boolean; name?: string; error?: string }
      return { ok: payload.ok === true, name: payload.name, error: payload.error }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      return { ok: false, error: message }
    }
  }

  /**
   * Установка Hysteria 2 (длинная: загрузка бинарника ~23 МБ). grantAll —
   * выдать гранты всем существующим профилям (аналог --grant-all).
   */
  async hysteria2Install(grantAll: boolean): Promise<BackendSimpleResult> {
    try {
      const args = grantAll ? ['hysteria2-install', '--grant-all'] : ['hysteria2-install']
      const payload = extractJson(await this.run(args)) as {
        ok?: boolean
        already?: boolean
        error?: string
      }
      return { ok: payload.ok === true, already: payload.already === true, error: payload.error }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      return { ok: false, error: message }
    }
  }

  async hysteria2Uninstall(): Promise<BackendSimpleResult> {
    try {
      const payload = extractJson(await this.run(['hysteria2-uninstall'])) as {
        ok?: boolean
        already?: boolean
        error?: string
      }
      return { ok: payload.ok === true, already: payload.already === true, error: payload.error }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      return { ok: false, error: message }
    }
  }

  /** Установка AmneziaWG (может включать сборку kernel-модуля — минуты). */
  async awgInstall(grantAll: boolean): Promise<BackendSimpleResult> {
    try {
      const args = grantAll ? ['awg-install', '--grant-all'] : ['awg-install']
      const payload = extractJson(await this.run(args)) as {
        ok?: boolean
        already?: boolean
        error?: string
      }
      return { ok: payload.ok === true, already: payload.already === true, error: payload.error }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      return { ok: false, error: message }
    }
  }

  async awgUninstall(): Promise<BackendSimpleResult> {
    try {
      const payload = extractJson(await this.run(['awg-uninstall'])) as {
        ok?: boolean
        already?: boolean
        error?: string
      }
      return { ok: payload.ok === true, already: payload.already === true, error: payload.error }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      return { ok: false, error: message }
    }
  }

  /** Kill-switch hysteria2-строк в подписке (handler перечитывает реестр сам). */
  async hysteria2Subbody(on: boolean): Promise<Hysteria2SubbodyResult> {
    try {
      const stdout = await this.run(['hysteria2-subbody', on ? '--on' : '--off'])
      const payload = extractJson(stdout) as { ok?: boolean; sub_body?: boolean; error?: string }
      return { ok: payload.ok === true, sub_body: payload.sub_body, error: payload.error }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      return { ok: false, error: message }
    }
  }

  /** hysteria2:// ссылка профиля (нужны установленный бэкенд и грант). */
  async hysteria2Link(name: string): Promise<Hysteria2LinkResult> {
    try {
      const stdout = await this.run(['hysteria2-link', '--name', name])
      const payload = extractJson(stdout) as {
        ok?: boolean
        name?: string
        link?: string
        error?: string
      }
      return {
        ok: payload.ok === true,
        name: payload.name,
        link: typeof payload.link === 'string' ? payload.link : undefined,
        error: payload.error
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      return { ok: false, error: message }
    }
  }

  /** Выдать/обновить AWG peer-грант профилю (keypair + PSK + адрес). */
  async awgGrant(name: string): Promise<BackendGrantResult> {
    try {
      const stdout = await this.run(['awg-grant', '--name', name])
      const payload = extractJson(stdout) as { ok?: boolean; name?: string; error?: string }
      return { ok: payload.ok === true, name: payload.name, error: payload.error }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      return { ok: false, error: message }
    }
  }

  /** Клиентский .conf AWG peer-а профиля (импорт в AmneziaVPN, не V2Ray/HAPP). */
  async awgConf(name: string): Promise<AwgConfResult> {
    try {
      return parseAwgConf(await this.run(['awg-conf', '--name', name]))
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      return { ok: false, error: message }
    }
  }

  /**
   * Тумблер AWG 3.1 (HeaderProtectionKey + RandomTrailers). Внимание UI:
   * переключение меняет [Interface]-параметры — все выданные клиентские .conf
   * должны быть перекачаны; клиентам нужен AmneziaVPN >= 5.0.1.5.
   */
  async awg31(on: boolean): Promise<BackendToggleResult> {
    try {
      const stdout = await this.run(['awg-31', on ? '--on' : '--off'])
      const payload = extractJson(stdout) as {
        ok?: boolean
        three_enabled?: boolean
        disable_cookies?: boolean
        error?: string
      }
      return {
        ok: payload.ok === true,
        three_enabled: payload.three_enabled,
        disable_cookies: payload.disable_cookies,
        error: payload.error
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      return { ok: false, error: message }
    }
  }
}
