import { describe, expect, it } from 'vitest'
import {
  describeTraffic,
  formatBytes,
  isValidTrafficLimitInput,
  trafficLimitToInput
} from '../../src/shared/traffic'

const GB = 1024 * 1024 * 1024

describe('describeTraffic', () => {
  it('без лимита и без трафика → none (чип не показывается)', () => {
    expect(describeTraffic(0, 0, false)).toEqual({ status: 'none', ratio: 0 })
  })

  it('трафик без лимита → unlimited', () => {
    expect(describeTraffic(123 * 1024 * 1024, 0, false)).toEqual({
      status: 'unlimited',
      ratio: 0
    })
  })

  it('меньше 80% лимита → ok', () => {
    expect(describeTraffic(GB, 10 * GB, false).status).toBe('ok')
  })

  it('порог предупреждения 80% → warn, чуть ниже → ok', () => {
    expect(describeTraffic(8 * GB, 10 * GB, false).status).toBe('warn')
    expect(describeTraffic(7.9 * GB, 10 * GB, false).status).toBe('ok')
  })

  it('used >= limit → exceeded (сервер отключит при следующей проверке)', () => {
    expect(describeTraffic(10 * GB, 10 * GB, false)).toEqual({ status: 'exceeded', ratio: 1 })
    expect(describeTraffic(11 * GB, 10 * GB, false).ratio).toBe(1)
  })

  it('флаг серверного отключения важнее чисел (race с таймером)', () => {
    expect(describeTraffic(GB, 10 * GB, true).status).toBe('disabled')
  })

  it('отрицательные и NaN значения трактуются как 0', () => {
    expect(describeTraffic(-5, Number.NaN, false).status).toBe('none')
    expect(describeTraffic(Number.NaN, -1, false).status).toBe('none')
  })
})

describe('formatBytes', () => {
  it('двоичные единицы: десятая только у дробных значений до 10', () => {
    expect(formatBytes(0)).toBe('0 B')
    expect(formatBytes(512)).toBe('512 B')
    expect(formatBytes(1536)).toBe('1.5 KB')
    expect(formatBytes(1024 * 1024)).toBe('1 MB')
    expect(formatBytes(1.5 * GB)).toBe('1.5 GB')
  })

  it('крупные значения без дробной части', () => {
    expect(formatBytes(100 * GB)).toBe('100 GB')
    expect(formatBytes(2 * 1024 ** 4)).toBe('2 TB')
  })

  it('некорректные значения → 0 B', () => {
    expect(formatBytes(Number.NaN)).toBe('0 B')
    expect(formatBytes(-1)).toBe('0 B')
    expect(formatBytes(Number.POSITIVE_INFINITY)).toBe('0 B')
  })
})

describe('isValidTrafficLimitInput', () => {
  it('принимает ту же грамматику, что серверный _normalize_traffic_limit', () => {
    for (const value of ['100GB', '500mb', '1.5TB', '2 b', '1073741824', 'none', ' NONE ']) {
      expect(isValidTrafficLimitInput(value), value).toBe(true)
    }
  })

  it('отвергает мусор', () => {
    for (const value of ['', 'abc', '10XB', 'GB', '-5GB', '1,5GB', '10 GB extra']) {
      expect(isValidTrafficLimitInput(value), value).toBe(false)
    }
  })
})

describe('trafficLimitToInput', () => {
  it('точные гигабайты → компактная форма для поля ввода', () => {
    expect(trafficLimitToInput(100 * GB)).toBe('100GB')
    expect(trafficLimitToInput(1 * 1024 ** 4)).toBe('1024GB')
  })

  it('нецелые гигабайты → байты (парсер сервера их принимает)', () => {
    expect(trafficLimitToInput(500 * 1024 * 1024)).toBe('524288000')
  })

  it('0 и мусор → пустая строка', () => {
    expect(trafficLimitToInput(0)).toBe('')
    expect(trafficLimitToInput(Number.NaN)).toBe('')
  })

  it('результат всегда проходит собственную валидацию', () => {
    for (const bytes of [GB, 100 * GB, 500 * 1024 * 1024, 1234567]) {
      expect(isValidTrafficLimitInput(trafficLimitToInput(bytes))).toBe(true)
    }
  })
})
