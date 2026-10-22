/**
 * Копирование в буфер обмена с честным результатом.
 *
 * `navigator.clipboard.writeText()` в Electron есть не всегда: API отсутствует в
 * небезопасном контексте, а при отказе разрешения промис отклоняется. Раньше
 * вызовы шли без обработки — пользователь видел «Скопировано!» (или вообще ничего,
 * если падало до тоста) и уносил в чат пустой буфер. Возвращаем boolean, чтобы
 * каждый экран сам решил, что показать: успех или «скопируйте вручную».
 */
export async function copyText(text: string): Promise<boolean> {
  try {
    const clipboard =
      typeof navigator !== 'undefined' ? (navigator.clipboard as Clipboard | undefined) : undefined
    if (!clipboard || typeof clipboard.writeText !== 'function') return false
    await clipboard.writeText(text)
    return true
  } catch {
    return false
  }
}
