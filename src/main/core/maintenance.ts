import { SshClient, SshCredentials } from './ssh-client'
import { shellCommand } from './shell-command'
import { describeFailure, isUnknownCommandFailure, unknownCommandHint } from './cli-failure'
import { extractJson } from './profiles'
import { dns01CliArgs, isDns01Ready, isValidDns01Domain, type Dns01Input } from '@shared/dns01'
import type {
  AlertsStatusResult,
  AlertsTestResult,
  AlertsToggleResult,
  Dns01RepairResult,
  Dns01StatusResult
} from '@shared/types'

/** Человекочитаемая причина, почему набор DNS-01 неполный (для ошибки в GUI). */
function dns01Problem(input: Dns01Input): string | null {
  if (!isValidDns01Domain(input.domain)) {
    return 'Укажите домен подписки вида sub.example.com (A/AAAA должна указывать на этот VPS)'
  }
  if (input.provider === 'cloudflare') {
    return isDns01Ready(input)
      ? null
      : 'Укажите API-токен Cloudflare (минимум 20 символов, право DNS:Edit на зону)'
  }
  if (input.provider === 'route53') {
    return isDns01Ready(input) ? null : 'Укажите корректные AWS access key id и secret'
  }
  return 'Выберите провайдера DNS: cloudflare или route53'
}

/**
 * Обслуживание подписки и мониторинга: DNS-01 (certbot по TXT-записи, без :80) и
 * Telegram-алерты. Отдельный менеджер, потому что это серверные операции уровня
 * установки (как update/uninstall), а не профилей и не бэкендов.
 *
 * Валидация параметров DNS-01 делается ДО выхода на сервер: сервер тоже проверяет,
 * но ошибка в GUI должна появляться мгновенно и не зависеть от SSH-раунда.
 */
export class MaintenanceManager {
  constructor(private readonly creds: SshCredentials) {}

  private async run(args: readonly string[]): Promise<string> {
    const client = new SshClient(this.creds)
    try {
      await client.connect()
      const res = await client.exec(shellCommand('xrayebator', args), { elevated: true })
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

  private async dns01(args: readonly string[]): Promise<Dns01RepairResult> {
    try {
      const payload = extractJson(await this.run(args)) as Dns01RepairResult & {
        ok?: boolean
        error?: string
      }
      return {
        ok: payload.ok === true,
        repaired: payload.repaired,
        skipped: payload.skipped,
        domain: payload.domain,
        provider: payload.provider,
        port: payload.port,
        tls_mode: payload.tls_mode,
        subscription_url: payload.subscription_url,
        note: payload.note,
        error: payload.error
      }
    } catch (err) {
      return { ok: false, error: err instanceof Error ? err.message : String(err) }
    }
  }

  async dns01Status(): Promise<Dns01StatusResult> {
    try {
      const payload = extractJson(await this.run(['dns01-status'])) as Dns01StatusResult
      return {
        ok: payload.ok === true,
        provider: payload.provider ?? '',
        tls_mode: payload.tls_mode ?? '',
        domain: payload.domain ?? '',
        port: payload.port ?? 0,
        credentials_present: payload.credentials_present === true,
        cert_expiry: payload.cert_expiry ?? 0,
        days_left: payload.days_left ?? 0,
        deploy_hook: payload.deploy_hook === true,
        error: payload.error
      }
    } catch (err) {
      return {
        ok: false,
        provider: '',
        tls_mode: '',
        domain: '',
        port: 0,
        credentials_present: false,
        cert_expiry: 0,
        days_left: 0,
        deploy_hook: false,
        error: err instanceof Error ? err.message : String(err)
      }
    }
  }

  /** Включить DNS-01 там, где подписки ещё нет (обычный путь из настроек). */
  async dns01Setup(input: Dns01Input): Promise<Dns01RepairResult> {
    const problem = dns01Problem(input)
    if (problem) return { ok: false, error: problem }
    return this.dns01(['dns01-setup', ...dns01CliArgs(input)])
  }

  /**
   * Заменить деградированную (http_tls) подписку на DNS-01. Идемпотентно: если
   * подписка уже на HTTPS, сервер вернёт skipped:true.
   */
  async repairDns01(input: Dns01Input): Promise<Dns01RepairResult> {
    const problem = dns01Problem(input)
    if (problem) return { ok: false, error: problem }
    return this.dns01(['repair-dns01', ...dns01CliArgs(input)])
  }

  async alertsStatus(): Promise<AlertsStatusResult> {
    try {
      const payload = extractJson(await this.run(['alerts-status'])) as AlertsStatusResult
      return {
        ok: payload.ok === true,
        configured: payload.configured === true,
        enabled: payload.enabled === true,
        chat_id: payload.chat_id ?? '',
        bot_username: payload.bot_username ?? '',
        timer_installed: payload.timer_installed === true,
        timer_active: payload.timer_active === true,
        last_run: payload.last_run ?? 0,
        events: payload.events ?? {},
        sni: payload.sni ?? {},
        error: payload.error
      }
    } catch (err) {
      return {
        ok: false,
        configured: false,
        enabled: false,
        chat_id: '',
        bot_username: '',
        timer_installed: false,
        timer_active: false,
        last_run: 0,
        events: {},
        sni: {},
        error: err instanceof Error ? err.message : String(err)
      }
    }
  }

  /** Тестовое сообщение: единственная проверка, что токен и чат действительно живые. */
  async alertsTest(): Promise<AlertsTestResult> {
    try {
      const payload = extractJson(await this.run(['alerts-test'])) as AlertsTestResult
      return { ok: payload.ok === true, sent: payload.sent === true, error: payload.error }
    } catch (err) {
      return { ok: false, error: err instanceof Error ? err.message : String(err) }
    }
  }

  /**
   * Вкл/выкл отправку. Токен бота через GUI не принимаем осознанно: он живёт в
   * alerts.json (0600 root) и настраивается через TUI/CLI `alerts-setup` — тот же
   * уровень доверия, что и SSH-пароль, но без дублирования секрета в renderer'е.
   */
  async alertsToggle(on: boolean): Promise<AlertsToggleResult> {
    try {
      const payload = extractJson(
        await this.run([on ? 'alerts-enable' : 'alerts-disable'])
      ) as AlertsToggleResult
      return { ok: payload.ok === true, enabled: payload.enabled, error: payload.error }
    } catch (err) {
      return { ok: false, error: err instanceof Error ? err.message : String(err) }
    }
  }
}
