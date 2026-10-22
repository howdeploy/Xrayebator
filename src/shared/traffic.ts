/**
 * Чистые хелперы учёта трафика профиля.
 * Сервер (xrayebator traffic-check) накапливает байты и принуждает лимит —
 * здесь только форматирование, валидация ввода и классификация состояния.
 */

export type TrafficStatus = 'none' | 'unlimited' | 'ok' | 'warn' | 'exceeded' | 'disabled'

export interface TrafficInfo {
  status: TrafficStatus
  /** used / limit, 0..1; при отсутствии лимита — 0. */
  ratio: number
}

/** Порог предупреждения: сервер отключит профиль при использовании 100% лимита. */
const WARN_RATIO = 0.8

export function describeTraffic(used: number, limit: number, disabled: boolean): TrafficInfo {
  const usedSafe = Number.isFinite(used) && used > 0 ? used : 0
  const limitSafe = Number.isFinite(limit) && limit > 0 ? limit : 0
  if (disabled) {
    return { status: 'disabled', ratio: limitSafe > 0 ? Math.min(usedSafe / limitSafe, 1) : 0 }
  }
  if (limitSafe === 0) {
    return { status: usedSafe > 0 ? 'unlimited' : 'none', ratio: 0 }
  }
  const ratio = Math.min(usedSafe / limitSafe, 1)
  if (usedSafe >= limitSafe) return { status: 'exceeded', ratio: 1 }
  if (ratio >= WARN_RATIO) return { status: 'warn', ratio }
  return { status: 'ok', ratio }
}

const BYTE_UNITS = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'] as const

/** Байты → строка с двоичными единицами («1.5 GB», «500 MB») — как сервер. */
export function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return '0 B'
  let value = bytes
  let unit = 0
  while (value >= 1024 && unit < BYTE_UNITS.length - 1) {
    value /= 1024
    unit += 1
  }
  const digits = unit > 0 && value < 10 && !Number.isInteger(value) ? 1 : 0
  return `${value.toFixed(digits)} ${BYTE_UNITS[unit]}`
}

/**
 * Грамматика строки лимита из поля ввода — та же, что у серверного
 * `_normalize_traffic_limit`: число (можно дробное) с единицей B/KB/MB/GB/TB,
 * голое число (байты) или 'none'. Пробелы игнорируются, регистр не важен.
 */
export function isValidTrafficLimitInput(raw: string): boolean {
  const value = raw.trim().toLowerCase().replace(/\s+/g, '')
  if (value === 'none') return true
  return /^\d+(\.\d+)?([kmgt]?b)?$/.test(value)
}

/** Байты лимита → значение для поля ввода: точные ГБ как «100GB», иначе байты. */
export function trafficLimitToInput(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return ''
  const gib = 1024 * 1024 * 1024
  if (bytes % gib === 0) return `${bytes / gib}GB`
  return String(bytes)
}
