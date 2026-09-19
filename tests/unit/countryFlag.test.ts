import { describe, expect, it } from 'vitest'
import { emojiToCountryCode } from '../../src/renderer/src/components/CountryFlag'

describe('emojiToCountryCode', () => {
  it('превращает Regional Indicator Symbols в ISO-код', () => {
    expect(emojiToCountryCode('🇱🇻')).toBe('LV')
    expect(emojiToCountryCode('🇩🇪')).toBe('DE')
    expect(emojiToCountryCode('🇺🇸')).toBe('US')
    expect(emojiToCountryCode('🇷🇺')).toBe('RU')
  })

  it('возвращает пустую строку без эмодзи', () => {
    expect(emojiToCountryCode('')).toBe('')
    expect(emojiToCountryCode(null)).toBe('')
    expect(emojiToCountryCode(undefined)).toBe('')
  })

  it('корректно обрабатывает флаг с другим текстом', () => {
    expect(emojiToCountryCode('🇳🇱 Нидерланды')).toBe('NL')
  })
})