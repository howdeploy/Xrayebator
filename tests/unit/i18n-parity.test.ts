import { describe, expect, it } from 'vitest'
import en from '../../src/renderer/src/i18n/en.json'
import ru from '../../src/renderer/src/i18n/ru.json'
import zh from '../../src/renderer/src/i18n/zh.json'

/**
 * Паритет ключей трёх языков.
 *
 * Раньше рассинхрон жил незамеченным: `dashboard.routes_few`/`routes_many` были
 * только в ru, `routes_other` — только в en, в zh plural-форм не было вовсе, и
 * никто этого не видел, пока счётчик не начал бы просить несуществующий ключ и
 * показывать сырое имя ключа вместо числа. Тест сравнивает НАБОРЫ ключей, а
 * plural-суффиксы учитывает отдельно: у ru форм больше, чем у en/zh, и это нормально.
 */

const LOCALES = { ru, en, zh } as const
const PLURAL_SUFFIXES = ['zero', 'one', 'two', 'few', 'many', 'other']
const PLURAL_CATEGORIES = { ru: ['one', 'few', 'many', 'other'], en: ['one', 'other'], zh: ['other'] } as const

type Json = { [key: string]: string | Json }

/** Плоский список путей: 'settings.title', 'deploy.status.done'. */
function flatten(node: Json, prefix = ''): string[] {
  const out: string[] = []
  for (const [key, value] of Object.entries(node)) {
    const path = prefix ? `${prefix}.${key}` : key
    if (typeof value === 'string') out.push(path)
    else out.push(...flatten(value, path))
  }
  return out
}

/** Путь без plural-суффикса: 'dashboard.routes_few' → 'dashboard.routes'. */
function basePath(path: string): string {
  const parts = path.split('.')
  const last = parts[parts.length - 1]
  const idx = last.lastIndexOf('_')
  if (idx > 0 && PLURAL_SUFFIXES.includes(last.slice(idx + 1))) {
    parts[parts.length - 1] = last.slice(0, idx)
  }
  return parts.join('.')
}

function valueAt(node: Json, path: string): string | undefined {
  let current: Json | string | undefined = node
  for (const part of path.split('.')) {
    if (typeof current !== 'object' || current === null) return undefined
    current = current[part]
  }
  return typeof current === 'string' ? current : undefined
}

function placeholders(text: string): string[] {
  return [...text.matchAll(/\{\{(\w+)\}\}/g)].map((m) => m[1]).sort()
}

describe('i18n parity', () => {
  const flat: Record<string, string[]> = {
    ru: flatten(ru as Json),
    en: flatten(en as Json),
    zh: flatten(zh as Json)
  }

  it('has the same set of keys in every language (plural suffixes aside)', () => {
    const baseSets: Record<string, Set<string>> = {}
    for (const [lng, keys] of Object.entries(flat)) {
      baseSets[lng] = new Set(keys.map(basePath))
    }
    const reference = [...baseSets.ru].sort()
    for (const lng of ['en', 'zh'] as const) {
      const missing = reference.filter((k) => !baseSets[lng].has(k))
      const extra = [...baseSets[lng]].filter((k) => !baseSets.ru.has(k)).sort()
      expect({ lng, missing, extra }).toEqual({ lng, missing: [], extra: [] })
    }
  })

  it('provides every plural form the language actually needs', () => {
    const baseKeys = new Set(flat.ru.filter((k) => basePath(k) !== k).map(basePath))
    for (const [lng, categories] of Object.entries(PLURAL_CATEGORIES)) {
      for (const base of baseKeys) {
        const present = categories.filter((c) => flat[lng].includes(`${base}_${c}`))
        expect({ lng, base, present }).toEqual({ lng, base, present: [...categories] })
      }
    }
  })

  it('keeps interpolation placeholders in sync with the Russian source', () => {
    const mismatches: string[] = []
    for (const key of flat.ru) {
      const source = valueAt(ru as Json, key)
      if (!source || !source.includes('{{')) continue
      for (const lng of ['en', 'zh'] as const) {
        const translated = valueAt(LOCALES[lng] as Json, key)
        if (translated === undefined) continue // отсутствие ключа ловит тест выше
        const expected = placeholders(source)
        const actual = placeholders(translated)
        if (expected.join(',') !== actual.join(',')) {
          mismatches.push(`${lng}:${key} expected ${expected.join(',')} got ${actual.join(',')}`)
        }
      }
    }
    expect(mismatches).toEqual([])
  })

  it('has no empty strings', () => {
    const empties: string[] = []
    for (const [lng, node] of Object.entries(LOCALES)) {
      for (const key of flatten(node as Json)) {
        if ((valueAt(node as Json, key) ?? '').trim() === '') empties.push(`${lng}:${key}`)
      }
    }
    expect(empties).toEqual([])
  })
})
