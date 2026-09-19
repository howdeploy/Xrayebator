import 'country-flag-icons/3x2/flags.css'

/** Извлекает ISO-код страны из Regional Indicator Symbols (🇱🇻 → LV).
 *  Windows рендерит эмодзи-флаги как буквы, поэтому для GUI используем
 *  country-flag-icons с настоящим изображением флага. Пустой результат → показывать эмодзи-фолбэк. */
export function emojiToCountryCode(flag: string | null | undefined): string {
  if (!flag) return ''
  const base = 0x1f1e6 // 'A'
  let code = ''
  for (const ch of flag) {
    const cp = ch.codePointAt(0)
    if (cp === undefined) continue
    const l = cp - base
    if (l >= 0 && l <= 25) code += String.fromCharCode(65 + l)
  }
  return code
}

interface CountryFlagProps {
  flag: string | null | undefined
  className?: string
}

export function CountryFlag({ flag, className }: CountryFlagProps): React.JSX.Element {
  const code = emojiToCountryCode(flag)
  if (code.length === 2) {
    return <span className={`flag:${code} ${className ?? ''}`} aria-label={code} />
  }
  return <span className={className ?? ''}>{flag}</span>
}