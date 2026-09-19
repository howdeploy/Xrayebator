import { describe, expect, it } from 'vitest'
import { extractJson } from '../../src/main/core/profiles'

describe('extractJson', () => {
  it('парсит массив из нескольких профилей (регрессия bug profiles:list)', () => {
    const raw = [
      '[',
      '{"name":"happ","transport":"xhttp","port":443},',
      '{"name":"phone-1","transport":"tcp","port":443},',
      '{"name":"phone-2","transport":"grpc","port":8443}',
      ']'
    ].join('\n')
    const payload = extractJson(raw) as Array<{ name: string }>
    expect(Array.isArray(payload)).toBe(true)
    expect(payload.map((p) => p.name)).toEqual(['happ', 'phone-1', 'phone-2'])
  })

  it('парсит единичный объект', () => {
    const payload = extractJson('{"ok":true,"names":["a"]}') as { ok: boolean }
    expect(payload.ok).toBe(true)
  })

  it('обходит служебный мусор до и после JSON', () => {
    const raw =
      'Логи перед...\n[{"name":"a"},{"name":"b"}]\nчто-то после'
    const payload = extractJson(raw) as Array<{ name: string }>
    expect(payload).toHaveLength(2)
  })

  it('корректно обрабатывает скобки внутри строк (URL, base64)', () => {
    const raw =
      '[{"name":"a","url":"https://h:443/sub/[tok]","sub_token":"xyz[123]"}]'
    const payload = extractJson(raw) as Array<{ url: string }>
    expect(payload[0].url).toBe('https://h:443/sub/[tok]')
  })

  it('парсит JSON c ANSI-статусами от safe_restart_xray (регрессия "пустой ответ")', () => {
    const raw = [
      '\x1b[0;36m  -> Бэкап конфига: config_20260811_cli_create_phone-1.json\x1b[0m',
      '\x1b[0;32m  ✓ Xray перезапущен\x1b[0m',
      '{"ok":true,"names":["phone-1","phone-2"],"errors":[]}'
    ].join('\n')
    const payload = extractJson(raw) as { ok: boolean; names: string[] }
    expect(payload.ok).toBe(true)
    expect(payload.names).toEqual(['phone-1', 'phone-2'])
  })

  it('бросает ошибку на пустом выводе', () => {
    expect(() => extractJson('')).toThrow('Сервер вернул пустой ответ')
  })

  it('включает сниппет вывода в сообщение об ошибке (диагностика)', () => {
    expect(() => extractJson('что-то без JSON')).toThrow(/вывод: что-то без JSON/)
  })
})