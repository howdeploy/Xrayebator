/**
 * DNS-01 (Cloudflare/Route53) — общая часть GUI: визард развёртывания, ремонт
 * деградированной подписки и карточка в настройках сервера. Валидация зеркалит
 * серверную (`_dns01_validate_domain`, `_dns01_provider_supported`, проверки
 * `--token`/`--aws-*` в `repair_dns01_command`), чтобы GUI не отправлял заведомо
 * невалидный запрос и не показывал «успех» там, где сервер вернул ok:false.
 */

export type Dns01Provider = 'cloudflare' | 'route53'

export const DNS01_PROVIDERS: readonly Dns01Provider[] = ['cloudflare', 'route53']

export interface Dns01Input {
  domain: string
  provider: Dns01Provider
  /** Cloudflare API-token с правом DNS:Edit на зону. */
  token?: string
  /** Route53: ключ доступа AWS. */
  awsKeyId?: string
  awsSecret?: string
}

/** Домен подписки: буквы/цифры/дефисы, минимум одна точка, не IP (как на сервере). */
export function isValidDns01Domain(domain: string): boolean {
  const d = domain.trim()
  if (!d || /[\s\r\n/\\:@]/.test(d)) return false
  if (/^[0-9.]+$/.test(d)) return false
  return /^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$/.test(
    d
  )
}

/** Cloudflare API-token: сервер требует минимум 20 символов [A-Za-z0-9_-]. */
export function isValidCloudflareToken(token: string): boolean {
  return /^[A-Za-z0-9_-]{20,}$/.test(token.trim())
}

/** AWS access key id: AKIA/ASIA-подобный идентификатор (верхний регистр + цифры). */
export function isValidAwsKeyId(keyId: string): boolean {
  return /^[A-Z0-9]{16,32}$/.test(keyId.trim())
}

/** AWS secret access key: base64-подобная строка без пробелов и переводов строк. */
export function isValidAwsSecret(secret: string): boolean {
  return /^[A-Za-z0-9/+=]{30,128}$/.test(secret.trim())
}

/** Готов ли набор для DNS-01: домен + провайдер + креденшелы этого провайдера. */
export function isDns01Ready(input: Dns01Input): boolean {
  if (!isValidDns01Domain(input.domain)) return false
  if (input.provider === 'cloudflare') return isValidCloudflareToken(input.token ?? '')
  if (input.provider === 'route53') {
    return isValidAwsKeyId(input.awsKeyId ?? '') && isValidAwsSecret(input.awsSecret ?? '')
  }
  return false
}

/**
 * Аргументы CLI для `dns01-setup`/`repair-dns01`/`quickstart`. `prefix` — префикс
 * длинных опций: `--` для CLI-команд, `--dns01-` для quickstart. Креденшелы уходят
 * только те, что нужны выбранному провайдеру: лишний `--token` для route53 сервер
 * проигнорирует, но и хранить его в payload незачем.
 */
export function dns01CliArgs(input: Dns01Input, prefix = '--'): string[] {
  const args = [`${prefix}domain`, input.domain.trim(), `${prefix}provider`, input.provider]
  if (input.provider === 'cloudflare') {
    args.push(`${prefix}token`, (input.token ?? '').trim())
  } else if (input.provider === 'route53') {
    args.push(
      `${prefix}aws-access-key-id`,
      (input.awsKeyId ?? '').trim(),
      `${prefix}aws-secret-access-key`,
      (input.awsSecret ?? '').trim()
    )
  }
  return args
}

/** Маскировка секрета для консоли/логов: показываем только длину и края. */
export function maskSecret(value: string): string {
  const v = value.trim()
  if (!v) return '—'
  if (v.length <= 8) return '•'.repeat(v.length)
  return `${v.slice(0, 4)}…${v.slice(-2)} (${v.length})`
}
