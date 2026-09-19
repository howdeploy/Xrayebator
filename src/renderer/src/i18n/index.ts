import i18n from 'i18next'
import { initReactI18next } from 'react-i18next'
import ru from './ru.json'
import en from './en.json'
import zh from './zh.json'

export const supportedLngs = ['ru', 'en', 'zh'] as const
export type SupportedLng = (typeof supportedLngs)[number]

export const LNG_STORAGE_KEY = 'xrayebator-language'

const storedLng = window.localStorage.getItem(LNG_STORAGE_KEY) as SupportedLng | null
const initialLng =
  storedLng && supportedLngs.includes(storedLng) ? storedLng : 'ru'

i18n.use(initReactI18next).init({
  resources: {
    ru: { translation: ru },
    en: { translation: en },
    zh: { translation: zh }
  },
  lng: initialLng,
  fallbackLng: 'en',
  interpolation: { escapeValue: false }
})

export function setLanguage(lng: SupportedLng): void {
  i18n.changeLanguage(lng)
  window.localStorage.setItem(LNG_STORAGE_KEY, lng)
}

export default i18n