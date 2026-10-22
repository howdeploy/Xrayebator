import type { DeployStartPayload, EmailMode, SshAccessInput } from '@shared/types'
import { isDns01Ready, type Dns01Input, type Dns01Provider } from '@shared/dns01'
import { isSshAccessReady } from '../components/SshAccessForm'

export interface DeployFormState {
  host: string
  port: string
  emailMode: EmailMode
  email: string
  /** PQ-маршрут при развёртывании: opt-in, по умолчанию выключен. */
  pq?: boolean
  /** DNS-01-фолбэк: включается тумблером, поля — ниже. */
  dns01Enabled?: boolean
  dns01Provider?: Dns01Provider
  dns01Domain?: string
  dns01Token?: string
  dns01AwsKeyId?: string
  dns01AwsSecret?: string
}

export function isValidEmailFormat(email: string): boolean {
  return /^[^@\s]+@[^@\s]+\.[^@\s]{2,}$/.test(email.trim()) && !/[\r\n]/.test(email)
}

/** Набор DNS-01 из формы: провайдер по умолчанию — cloudflare (самый частый случай). */
export function dns01FromForm(form: DeployFormState): Dns01Input {
  return {
    domain: (form.dns01Domain ?? '').trim(),
    provider: form.dns01Provider ?? 'cloudflare',
    token: form.dns01Token ?? '',
    awsKeyId: form.dns01AwsKeyId ?? '',
    awsSecret: form.dns01AwsSecret ?? ''
  }
}

export function isDeployReady(form: DeployFormState, access: SshAccessInput): boolean {
  if (!form.host.trim()) return false
  if (!isSshAccessReady(access)) return false
  if (form.emailMode === 'provided' && !isValidEmailFormat(form.email)) return false
  // DNS-01-фолбэк: кнопка остаётся выключенной, пока набор неполный — иначе сервер
  // вернёт ok:false уже после установки Xray, что выглядит как непонятный сбой.
  if (form.dns01Enabled && !isDns01Ready(dns01FromForm(form))) return false
  return true
}

export function buildDeployPayload(
  form: DeployFormState,
  access: SshAccessInput
): Omit<DeployStartPayload, never> {
  const trimmedEmail = form.email.trim()
  return {
    host: form.host.trim(),
    port: Number(form.port) || 22,
    emailMode: form.emailMode,
    ...(form.emailMode === 'provided' ? { email: trimmedEmail } : {}),
    ...(form.pq ? { pq: true } : {}),
    ...(form.dns01Enabled ? { dns01: dns01FromForm(form) } : {}),
    access
  }
}
