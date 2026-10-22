import { afterEach, describe, expect, it, vi } from 'vitest'
import { copyText } from '../../src/renderer/src/lib/clipboard'

/**
 * Копирование раньше шло через голый `navigator.clipboard.writeText()`: при отказе
 * промис отклонялся, тост не показывался, и пользователь считал, что скопировал.
 * Хелпер обязан вернуть false вместо исключения — во всех трёх режимах отказа.
 */
const originalNavigator = Object.getOwnPropertyDescriptor(globalThis, 'navigator')

function setClipboard(value: unknown): void {
  Object.defineProperty(globalThis, 'navigator', {
    value,
    configurable: true,
    writable: true
  })
}

afterEach(() => {
  if (originalNavigator) {
    Object.defineProperty(globalThis, 'navigator', originalNavigator)
  } else {
    // @ts-expect-error — в node-окружении navigator может отсутствовать вовсе
    delete globalThis.navigator
  }
  vi.restoreAllMocks()
})

describe('copyText', () => {
  it('returns true when the clipboard accepts the text', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined)
    setClipboard({ clipboard: { writeText } })
    await expect(copyText('vless://key')).resolves.toBe(true)
    expect(writeText).toHaveBeenCalledWith('vless://key')
  })

  it('returns false instead of throwing when the write is rejected', async () => {
    setClipboard({
      clipboard: { writeText: vi.fn().mockRejectedValue(new Error('NotAllowedError')) }
    })
    await expect(copyText('vless://key')).resolves.toBe(false)
  })

  it('returns false when the clipboard API is missing entirely', async () => {
    setClipboard({})
    await expect(copyText('vless://key')).resolves.toBe(false)

    setClipboard({ clipboard: {} })
    await expect(copyText('vless://key')).resolves.toBe(false)
  })

  it('returns false when there is no navigator at all', async () => {
    // @ts-expect-error — проверяем отсутствие глобального объекта
    delete globalThis.navigator
    await expect(copyText('vless://key')).resolves.toBe(false)
  })
})
