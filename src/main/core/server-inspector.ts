import { SshClient, SshCredentials } from './ssh-client'
import { shellCommand } from './shell-command'
import { extractJson } from './profiles'
import type {
  DiagnosticState,
  InspectionSnapshot,
  ProfilesState,
  ServerDiagnostics,
  ServerSetupStatus,
  SubscriptionState,
  VlessLink,
  XrayState
} from '@shared/types'

/** Результат проверки публичной подписки: ключи, null (не проверялась/недоступна). */
export type SubscriptionProbe = VlessLink[] | null | 'unreachable'

export interface NormalizedInspection {
  setupStatus: ServerSetupStatus
  subscriptionUrl: string
  keys: VlessLink[]
  routesCount: number | null
  os: string | null
  country: string | null
  city: string | null
  flag: string | null
  diagnostics: ServerDiagnostics
}

function isLocalSubscriptionUrl(url: string): boolean {
  return (
    /^\[?127\.0\.0\.1\]?$/.test(url) ||
    /\/\/(127\.0\.0\.1|localhost|\[::1\])(:|\/)/.test(url) ||
    url.startsWith('http://')
  )
}

/** Публичный URL, который GUI может пробовать; null — probe не выполнять. */
export function subscriptionProbeTarget(snapshot: InspectionSnapshot): string | null {
  const url = snapshot.subscription_url?.trim() ?? ''
  if (!url) return null
  if (snapshot.subscription_mode === 'local_only') return null
  if (isLocalSubscriptionUrl(url)) return null
  if (!url.startsWith('https://')) return null
  return url
}

function subscriptionState(
  snapshot: InspectionSnapshot,
  probe: SubscriptionProbe
): SubscriptionState {
  if (!snapshot.subscription_installed) return 'missing'
  const publicUrl = subscriptionProbeTarget(snapshot) !== null
  if (!publicUrl) {
    return snapshot.subscription_mode === 'local_only' ? 'localOnly' : 'missing'
  }
  if (probe === null) return 'public'
  if (probe === 'unreachable' || probe.length === 0) return 'unreachable'
  return 'public'
}

export function normalizeInspection(
  snapshot: InspectionSnapshot,
  probe: SubscriptionProbe
): NormalizedInspection {
  if (!snapshot.ok || !snapshot.recognized) {
    throw new Error(
      snapshot.error ?? 'На сервере не распознана установка Xrayebator — импорт недоступен'
    )
  }
  if (snapshot.manager !== 'detected') {
    throw new Error('Xrayebator (менеджер) не найден на сервере — импорт недоступен')
  }

  const subscription = subscriptionState(snapshot, probe)
  const publicUrl = subscriptionProbeTarget(snapshot) ?? ''
  const keys = Array.isArray(probe) ? probe : []

  const diagnostics: ServerDiagnostics = {
    manager: snapshot.manager as DiagnosticState,
    xray: snapshot.xray as XrayState,
    profiles: snapshot.profiles as ProfilesState,
    subscription,
    inspectedAt: new Date().toISOString()
  }

  const ready =
    diagnostics.manager === 'detected' &&
    diagnostics.xray === 'running' &&
    diagnostics.profiles === 'available' &&
    subscription === 'public' &&
    keys.length > 0

  // Публичный, но недосягаемый URL сохраняем как metadata — карточка помнит
  // endpoint; Keys-страница ориентируется на diagnostics.subscription.
  const subscriptionUrl =
    subscription === 'localOnly' || subscription === 'missing' ? '' : publicUrl

  return {
    setupStatus: ready ? 'ready' : 'partial',
    subscriptionUrl,
    keys,
    routesCount: snapshot.profile_count > 0 ? snapshot.profile_count : null,
    os: snapshot.os || null,
    country: snapshot.country || null,
    city: snapshot.city || null,
    flag: snapshot.flag || null,
    diagnostics
  }
}

/**
 * Read-only инспектор существующей установки для GUI-импорта.
 * Выполняет ТОЛЬКО `xrayebator inspect --json`; никаких mutation-команд.
 */
export class ServerInspector {
  constructor(
    private readonly creds: SshCredentials,
    private readonly probeSubscription: (url: string) => Promise<VlessLink[]> = async () => []
  ) {}

  async inspect(): Promise<NormalizedInspection> {
    const client = new SshClient(this.creds)
    try {
      await client.connect()
      const res = await client.exec(shellCommand('xrayebator', ['inspect', '--json']), {
        elevated: true
      })
      let snapshot: InspectionSnapshot
      try {
        snapshot = extractJson(res.stdout) as InspectionSnapshot
      } catch (err) {
        throw new Error(
          `Сервер не вернул корректный JSON диагностики (код ${res.code}): ` +
            `${err instanceof Error ? err.message : String(err)}`
        )
      }
      if (!snapshot.ok) {
        throw new Error(snapshot.error ?? 'Xrayebator на сервере не распознан')
      }

      const publicUrl = subscriptionProbeTarget(snapshot)
      let probe: SubscriptionProbe = null
      if (publicUrl) {
        try {
          const keys = await this.probeSubscription(publicUrl)
          probe = keys && keys.length > 0 ? keys : 'unreachable'
        } catch {
          probe = 'unreachable'
        }
      } else {
        probe = null
      }
      return normalizeInspection(snapshot, probe)
    } finally {
      client.close()
    }
  }
}
