import i18n from 'i18next'
import { initReactI18next } from 'react-i18next'
import ru from './ru.json'
import en from './en.json'
import zh from './zh.json'

export const supportedLngs = ['ru', 'en', 'zh'] as const
export type SupportedLng = (typeof supportedLngs)[number]

export const LNG_STORAGE_KEY = 'xrayebator-language'

/** Порядок файлов совпадает с supportedLngs — по индексу обновляем язык при HMR. */
const BUNDLE_FILES = ['./ru.json', './en.json', './zh.json']
const bundles: Record<SupportedLng, Record<string, unknown>> = {
  ru: ru as Record<string, unknown>,
  en: en as Record<string, unknown>,
  zh: zh as Record<string, unknown>
}

const storedLng = window.localStorage.getItem(LNG_STORAGE_KEY) as SupportedLng | null
const initialLng =
  storedLng && supportedLngs.includes(storedLng) ? storedLng : 'ru'

i18n.use(initReactI18next).init({
  resources: {
    ru: { translation: bundles.ru },
    en: { translation: bundles.en },
    zh: { translation: bundles.zh }
  },
  lng: initialLng,
  fallbackLng: 'en',
  interpolation: { escapeValue: false }
})

// i18next копирует строки в свой стор на ПЕРВОМ init. Правка JSON на живом
// dev-сервере обновляет модуль (Vite принимает JSON сам), но не строки в сторе —
// поэтому новый ключ показывался сырым («settings.profileSettingsTitle — happ»)
// до перезапуска приложения. Перезаливаем бандлы с overwrite: дёшево и снимает
// весь класс «сырых ключей».
function applyBundles(): void {
  for (const lng of supportedLngs) {
    i18n.addResourceBundle(lng, 'translation', bundles[lng], true, true)
  }
}

applyBundles()

if (import.meta.hot) {
  import.meta.hot.accept(BUNDLE_FILES, (updated) => {
    updated.forEach((mod, index) => {
      const bundle = (mod as { default?: Record<string, unknown> } | undefined)?.default
      if (!bundle) return
      const lng = supportedLngs[index]
      bundles[lng] = bundle
      i18n.addResourceBundle(lng, 'translation', bundle, true, true)
    })
  })
}

export function setLanguage(lng: SupportedLng): void {
  i18n.changeLanguage(lng)
  window.localStorage.setItem(LNG_STORAGE_KEY, lng)
}

export default i18n
