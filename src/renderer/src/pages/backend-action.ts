/**
 * Разбор результата операций с бэкендами (установка, запуск, гранты, тумблеры).
 *
 * Зачем отдельный модуль: часть команд сообщает об отказе не кодом возврата, а
 * `{ok:false, error}` в JSON. GUI реагировал только на выброшенные исключения,
 * поэтому такой отказ выглядел как «нажал — ничего не произошло»: живой случай
 * (2026-10-24, `awg-install` на Debian 12) вернул `reboot_required: true` с
 * понятным текстом, а карточка просто осталась «Не установлено».
 */
export interface BackendActionOutcome {
  /** Операция сообщила об отказе через `ok: false`. */
  failed: boolean
  /** Текст причины, если сервер его дал. */
  error?: string
}

export function backendActionFailure(result: unknown): BackendActionOutcome {
  if (!result || typeof result !== 'object') return { failed: false }
  const res = result as { ok?: unknown; error?: unknown }
  if (res.ok !== false) return { failed: false }
  const error =
    typeof res.error === 'string' && res.error.trim().length > 0 ? res.error : undefined
  return { failed: true, error }
}
