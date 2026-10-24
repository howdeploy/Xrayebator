import { Fragment, useEffect, useMemo, useRef, useState } from 'react'
import QRCode from 'qrcode'
import { Button, TextField, Label, Input, Chip, Spinner, AlertDialog, Dropdown, DropdownItem } from '@heroui/react'
import {
  Settings2,
  Layers,
  Waypoints,
  FileBadge,
  Cable,
  Boxes,
  Search,
  Filter,
  Database,
  Play,
  Trash2,
  Lock,
  CloudDownload,
  CloudOff,
  Fingerprint,
  Globe2,
  EthernetPort,
  Copy,
  Download,
  Check,
  ShieldOff,
  CalendarClock,
  CalendarX,
  Gauge,
  RefreshCw,
  Zap,
  ShieldCheck,
  ChevronDown,
  Link2
} from 'lucide-react'
import { useTranslation } from 'react-i18next'
import type {
  BackendEntry,
  BackendStatusResult,
  Dns01StatusResult,
  ProfilePqResult,
  Server,
  ServerProfile,
  SniEntry,
  SshAccessInput,
  SshProtectStatusResult
} from '@shared/types'
import { isDns01Ready, type Dns01Input, type Dns01Provider } from '@shared/dns01'
import { describeExpire, isFutureDate, presetDate } from '@shared/expire'
import {
  describeTraffic,
  formatBytes,
  isValidTrafficLimitInput,
  trafficLimitToInput
} from '@shared/traffic'
import { todayIso } from '@shared/calendar'
import { buildAwgVpnUrl, stripAwgComments } from '@shared/awg'
import { isSshAccessReady, SshAccessForm } from '../components/SshAccessForm'
import { CalendarPicker } from '../components/CalendarPicker'
import { copyText } from '../lib/clipboard'
import { shouldAutoConnectServer } from './server-access'
import { backendActionFailure } from './backend-action'
import styles from './ServerSettings.module.css'
import hystLogo from '../assets/hysteria-logo.svg'
import amneziaLogo from '../assets/amnezia-logo.jpg'

/**
 * Пропсы страницы сервера. Одна страница рисует два экрана (`mode`): настройки
 * (создание профиля, доп. протоколы, подписка и TLS) и список существующих
 * профилей. Это один компонент намеренно: оба экрана делят SSH-сессию, загрузку
 * данных и диалоги профиля, поэтому переключение между ними не повторяет
 * SSH-запрос и не сбрасывает введённое имя будущего профиля.
 */
export interface ServerPageProps {
  server: Server
  mode: 'settings' | 'profiles'
  /** Открыт по «Изменить доступ» с карточки сервера: показать форму, не автоподключаясь. */
  editingAccess?: boolean
  onBack: () => void
  /** Вкладка, на которую надо вернуться со страницы профилей. */
  initialSection?: SettingsSection
  /** Переход на страницу «Существующие профили». */
  onOpenProfiles?: () => void
  /** Со страницы профилей: вернуться в настройки на конкретный раздел. */
  onOpenSettings?: (section: SettingsSection) => void
}

const PROTOCOLS = [
  { id: 'xhttp', label: 'XHTTP' },
  { id: 'tcp', label: 'TCP' },
  { id: 'tcp-utls', label: 'TCP-uTLS' },
  { id: 'tcp-xudp', label: 'TCP-XUDP' },
  { id: 'tcp-mux', label: 'TCP-MUX' },
  { id: 'grpc', label: 'gRPC' }
] as const

export const FINGERPRINTS = [
  'chrome',
  'firefox',
  'safari',
  'edge',
  'ios',
  'random'
] as const

/**
 * Разделы экрана настроек. Раньше это была одна вертикальная стена из пяти секций:
 * оператору, которому нужен только список профилей (большинство визитов), приходилось
 * прокручивать блок подключения и форму создания.
 */
/**
 * Панели страницы настроек. «Существующие профили» здесь нет: список профилей
 * переехал на отдельную страницу (решение 2026-10-21), а на его месте осталась
 * форма создания — так вкладка и называется.
 */
export type SettingsSection = 'create' | 'backends' | 'subscription'
export const SETTINGS_SECTIONS: { id: SettingsSection; labelKey: string }[] = [
  { id: 'create', labelKey: 'settings.sectionCreate' },
  { id: 'backends', labelKey: 'settings.sectionBackends' },
  { id: 'subscription', labelKey: 'settings.sectionSubscription' }
]

/**
 * Порядок вкладок в верхней строке. Пункт «Существующие профили» стоит сразу
 * после создания, но это не панель, а переход на отдельную страницу: он не
 * скрывает разметку, а меняет экран.
 */
const SETTINGS_TABS: { id: SettingsSection | 'profiles'; labelKey: string }[] = [
  { id: 'create', labelKey: 'settings.sectionCreate' },
  { id: 'profiles', labelKey: 'settings.sectionProfiles' },
  { id: 'backends', labelKey: 'settings.sectionBackends' },
  { id: 'subscription', labelKey: 'settings.sectionSubscription' }
]

/**
 * Пропсы панели раздела. Раздел не размонтируется, а скрывается атрибутом `hidden`
 * (см. styles.sectionPane): иначе при переключении вкладки терялись бы введённые имя,
 * счётчик и выбранный протокол ещё не созданного профиля.
 */
export function sectionPaneProps(
  id: SettingsSection,
  active: SettingsSection
): React.ComponentProps<'div'> {
  return {
    id: `pane-${id}`,
    role: 'tabpanel',
    'aria-labelledby': `tab-${id}`,
    hidden: active !== id,
    className: styles.sectionPane
  }
}

/**
 * Диалоги подтверждения действий с бэкендами: заголовок и красная кнопка называют
 * конкретное действие. Раньше у всех шести был обезличенный заголовок «Подтвердите
 * действие» и кнопка «Готово» — на самом рискованном шаге оператор не читал, что
 * именно подтверждает (удаление Hysteria 2 и включение AWG 3.1 выглядели одинаково).
 */
const BACKEND_CONFIRM_ACTION_KEYS: Record<
  | 'hysteria2-uninstall'
  | 'awg-uninstall'
  | 'awg31-on'
  | 'awg31-off'
  | 'hysteria2-revoke-all'
  | 'awg-revoke-all',
  string
> = {
  'hysteria2-uninstall': 'settings.backendsActionHystUninstall',
  'awg-uninstall': 'settings.backendsActionAwgUninstall',
  'awg31-on': 'settings.backendsActionAwg31On',
  'awg31-off': 'settings.backendsActionAwg31Off',
  'hysteria2-revoke-all': 'settings.backendsActionRevokeHystAll',
  'awg-revoke-all': 'settings.backendsActionRevokeAwgAll'
}

/**
 * Состояние бэкенда: «установлен» ≠ «работает». Подпись и цвет берутся из ОДНОГО
 * признака — раньше текст шёл от `installed`, а зелёный цвет от `state`, поэтому
 * упавший после перезагрузки AWG рисовался серым «Активен · UDP …» (живой
 * дефект: модуль amneziawg не загрузился, интерфейса нет, туннель лежит).
 * `down` — установлен, но юнит/интерфейс не поднят: это чинится кнопкой
 * «Запустить», а не переустановкой.
 */
type BackendTone = 'ok' | 'down' | 'absent'

function backendTone(entry: BackendEntry | undefined): BackendTone {
  if (!entry?.installed) return 'absent'
  return entry.state === 'active' ? 'ok' : 'down'
}

const BACKEND_TONE_CLASS: Record<BackendTone, string> = {
  ok: styles.backendStateOk,
  down: styles.backendStateDown,
  absent: ''
}

export const SNI_CATEGORIES = [  'ru_whitelist',
  'yandex_cdn',
  'foreign',
  'fallback'
] as const

export const PORT_PRESETS = [443, 8443, 2053, 2083, 2087, 2096, 9443, 8080] as const

/** Пресеты лимита трафика для диалога профиля. */
export const TRAFFIC_PRESETS = ['10GB', '50GB', '100GB', '500GB', '1TB'] as const

export function ServerPage({
  server,
  editingAccess = false,
  onBack,
  mode,
  initialSection,
  onOpenProfiles,
  onOpenSettings
}: ServerPageProps): React.JSX.Element {
  const { t } = useTranslation()
  const [access, setAccess] = useState<SshAccessInput>({
    username: server.username || 'root',
    authMethod: server.authMethod ?? 'password',
    password: '',
    passwordCredentialId: server.passwordCredentialId ?? undefined,
    passwordPersisted: server.passwordPersisted ?? undefined,
    privateKeyPath: server.privateKeyPath ?? undefined,
    privateKeyCredentialId: server.privateKeyCredentialId ?? undefined,
    privateKeyName: server.privateKeyName ?? undefined,
    privateKeyPersisted: server.privateKeyPersisted ?? undefined,
    passphrase: '',
    privilegeMode: server.privilegeMode ?? 'root',
    sudoPassword: ''
  })
  const [busy, setBusy] = useState(false)
  const autoConnectStarted = useRef(false)
  const [profiles, setProfiles] = useState<ServerProfile[] | null>(null)
  const [backends, setBackends] = useState<BackendStatusResult | null>(null)
  const [backendsLoading, setBackendsLoading] = useState(false)
  const [backendsError, setBackendsError] = useState<string | null>(null)
  const [backendBusy, setBackendBusy] = useState<string | null>(null)
  const [confirmBackend, setConfirmBackend] = useState<
    | 'hysteria2-uninstall'
    | 'awg-uninstall'
    | 'awg31-on'
    | 'awg31-off'
    | 'hysteria2-revoke-all'
    | 'awg-revoke-all'
    | null
  >(null)
  // Имя профиля, у которого раскрыта панель действий (одна кнопка «Настройки» вместо
  // строки из одиннадцати кнопок — она выдавливала текст профиля в столбик).
  const [actionTarget, setActionTarget] = useState<{
    kind: 'profile' | 'hysteria2' | 'awg'
    profile: ServerProfile
  } | null>(null)
  // QR-модалка выдачи ключей бэкенд-боксов. Диалог «Ключи» убран:
  // полное копирование только на странице Ключей (решение 2026-10-06).
  const [keysQrUrl, setKeysQrUrl] = useState<string | null>(null)
  const [keysQrData, setKeysQrData] = useState<string | null>(null)
  const qrModalRef = useRef<HTMLDivElement>(null)
  const [error, setError] = useState<string | null>(null)
  const [toast, setToast] = useState<string | null>(null)
  // Раздел настроек. Панели скрываются атрибутом hidden (см. styles.sectionPane),
  // поэтому введённое в форме имя и счётчик не теряются при переключении.
  const [section, setSection] = useState<SettingsSection>(initialSection ?? 'create')
  /** Поиск по странице профилей: имя, SNI или ссылка подписки. */
  const [profileQuery, setProfileQuery] = useState('')
  /** Фильтр списка профилей: все, только активные, только отключённые. */
  const [profileFilter, setProfileFilter] = useState<'all' | 'active' | 'disabled'>('all')

  /**
   * Экран не размонтируется при переключении (иначе повторялся SSH-запрос),
   * поэтому раздел, выбранный вкладкой со страницы профилей, приходит пропсом:
   * применяем его, не пересоздавая страницу.
   */
  useEffect(() => {
    if (initialSection) setSection(initialSection)
  }, [initialSection])
  const [hostKeyFingerprint, setHostKeyFingerprint] = useState<string | null>(
    server.hostKeyFingerprint ?? null
  )
  const [confirmHostKeyReset, setConfirmHostKeyReset] = useState(false)
  const [hostKeyResetBusy, setHostKeyResetBusy] = useState(false)

  const [name, setName] = useState('')
  const [transport, setTransport] = useState('xhttp')
  const [count, setCount] = useState('1')
  const [creating, setCreating] = useState(false)
  // Выбор мультипротокольного бэкенда в «Создать профиль»: клик по карточке
  // = только выбор (как у VLESS-транспортов), создание — кнопкой «Создать профиль».
  const [backendSel, setBackendSel] = useState<'hysteria2' | 'awg' | null>(null)
  const [createExpire, setCreateExpire] = useState('')
  const [createExpireOpen, setCreateExpireOpen] = useState(false)

  const [updating, setUpdating] = useState(false)
  const [uninstalling, setUninstalling] = useState(false)
  const [confirmUninstall, setConfirmUninstall] = useState(false)
  const [confirmRemove, setConfirmRemove] = useState<ServerProfile | null>(null)

  const [fpTarget, setFpTarget] = useState<ServerProfile | null>(null)
  const [fpRoute, setFpRoute] = useState<number>(1)
  const [fpValue, setFpValue] = useState<string>('firefox')
  const [fpBusy, setFpBusy] = useState(false)
  const [fpDone, setFpDone] = useState(false)
  // Ошибка показывается В САМОМ диалоге: страница за оверлеем, и баннер вверху
  // оператор просто не видит, оставаясь с открытым диалогом и без объяснения.
  const [fpError, setFpError] = useState<string | null>(null)

  const [sniTarget, setSniTarget] = useState<ServerProfile | null>(null)
  const [sniRoute, setSniRoute] = useState<number>(1)
  const [sniValue, setSniValue] = useState('')
  const [sniBusy, setSniBusy] = useState(false)
  const [sniDone, setSniDone] = useState(false)
  const [sniList, setSniList] = useState<SniEntry[] | null>(null)
  const [sniError, setSniError] = useState<string | null>(null)

  const [portTarget, setPortTarget] = useState<ServerProfile | null>(null)
  const [portRoute, setPortRoute] = useState<number>(1)
  const [portMode, setPortMode] = useState<'preset' | 'custom' | 'random'>('random')
  const [portValue, setPortValue] = useState('')
  const [portBusy, setPortBusy] = useState(false)
  const [portDone, setPortDone] = useState(false)
  const [portError, setPortError] = useState<string | null>(null)

  // Revoke: выбор «только ссылка» / «полный отзыв» → подтверждение → выполнение.
  const [revokeTarget, setRevokeTarget] = useState<ServerProfile | null>(null)
  const [revokeStep, setRevokeStep] = useState<'choose' | 'confirm' | 'done'>('choose')
  const [revokeBusy, setRevokeBusy] = useState(false)
  const [revokeUrl, setRevokeUrl] = useState<string | null>(null)
  const [revokeFullOnly, setRevokeFullOnly] = useState(false)

  const [expireTarget, setExpireTarget] = useState<ServerProfile | null>(null)
  const [expireChooser, setExpireChooser] = useState<ServerProfile[] | null>(null)
  const [expireDate, setExpireDate] = useState('')
  const [expireBusy, setExpireBusy] = useState(false)
  const [expireDone, setExpireDone] = useState(false)

  const [limitTarget, setLimitTarget] = useState<ServerProfile | null>(null)
  const [limitValue, setLimitValue] = useState('')
  const [limitReset, setLimitReset] = useState(false)
  const [limitBusy, setLimitBusy] = useState(false)
  const [limitDone, setLimitDone] = useState(false)

  // Подписка (DNS-01) и мониторинг (Telegram): грузятся параллельно с профилями,
  // best-effort — сервер со старым менеджером не должен ломать страницу.
  const [dns01Status, setDns01Status] = useState<Dns01StatusResult | null>(null)
  const [dns01Error, setDns01Error] = useState<string | null>(null)
  const [dns01Open, setDns01Open] = useState(false)
  const [dns01Provider, setDns01Provider] = useState<Dns01Provider>('cloudflare')
  const [dns01Domain, setDns01Domain] = useState('')
  const [dns01Token, setDns01Token] = useState('')
  const [dns01AwsKeyId, setDns01AwsKeyId] = useState('')
  const [dns01AwsSecret, setDns01AwsSecret] = useState('')
  const [dns01Busy, setDns01Busy] = useState(false)
  // Защита SSH от перебора: отдельный серверный статус (fail2ban + лимиты sshd).
  const [sshProtect, setSshProtect] = useState<SshProtectStatusResult | null>(null)
  const [sshProtectBusy, setSshProtectBusy] = useState(false)
  const [sshProtectError, setSshProtectError] = useState<string | null>(null)
  const [pqTarget, setPqTarget] = useState<ServerProfile | null>(null)
  const [pqTransport, setPqTransport] = useState<string>('tcp')
  const [pqBusy, setPqBusy] = useState(false)
  const [pqError, setPqError] = useState<string | null>(null)
  const [pqResult, setPqResult] = useState<ProfilePqResult | null>(null)

  const connected = profiles !== null
  const accessReady = isSshAccessReady(access)

  const futureNames = useMemo(() => {
    const base = name.trim() || 'phone-1'
    const n = Math.min(Math.max(Number(count) || 1, 1), 50)
    const list: string[] = []
    for (let i = 1; i <= n; i++) {
      list.push(i === 1 ? base : `${base}-${i}`)
    }
    return list
  }, [name, count])

  const toastText = (text: string): void => {
    setToast(text)
    setTimeout(() => setToast(null), 1800)
  }

  const load = async (): Promise<void> => {
    if (!accessReady) {
      setError(t('settings.errorPassword'))
      return
    }
    setBusy(true)
    setError(null)
    try {
      // Бэкенды грузятся ПАРАЛЛЕЛЬНО с профилями (фидбек: не заставлять ждать).
      setBackendsLoading(true)
      const backendsP = window.api.backends
        .status(server.id, access)
        .then((b) => {
          setBackends(b)
          setBackendsError(null)
        })
        .catch((err: unknown) => {
          setBackends(null)
          setBackendsError(err instanceof Error ? err.message : String(err))
        })
        .finally(() => setBackendsLoading(false))
      const result = await window.api.profiles.list(server.id, access)
      setProfiles(result.profiles ?? [])
      await backendsP
      // Состояние подписки — параллельно и best-effort: его отсутствие
      // (старый менеджер на сервере) не должно ронять страницу профилей.
      void window.api.dns01
        .status(server.id, access)
        .then((s) => {
          setDns01Status(s)
          setDns01Error(null)
          if (s.domain) setDns01Domain(s.domain)
        })
        .catch((err: unknown) =>
          setDns01Error(err instanceof Error ? err.message : String(err))
        )
      // Защита SSH — тоже best-effort: сервер со старым менеджером её не знает,
      // и это не должно ронять ни профили, ни подписку.
      void window.api.security
        .sshProtectStatus(server.id, access)
        .then((s) => {
          setSshProtect(s)
          setSshProtectError(s.ok ? null : s.error ?? null)
        })
        .catch((err: unknown) =>
          setSshProtectError(err instanceof Error ? err.message : String(err))
        )
      const refreshed = await window.api.servers.get(server.id)
      setHostKeyFingerprint(refreshed?.hostKeyFingerprint ?? null)
      if (refreshed) {
        setAccess((current) => ({
          ...current,
          passwordCredentialId: refreshed.passwordCredentialId ?? current.passwordCredentialId,
          passwordPersisted: refreshed.passwordPersisted ?? current.passwordPersisted,
          password: refreshed.passwordPersisted ? '' : current.password
        }))
      }
    } catch (err) {
      setProfiles(null)
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  useEffect(() => {
    if (autoConnectStarted.current) return
    autoConnectStarted.current = true
    if (editingAccess) return
    if (shouldAutoConnectServer(server)) void load()
  }, [server.id])

  useEffect(() => {
    if (!keysQrUrl) return
    // Оверлей забирает фокус сам: иначе Esc и Tab остаются в интерфейсе под ним.
    qrModalRef.current?.focus()
    const onEsc = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') setKeysQrUrl(null)
    }
    document.addEventListener('keydown', onEsc)
    return () => document.removeEventListener('keydown', onEsc)
  }, [keysQrUrl])

  /**
   * Окно настроек профиля закрывается само, когда из него открыли вложенный диалог
   * (SNI, порт, срок, лимит, отзыв, удаление): два AlertDialog одновременно не нужны.
   */
  useEffect(() => {
    if (
      sniTarget ||
      fpTarget ||
      portTarget ||
      pqTarget ||
      expireTarget ||
      limitTarget ||
      revokeTarget ||
      confirmRemove
    ) {
      setActionTarget(null)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sniTarget, fpTarget, portTarget, pqTarget, expireTarget, limitTarget, revokeTarget, confirmRemove])

  const dns01Input = (): Dns01Input => ({
    domain: dns01Domain.trim(),
    provider: dns01Provider,
    token: dns01Token,
    awsKeyId: dns01AwsKeyId,
    awsSecret: dns01AwsSecret
  })

  /**
   * DNS-01: `setup` — поднять подписку по домену (порт 80 не нужен), `repair` —
   * заменить деградированную http_tls-подписку. Креденшелы после успеха забываем:
   * они уже лежат на сервере в 0600-root файле, в renderer'е им делать нечего.
   */
  const runDns01 = async (kind: 'setup' | 'repair'): Promise<void> => {
    if (!accessReady) {
      setError(t('settings.errorPassword'))
      return
    }
    const input = dns01Input()
    if (!isDns01Ready(input)) {
      setDns01Error(t('settings.dns01Incomplete'))
      return
    }
    setDns01Busy(true)
    setDns01Error(null)
    try {
      const res =
        kind === 'repair'
          ? await window.api.dns01.repair(server.id, access, input)
          : await window.api.dns01.setup(server.id, access, input)
      if (!res.ok) {
        setDns01Error(res.error ?? t('settings.dns01Failed'))
        return
      }
      setDns01Status(await window.api.dns01.status(server.id, access))
      setDns01Token('')
      setDns01AwsSecret('')
      setDns01Open(false)
      toastText(res.skipped ? t('settings.dns01Skipped') : t('settings.dns01Done'))
    } catch (err) {
      setDns01Error(err instanceof Error ? err.message : String(err))
    } finally {
      setDns01Busy(false)
    }
  }

  /**
   * Защита SSH: одна кнопка, два направления. Статус после действия приходит тем
   * же JSON-ответом, поэтому отдельный запрос не нужен. Парольный вход защита не
   * выключает — иначе GUI перестал бы управлять сервером (он ходит по SSH-паролю).
   */
  const toggleSshProtect = async (enable: boolean): Promise<void> => {
    if (!accessReady) {
      setError(t('settings.errorPassword'))
      return
    }
    setSshProtectBusy(true)
    setSshProtectError(null)
    try {
      const res = enable
        ? await window.api.security.sshProtectEnable(server.id, access)
        : await window.api.security.sshProtectDisable(server.id, access)
      setSshProtect(res)
      if (res.ok !== true) {
        setSshProtectError(res.error ?? t('settings.sshProtectFailed'))
        return
      }
      toastText(enable ? t('settings.sshProtectOnToast') : t('settings.sshProtectOffToast'))
    } catch (err) {
      setSshProtectError(err instanceof Error ? err.message : String(err))
    } finally {
      setSshProtectBusy(false)
    }
  }

  /** Перечитать статус защиты (например, после ручного разбана по SSH). */
  const refreshSshProtect = async (): Promise<void> => {
    setSshProtectBusy(true)
    setSshProtectError(null)
    try {
      const res = await window.api.security.sshProtectStatus(server.id, access)
      setSshProtect(res)
      if (res.ok !== true) setSshProtectError(res.error ?? t('settings.sshProtectFailed'))
    } catch (err) {
      setSshProtectError(err instanceof Error ? err.message : String(err))
    } finally {
      setSshProtectBusy(false)
    }
  }

  /**
   * PQ-маршрут профиля: VLESS Encryption живёт на отдельном порту (decryption —
   * свойство инбаунда), поэтому клиенту нужен ML-KEM, а в обычной v2ray-подписке
   * маршрут скрыт — иначе клиенты без PQ получили бы мёртвый ключ.
   */
  const addPqRoute = async (): Promise<void> => {
    if (!pqTarget) return
    setPqBusy(true)
    setPqError(null)
    try {
      const res = await window.api.profiles.addPq(server.id, access, {
        name: pqTarget.name,
        transport: pqTransport as 'tcp'
      })
      if (!res.ok) {
        setPqError(res.error ?? t('settings.pqFailed'))
        return
      }
      setPqResult(res)
      const fresh = await window.api.profiles.list(server.id, access)
      setProfiles(fresh.profiles ?? [])
    } catch (err) {
      setPqError(err instanceof Error ? err.message : String(err))
    } finally {
      setPqBusy(false)
    }
  }

  const create = async (): Promise<void> => {
    if (!accessReady) {
      setError(t('settings.errorPassword'))
      return
    }
    if (!name.trim()) {
      setError(t('settings.errorName'))
      return
    }
    // Pre-check коллизии имени (см. createBackendProfiles).
    const nameCollision = futureNames.find((nm) =>
      (profiles ?? []).some((p) => p.name === nm)
    )
    if (nameCollision) {
      setError(t('settings.errorNameExists', { name: nameCollision }))
      return
    }
    setBusy(true)
    setCreating(true)
    setError(null)
    const beforeNames = new Set((profiles ?? []).map((p) => p.name))
    let createdCount = 0
    let failedMessage: string | null = null
    try {
      const result = await window.api.profiles.create(server.id, access, {
        name: name.trim(),
        transport,
        count: Math.min(Math.max(Number(count) || 1, 1), 50),
        ...(createExpire && isFutureDate(createExpire, Date.now())
          ? { expire: createExpire }
          : {})
      })
      if (result.ok && result.names.length > 0) {
        createdCount = result.names.length
      } else {
        failedMessage = result.errors[0] ?? t('settings.createFailed')
      }
    } catch (err) {
      failedMessage = err instanceof Error ? err.message : String(err)
    }
    // Профили могли создаться на сервере, даже если ответ не распарсился —
    // всегда перечитываем список, чтобы показать реальное состояние.
    try {
      const fresh = await window.api.profiles.list(server.id, access)
      setProfiles(fresh.profiles ?? [])
      // Если create вернул ошибку парсинга («пустой ответ»), но заказанные
      // профили реально появились на сервере — считаем создание успешным.
      if (createdCount === 0 && failedMessage) {
        const newlyAppeared = (fresh.profiles ?? []).filter(
          (p) => futureNames.includes(p.name) && !beforeNames.has(p.name)
        )
        if (newlyAppeared.length > 0) {
          createdCount = newlyAppeared.length
          failedMessage = null
        }
      }
    } catch {
      // список не критичен, ошибку создания уже показываем
    }
    if (createdCount > 0) {
      toastText(t('settings.created', { count: createdCount }))
      setName('')
    } else if (failedMessage) {
      setError(failedMessage)
    }
    setBusy(false)
    setCreating(false)
  }

  const remove = async (profile: ServerProfile): Promise<void> => {
    if (!accessReady) return
    setBusy(true)
    setError(null)
    try {
      const result = await window.api.profiles.remove(server.id, access, profile.name)
      if (result.ok) {
        toastText(t('settings.deleted', { name: profile.name }))
        setProfiles((prev) => (prev ?? []).filter((p) => p.name !== profile.name))
      } else {
        // Удаление могло пройти на сервере, даже если ответ не распарсился.
        // Перечитываем список: профиля больше нет — считаем удаление успешным.
        const fresh = await window.api.profiles.list(server.id, access)
        const stillThere = (fresh.profiles ?? []).some((p) => p.name === profile.name)
        if (stillThere) {
          setError(result.error ?? t('settings.deleteFailed'))
        } else {
          toastText(t('settings.deleted', { name: profile.name }))
          setProfiles(fresh.profiles ?? [])
        }
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  const changeFingerprint = async (): Promise<void> => {
    if (!fpTarget || !accessReady) return
    setFpBusy(true)
    setError(null)
    setFpError(null)
    const input = {
      name: fpTarget.name,
      fingerprint: fpValue,
      ...(fpTarget.multi_route ? { route: fpRoute - 1 } : {})
    }
    try {
      const result = await window.api.profiles.changeFingerprint(server.id, access, input)
      if (result.ok) {
        toastText(t('settings.fpChanged', { name: fpTarget.name, fp: result.fingerprint ?? fpValue }))
        const fresh = await window.api.profiles.list(server.id, access)
        setProfiles(fresh.profiles ?? [])
        setFpDone(true)
        setTimeout(() => {
          setFpTarget(null)
          setFpDone(false)
        }, 400)
      } else {
        setFpError(result.error ?? t('settings.fpFailed'))
      }
    } catch (err) {
      setFpError(err instanceof Error ? err.message : String(err))
    } finally {
      setFpBusy(false)
    }
  }

  const changeSni = async (): Promise<void> => {
    if (!sniTarget || !sniValue.trim() || !accessReady) return
    setSniBusy(true)
    setError(null)
    setSniError(null)
    const input = {
      name: sniTarget.name,
      sni: sniValue.trim(),
      ...(sniTarget.multi_route ? { route: sniRoute - 1 } : {})
    }
    try {
      const result = await window.api.profiles.changeSni(server.id, access, input)
      if (result.ok) {
        toastText(t('settings.sniChanged', { name: sniTarget.name, sni: result.sni ?? input.sni }))
        const fresh = await window.api.profiles.list(server.id, access)
        setProfiles(fresh.profiles ?? [])
        setSniDone(true)
        setTimeout(() => {
          setSniTarget(null)
          setSniDone(false)
        }, 400)
      } else {
        setSniError(result.error ?? t('settings.sniFailed'))
      }
    } catch (err) {
      setSniError(err instanceof Error ? err.message : String(err))
    } finally {
      setSniBusy(false)
    }
  }

  const changePort = async (): Promise<void> => {
    if (!portTarget || !accessReady) return
    setPortBusy(true)
    setError(null)
    setPortError(null)
    const input = {
      name: portTarget.name,
      port: portMode === 'random' ? ('random' as const) : Number(portValue),
      ...(portTarget.multi_route ? { route: portRoute - 1 } : {})
    }
    try {
      const result = await window.api.profiles.changePort(server.id, access, input)
      if (result.ok) {
        const fresh = await window.api.profiles.list(server.id, access)
        setProfiles(fresh.profiles ?? [])
        if (result.firewall_warning) {
          // Предупреждение тоже показываем в диалоге: страница за оверлеем.
          setPortError(t('settings.firewallWarning'))
          return
        }
        toastText(t('settings.portChanged', { name: portTarget.name, port: result.port ?? input.port }))
        setPortDone(true)
        setTimeout(() => {
          setPortTarget(null)
          setPortDone(false)
        }, 400)
      } else {
        setPortError(result.error ?? t('settings.portFailed'))
      }
    } catch (err) {
      setPortError(err instanceof Error ? err.message : String(err))
    } finally {
      setPortBusy(false)
    }
  }

  const copyUrl = async (profile: ServerProfile): Promise<void> => {
    if (!profile.subscription_url) return
    const ok = await copyText(profile.subscription_url)
    toastText(ok ? t('settings.copied') : t('settings.copyFailed'))
  }

  /**
   * Копирование с честным тостом. `navigator.clipboard` может отказать (нет
   * разрешения, нет API) — без проверки пользователь видел «Скопировано!» и уносил
   * в чат пустой буфер.
   */
  const copyWithToast = async (text: string, okMessage: string): Promise<void> => {
    const ok = await copyText(text)
    toastText(ok ? okMessage : t('settings.copyFailed'))
  }

  const openRevoke = (profile: ServerProfile, forceFull = false): void => {
    setRevokeTarget(profile)
    setRevokeFullOnly(forceFull)
    setRevokeStep(forceFull ? 'confirm' : 'choose')
    setRevokeUrl(null)
  }

  const runRevoke = async (mode: 'token' | 'full'): Promise<void> => {
    if (!revokeTarget || !accessReady) return
    setRevokeBusy(true)
    setError(null)
    try {
      const result = await window.api.profiles.revoke(server.id, access, {
        name: revokeTarget.name,
        full: mode === 'full'
      })
      if (result.ok) {
        setRevokeUrl(result.subscription_url ?? null)
        setRevokeStep('done')
        toastText(
          t(mode === 'full' ? 'settings.revokedFull' : 'settings.revoked', {
            name: revokeTarget.name
          })
        )
        const fresh = await window.api.profiles.list(server.id, access)
        setProfiles(fresh.profiles ?? [])
      } else {
        setError(result.error ?? t('settings.revokeFailed'))
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setRevokeBusy(false)
    }
  }

  const openExpire = (profile: ServerProfile): void => {
    setExpireTarget(profile)
    setExpireDate(
      profile.expire
        ? describeExpire(profile.expire, false, Date.now(), profile.expire_date).date
        : ''
    )
    setExpireDone(false)
  }

  const applyExpire = async (value: string | null): Promise<void> => {
    if (!expireTarget || !accessReady) return
    setExpireBusy(true)
    setError(null)
    try {
      const result = await window.api.profiles.setExpire(server.id, access, {
        name: expireTarget.name,
        expire: value
      })
      if (result.ok) {
        toastText(
          value
            ? t('settings.expireChanged', { name: expireTarget.name, date: value })
            : t('settings.expireCleared', { name: expireTarget.name })
        )
        const fresh = await window.api.profiles.list(server.id, access)
        setProfiles(fresh.profiles ?? [])
        setExpireDone(true)
        setTimeout(() => {
          setExpireTarget(null)
          setExpireDone(false)
        }, 400)
      } else {
        setError(result.error ?? t('settings.expireFailed'))
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setExpireBusy(false)
    }
  }

  /** Чип срока в карточке профиля: дата, «истёк», «скоро истекает» или ничего. */
  const expireChip = (profile: ServerProfile): React.JSX.Element | null => {
    const now = Date.now()
    const info = describeExpire(
      profile.expire ?? 0,
      profile.expire_disabled === true,
      now,
      profile.expire_date
    )
    if (info.status === 'none') return null
    const expired = info.status === 'expired'
    // Предупреждаем за 3 дня: время продлить срок до автоотключения сервером.
    const soon = !expired && profile.expire * 1000 - now < 3 * 24 * 60 * 60 * 1000
    const tone = expired ? styles.expireChipDanger : soon ? styles.expireChipWarn : ''
    return (
      <Chip
        size="sm"
        color="default"
        className={`${styles.expireChip} ${tone}`}
        title={t(
          expired
            ? 'settings.expireHintExpired'
            : soon
              ? 'settings.expireHintSoon'
              : 'settings.expireHint'
        )}
      >
        <span className={styles.chipWithIcon}>
          <CalendarClock size={14} />
          {expired
            ? t('settings.expireExpired')
            : t('settings.expireUntil', { date: info.date })}
        </span>
      </Chip>
    )
  }

  /**
   * Сервер старой версии не отдаёт поле expire: управление сроками недоступно.
   * Без этой проверки GUI молча показывал «бессрочно» — как будто срока нет.
   */
  const expireSupported = (profiles ?? []).some((p) => p.expire_supported === true)

  const openLimit = (profile: ServerProfile): void => {
    setLimitTarget(profile)
    setLimitValue(trafficLimitToInput(profile.traffic_limit ?? 0))
    setLimitReset(false)
    setLimitDone(false)
  }

  const applyLimit = async (limit: string | null, reset: boolean): Promise<void> => {
    if (!limitTarget || !accessReady) return
    setLimitBusy(true)
    setError(null)
    try {
      const result = await window.api.profiles.setLimit(server.id, access, {
        name: limitTarget.name,
        limit,
        reset
      })
      if (result.ok) {
        if (limit === 'none') {
          toastText(t('settings.trafficCleared', { name: limitTarget.name }))
        } else if (limit) {
          toastText(t('settings.trafficChanged', { name: limitTarget.name, limit }))
        } else {
          toastText(t('settings.trafficResetDone', { name: limitTarget.name }))
        }
        const fresh = await window.api.profiles.list(server.id, access)
        setProfiles(fresh.profiles ?? [])
        setLimitDone(true)
        setTimeout(() => {
          setLimitTarget(null)
          setLimitDone(false)
        }, 400)
      } else {
        setError(result.error ?? t('settings.trafficFailed'))
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLimitBusy(false)
    }
  }

  /** Чип трафика в карточке профиля: «использовано / лимит» или «лимит исчерпан». */
  const trafficChip = (profile: ServerProfile): React.JSX.Element | null => {
    if (!profile.traffic_supported) return null
    const used = profile.traffic_used ?? 0
    const limit = profile.traffic_limit ?? 0
    const info = describeTraffic(used, limit, profile.traffic_disabled === true)
    if (info.status === 'none') return null
    const danger = info.status === 'disabled' || info.status === 'exceeded'
    const warn = info.status === 'warn'
    const label = danger
      ? t('settings.trafficChipExceeded')
      : limit > 0
        ? `${formatBytes(used)} / ${formatBytes(limit)}`
        : formatBytes(used)
    const title =
      info.status === 'disabled'
        ? t('settings.trafficDisabledTitle')
        : info.status === 'exceeded'
          ? t('settings.trafficChipExceededTitle')
          : warn
            ? t('settings.trafficChipWarnTitle')
            : t('settings.trafficChipTitle')
    return (
      <Chip
        size="sm"
        color="default"
        className={`${styles.expireChip} ${
          danger ? styles.expireChipDanger : warn ? styles.expireChipWarn : ''
        }`}
        title={title}
      >
        <span className={styles.chipWithIcon}>
          <Database size={14} />
          {t('settings.trafficShort')}: {label}
        </span>
      </Chip>
    )
  }

  /**
   * Сервер старой версии не отдаёт traffic-поля: управление лимитом скрыто.
   * Как и у expire, отличает «лимита нет» от «сервер не умеет лимиты».
   */
  const trafficSupported = (profiles ?? []).some((p) => p.traffic_supported === true)

  const limitInputValue = limitValue.trim()
  const limitInputValid =
    limitInputValue === '' || isValidTrafficLimitInput(limitInputValue)
  const canSaveLimit =
    limitInputValue !== '' ? isValidTrafficLimitInput(limitInputValue) : limitReset

  const updateServer = async (branch?: 'main' | 'dev' | 'experimental'): Promise<void> => {
    if (!accessReady) return
    setBusy(true)
    setUpdating(true)
    setError(null)
    try {
      const result = await window.api.server.update(server.id, access, branch)
      if (result.ok) {
        toastText(t('settings.updated'))
      } else {
        setError(result.error ?? t('settings.updateFailed'))
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
      setUpdating(false)
    }
  }

  const reloadBackends = async (): Promise<void> => {
    try {
      setBackends(await window.api.backends.status(server.id, access))
      setBackendsError(null)
    } catch (err) {
      setBackendsError(err instanceof Error ? err.message : String(err))
    }
    try {
      const fresh = await window.api.profiles.list(server.id, access)
      if (fresh.ok) setProfiles(fresh.profiles)
    } catch {
      // профили уже загружены ранее — молча оставляем как есть
    }
  }

  const runBackendAction = async (
    id: string,
    action: () => Promise<unknown>
  ): Promise<void> => {
    if (!accessReady) return
    setBusy(true)
    setBackendBusy(id)
    setError(null)
    try {
      const result = await action()
      // Отказ может прийти и без исключения — `{ok:false, error}`. Без этой
      // проверки клик по «Установить» выглядел как «ничего не произошло»
      // (живой случай: awg-install вернул reboot_required с объяснением).
      const outcome = backendActionFailure(result)
      if (outcome.failed) {
        setError(outcome.error ?? t('settings.backendActionFailed'))
        return
      }
      await reloadBackends()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
      setBackendBusy(null)
    }
  }

  const installHysteria2 = (): Promise<void> =>
    runBackendAction('hysteria2-install', () =>
      window.api.backends.hysteria2Install(server.id, access, true)
    )
  const uninstallHysteria2 = (): Promise<void> => {
    setConfirmBackend(null)
    return runBackendAction('hysteria2-uninstall', () =>
      window.api.backends.hysteria2Uninstall(server.id, access)
    )
  }
  const toggleSubbody = (): Promise<void> =>
    runBackendAction('subbody', () =>
      window.api.backends.hysteria2Subbody(
        server.id,
        access,
        !(backends?.backends.hysteria2?.sub_body ?? false)
      )
    )
  const installAwg = (): Promise<void> =>
    runBackendAction('awg-install', () =>
      window.api.backends.awgInstall(server.id, access, true)
    )
  const uninstallAwg = (): Promise<void> => {
    setConfirmBackend(null)
    return runBackendAction('awg-uninstall', () =>
      window.api.backends.awgUninstall(server.id, access)
    )
  }
  const toggle31 = (on: boolean): Promise<void> => {
    setConfirmBackend(null)
    return runBackendAction('awg31', () => window.api.backends.awg31(server.id, access, on))
  }
  const startBackend = (type: 'hysteria2' | 'awg'): Promise<void> =>
    runBackendAction(`${type}-start`, () => window.api.backends.start(server.id, access, type))

  // Revoke/Срок на карточках бэкендов: креденшелы per-profile, поэтому
  // операции идут по всем профилям с грантом этого бэкенда.
  const grantedBackendProfiles = (kind: 'hysteria2' | 'awg'): ServerProfile[] =>
    (profiles ?? []).filter((p) => p.backends?.[kind])

  const revokeBackendKeys = (kind: 'hysteria2' | 'awg'): Promise<void> => {
    setConfirmBackend(null)
    const targets = grantedBackendProfiles(kind)
    return runBackendAction(`${kind}-revoke-all`, async () => {
      for (const p of targets) {
        if (kind === 'hysteria2') {
          await window.api.backends.hysteria2Grant(server.id, access, p.name)
        } else {
          await window.api.backends.awgGrant(server.id, access, p.name)
        }
      }
    })
  }

  const openBackendExpiry = (kind: 'hysteria2' | 'awg'): void => {
    const granted = grantedBackendProfiles(kind)
    if (granted.length === 0) return
    if (granted.length === 1) {
      setExpireChooser(null)
      setExpireTarget(granted[0])
    } else {
      setExpireChooser(granted)
    }
  }

  const showKeysQr = async (data: string): Promise<void> => {
    setKeysQrUrl(data)
    setKeysQrData(null)
    const dataUrl = await QRCode.toDataURL(data, { width: 320, margin: 2 })
    setKeysQrData(dataUrl)
  }

  const forgetHostKey = async (): Promise<void> => {
    setHostKeyResetBusy(true)
    setError(null)
    try {
      await window.api.servers.forgetHostKey(server.id)
      setHostKeyFingerprint(null)
      setConfirmHostKeyReset(false)
      toastText(t('sshAccess.hostKeyResetDone'))
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setHostKeyResetBusy(false)
    }
  }

  const uninstallServer = async (): Promise<void> => {
    if (!accessReady) return
    setConfirmUninstall(false)
    setBusy(true)
    setUninstalling(true)
    setError(null)
    try {
      const result = await window.api.server.uninstall(server.id, access)
      if (result.ok) {
        toastText(t('settings.uninstalled'))
      } else {
        setError(result.error ?? t('settings.uninstallFailed'))
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
      setUninstalling(false)
    }
  }

  // Создание профиля бэкенда из карточки в «Создать профиль»:
  // тот же профиль (имя/количество/срок из общей формы), плюс сразу
  // выдаётся ключ выбранного протокола (hysteria2/awg attach).
  const createBackendProfiles = async (kind: 'hysteria2' | 'awg'): Promise<void> => {
    if (!accessReady) {
      setError(t('settings.errorPassword'))
      return
    }
    if (!name.trim()) {
      setError(t('settings.errorName'))
      return
    }
    // Pre-check: удаление по имени снимает ВСЕ ключи профиля (маршруты +
    // бэкенды), поэтому коллизию имени ловим до создания, а не после.
    const nameCollision = futureNames.find((nm) =>
      (profiles ?? []).some((p) => p.name === nm)
    )
    if (nameCollision) {
      setError(t('settings.errorNameExists', { name: nameCollision }))
      return
    }
    if (!backends?.backends[kind]?.installed) {
      setError(t('settings.backendsCreateNotInstalled'))
      return
    }
    setBusy(true)
    setCreating(true)
    setError(null)
    const beforeNames = new Set((profiles ?? []).map((p) => p.name))
    let createdNames: string[] = []
    let failedMessage: string | null = null
    try {
      const result = await window.api.profiles.create(server.id, access, {
        name: name.trim(),
        transport: 'xhttp',
        count: Math.min(Math.max(Number(count) || 1, 1), 50),
        ...(createExpire && isFutureDate(createExpire, Date.now())
          ? { expire: createExpire }
          : {})
      })
      createdNames = result.ok ? result.names : []
      if (!result.ok) failedMessage = result.errors[0] ?? t('settings.createFailed')
    } catch (err) {
      failedMessage = err instanceof Error ? err.message : String(err)
    }
    if (createdNames.length === 0 && failedMessage) {
      // Профили могли создаться даже при ошибке парсинга — перечитываем список.
      try {
        const fresh = await window.api.profiles.list(server.id, access)
        setProfiles(fresh.profiles ?? [])
        const newlyAppeared = (fresh.profiles ?? []).filter(
          (p) => futureNames.includes(p.name) && !beforeNames.has(p.name)
        )
        if (newlyAppeared.length > 0) {
          createdNames = newlyAppeared.map((p) => p.name)
          failedMessage = null
        }
      } catch {
        // список не критичен, ошибку создания уже показываем
      }
    }
    const grantErrors: string[] = []
    for (const nm of createdNames) {
      try {
        if (kind === 'hysteria2') {
          await window.api.backends.hysteria2Grant(server.id, access, nm)
        } else {
          await window.api.backends.awgGrant(server.id, access, nm)
        }
      } catch (err) {
        grantErrors.push(`${nm}: ${err instanceof Error ? err.message : String(err)}`)
      }
    }
    try {
      const fresh = await window.api.profiles.list(server.id, access)
      setProfiles(fresh.profiles ?? [])
      await reloadBackends()
    } catch {
      // не критично — основной результат уже показан
    }
    if (createdNames.length > 0 && grantErrors.length === 0) {
      toastText(t('settings.backendsCreated', { count: createdNames.length }))
      setName('')
      setBackendSel(null)
    } else if (createdNames.length > 0) {
      setError(t('settings.backendsCreatedPartial'))
    } else if (failedMessage) {
      setError(failedMessage)
    }
    setBusy(false)
    setCreating(false)
  }

  // Ключи бэкенд-профиля: карточки в списке профилей (дубликаты стиля
  // бэкенд-блока, разделённые по протоколам).
  const profileHystLink = async (profile: ServerProfile): Promise<string> => {
    const res = await window.api.backends.hysteria2Link(server.id, access, profile.name)
    if (!res.ok || !res.link) throw new Error(res.error ?? t('settings.createFailed'))
    return res.link
  }

  const qrProfileHyst = async (profile: ServerProfile): Promise<void> => {
    try {
      await showKeysQr(await profileHystLink(profile))
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    }
  }

  const profileAwgConf = async (profile: ServerProfile): Promise<string> => {
    const res = await window.api.backends.awgConf(server.id, access, profile.name)
    if (!res.ok || !res.conf) throw new Error(res.error ?? t('settings.createFailed'))
    return res.conf
  }

  const qrProfileAwg = async (profile: ServerProfile): Promise<void> => {
    try {
      await showKeysQr(stripAwgComments(await profileAwgConf(profile)))
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    }
  }

  const qrProfileAwgVpn = async (profile: ServerProfile): Promise<void> => {
    try {
      const conf = await profileAwgConf(profile)
      await showKeysQr(
        await buildAwgVpnUrl(conf, profile.name, {
          clientPubKey: profile.backends?.awg?.client_public_key
        })
      )
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    }
  }

  const hyst = backends?.backends.hysteria2
  const awgEntry = backends?.backends.awg
  // Тон состояния — один признак на подпись и цвет (см. backendTone).
  const hystTone = backendTone(hyst)
  const awgTone = backendTone(awgEntry)

  const transportLabel = (profile: ServerProfile): string =>
    profile.multi_route ? `${profile.transport} · ${profile.routes} ${t('settings.routes')}` : profile.transport

  /** Иконка транспорта у строки профиля; у бэкенд-строк свои логотипы. */
  const transportIcon = (profile: ServerProfile): React.JSX.Element => {
    if (profile.transport === 'xhttp') return <Waypoints size={18} />
    if (profile.transport === 'grpc') return <Boxes size={18} />
    return <Cable size={18} />
  }

  /** Профиль отключён сервером: истёк срок или исчерпан лимит трафика. */
  const profileOff = (profile: ServerProfile): boolean =>
    profile.expire_disabled === true || profile.traffic_disabled === true

  /** Поиск (имя, SNI, ссылка подписки) и фильтр по состоянию — одна выборка. */
  const visibleProfiles = (profiles ?? []).filter((p) => {
    if (profileFilter === 'active' && profileOff(p)) return false
    if (profileFilter === 'disabled' && !profileOff(p)) return false
    const q = profileQuery.trim().toLowerCase()
    if (!q) return true
    return (
      p.name.toLowerCase().includes(q) ||
      (p.sni ?? '').toLowerCase().includes(q) ||
      (p.subscription_url ?? '').toLowerCase().includes(q)
    )
  })

  /**
   * Сколько карточек реально рисуется: сам профиль плюс карточка на каждый
   * выданный грант бэкенда (Hysteria 2 / AmneziaWG). Считать только профили
   * нечестно — на сервере из трёх профилей с двумя грантами на экране пять
   * карточек, а счётчик показывал три.
   */
  const visibleCardCount = visibleProfiles.reduce(
    (n, p) => n + 1 + (p.backends?.hysteria2 ? 1 : 0) + (p.backends?.awg ? 1 : 0),
    0
  )
  /** Тон режима подписки: HTTPS — норма, http_tls — предупреждение. */
  const dns01Tone: 'ok' | 'warn' | '' =
    dns01Status?.tls_mode === 'domain_tls' || dns01Status?.tls_mode === 'ip_tls'
      ? 'ok'
      : dns01Status?.tls_mode === 'http_tls'
        ? 'warn'
        : ''

  /** Сертификат истекает в ближайшие две недели — красим срок, чтобы не проглядеть. */
  const dns01CertSoon =
    (dns01Status?.cert_expiry ?? 0) > 0 && (dns01Status?.days_left ?? 0) < 14

  return (
    <div className={styles.root}>
      <header className={styles.header}>
        <Button
          variant="secondary"
          size="sm"
          isDisabled={busy}
          onPress={onBack}
        >
          {t('dashboard.back')}
        </Button>
        <h1 className={styles.title}>
          {mode === 'profiles' ? (
            <Layers size={20} className={styles.titleIcon} />
          ) : (
            <Settings2 size={20} className={styles.titleIcon} />
          )}
          {mode === 'profiles' ? t('settings.listTitle') : t('settings.title')}
        </h1>
        <span className={styles.serverName}>{server.name}</span>
        {connected && (
          <div className={styles.headerActions}>
            <Dropdown>
              <Dropdown.Trigger
                className={styles.updateTrigger}
                aria-label={updating ? t('settings.updating') : t('settings.updateServer')}
                isDisabled={busy}
              >
                <CloudDownload
                  size={16}
                  className={updating ? styles.iconDownloading : undefined}
                />
                <span className={styles.updateTriggerLabel}>
                  {updating ? t('settings.updating') : t('settings.updateServer')}
                </span>
                <ChevronDown size={14} className={styles.updateTriggerChevron} />
              </Dropdown.Trigger>
              <Dropdown.Popover placement="bottom end" className={styles.updatePopover}>
                <Dropdown.Menu>
                  <DropdownItem
                    key="auto"
                    className={styles.updateItem}
                    onAction={() => void updateServer()}
                  >
                    <span>{t('settings.updateBranchAuto')}</span>
                    <span className={styles.updateItemHint}>
                      {t('settings.updateBranchAutoHint')}
                    </span>
                  </DropdownItem>
                  <DropdownItem
                    key="main"
                    className={styles.updateItem}
                    onAction={() => void updateServer('main')}
                  >
                    <span>{t('settings.updateBranchMain')}</span>
                    <span className={styles.updateItemHint}>
                      {t('settings.updateBranchMainHint')}
                    </span>
                  </DropdownItem>
                  <DropdownItem
                    key="dev"
                    className={`${styles.updateItem} ${styles.updateItemBeta}`}
                    onAction={() => void updateServer('dev')}
                  >
                    <span>{t('settings.updateBranchDev')}</span>
                    <span className={styles.updateItemHint}>
                      {t('settings.updateBranchDevHint')}
                    </span>
                  </DropdownItem>
                </Dropdown.Menu>
              </Dropdown.Popover>
            </Dropdown>
            <Button
              variant="danger-soft"
              size="sm"
              className={uninstalling ? styles.breathing : undefined}
              isDisabled={busy}
              onPress={() => setConfirmUninstall(true)}
            >
              <CloudOff size={16} />
              {uninstalling ? t('settings.uninstalling') : t('settings.uninstallServer')}
            </Button>
          </div>
        )}
      </header>

      <div className={styles.body}>
        {!connected && (
          <section className={styles.connectCard}>
            <p className={styles.hint}>
              {t('settings.hint')}
            </p>
            <SshAccessForm
              value={access}
              onChange={setAccess}
              disabled={busy}
              hostKeyFingerprint={hostKeyFingerprint}
              onForgetHostKey={() => setConfirmHostKeyReset(true)}
            />
            <div className={styles.accessActions}>
              <Button
                variant="primary"
                size="lg"
                className={busy ? styles.glowPulse : undefined}
                isDisabled={busy || !accessReady}
                onPress={load}
              >
                <Play size={16} />
                {busy ? t('settings.connecting') : t('settings.connect')}
              </Button>
            </div>
            <p className={styles.passwordNote}>{t('settings.passwordNote')}</p>
          </section>
        )}

        {error && <div className={styles.error}>{t('settings.error')}: {error}</div>}
        {toast && <div className={styles.toast}>{toast}</div>}

        {keysQrUrl && (
          <div
            className={styles.keysQrModal}
            role="dialog"
            aria-modal="true"
            aria-label={t('keys.qr')}
            tabIndex={-1}
            ref={qrModalRef}
            onClick={() => setKeysQrUrl(null)}
          >
            {keysQrData ? <img src={keysQrData} alt={t('keys.qr')} /> : null}
          </div>
        )}

        {connected && (
          <>
            <nav className={styles.sectionTabs} role="tablist" aria-label={t('settings.sectionsAria')}>
              {SETTINGS_TABS.map((tab) => {
                const isProfiles = tab.id === 'profiles'
                const active = isProfiles
                  ? mode === 'profiles'
                  : mode === 'settings' && section === tab.id
                return (
                  <button
                    key={tab.id}
                    type="button"
                    role="tab"
                    id={`tab-${tab.id}`}
                    aria-selected={active}
                    aria-controls={
                      !isProfiles && mode === 'settings' ? `pane-${tab.id}` : undefined
                    }
                    className={`${styles.sectionTab} ${active ? styles.sectionTabActive : ''}`}
                    onClick={() => {
                      if (tab.id === 'profiles') {
                        if (mode !== 'profiles') onOpenProfiles?.()
                        return
                      }
                      // Со страницы профилей вкладки уводят обратно в настройки.
                      if (mode === 'profiles') {
                        setSection(tab.id)
                        onOpenSettings?.(tab.id)
                      } else setSection(tab.id)
                    }}
                  >
                    {t(tab.labelKey)}
                  </button>
                )
              })}
            </nav>

            {mode === 'settings' && (
            <div {...sectionPaneProps('create', section)}>
            <section
              className={`${styles.createCard} ${creating ? styles.createCardBusy : ''}`}
            >
              <h2 className={styles.sectionTitle}>{t('settings.createTitle')}</h2>
              <p className={styles.sectionHint}>{t('settings.createHint')}</p>
              {creating && (
                <div className={styles.createBusy}>
                  <span className={styles.createBusyDot} />
                  {t('settings.creating')}
                </div>
              )}
              <div className={styles.createRow}>
                <TextField variant="secondary" className={styles.nameField}>
                  <Label>{t('settings.profileName')}</Label>
                  <Input
                    value={name}
                    disabled={busy}
                    placeholder="phone-1"
                    onChange={(e) => setName(e.target.value)}
                  />
                </TextField>
                <TextField variant="secondary" className={styles.countField}>
                  <Label>{t('settings.count')}</Label>
                  <Input
                    type="number"
                    min={1}
                    max={50}
                    value={count}
                    disabled={busy}
                    onChange={(e) => setCount(e.target.value)}
                  />
                </TextField>
                <Button
                  variant="secondary"
                  size="lg"
                  className={styles.createExpireBtn}
                  isDisabled={busy}
                  onPress={() => setCreateExpireOpen(true)}
                >
                  <CalendarClock size={16} />
                  {createExpire
                    ? t('settings.createExpireSet', { date: createExpire })
                    : t('settings.createExpire')}
                </Button>
              </div>
              <div className={styles.createPreview}>
                <span className={styles.createPreviewLabel}>{t('settings.previewLabel')}</span>
                <div className={styles.createPreviewNames}>
                  {futureNames.slice(0, 6).map((nm, idx) => (
                    <span key={`${nm}-${idx}`} className={styles.createPreviewName}>
                      {nm}
                    </span>
                  ))}
                  {futureNames.length > 6 && (
                    <span className={styles.createPreviewMore}>
                      +{futureNames.length - 6}
                    </span>
                  )}
                </div>
                <span className={styles.createPreviewHint}>{t('settings.previewHint')}</span>
              </div>
              <div className={styles.transportField}>
                <span className={styles.fieldLabel}>{t('settings.protocol')}</span>
                <p className={styles.sectionHint}>{t('settings.protocolPrompt')}</p>
                <div className={styles.transportGrid}>
                  {PROTOCOLS.map((proto) => {
                    const active = transport === proto.id && backendSel === null
                    return (
                      <button
                        key={proto.id}
                        type="button"
                        className={`${styles.transportCard} ${
                          active ? styles.transportCardActive : ''
                        }`}
                        disabled={busy}
                        onClick={() => {
                          setTransport(proto.id)
                          setBackendSel(null)
                        }}
                      >
                        <span className={styles.transportCardName}>
                          {proto.label}
                          {proto.id === 'xhttp' && (
                            <span className={styles.transportCardTag}>
                              {t('settings.recommended')}
                            </span>
                          )}
                        </span>
                        <span className={styles.transportCardDesc}>
                          {t(`settings.protocolHint.${proto.id}`)}
                        </span>
                      </button>
                    )
                  })}
                </div>
              </div>
              <div className={styles.backendCreate}>
                <span className={styles.fieldLabel}>{t('settings.backendsTitle')}</span>
                <p className={styles.sectionHint}>{t('settings.backendsCreateHint')}</p>
                <div className={styles.backendCreateGrid}>
                  <button
                    type="button"
                    className={`${styles.backendCreateCard} ${
                      backendSel === 'hysteria2' ? styles.backendCreateCardActive : ''
                    }`}
                    disabled={busy || creating}
                    onClick={() => setBackendSel(backendSel === 'hysteria2' ? null : 'hysteria2')}
                  >
                    <span className={`${styles.backendIcon} ${styles.backendIconHyst}`}>
                      <img src={hystLogo} alt="Hysteria 2" className={styles.backendIconSvg} />
                    </span>
                    <span className={styles.backendCreateText}>
                      <span className={styles.backendCreateName}>Hysteria 2</span>
                      <span className={styles.backendCreateDesc}>
                        {t('settings.backendsCreateHystDesc')}
                      </span>
                    </span>
                  </button>
                  <button
                    type="button"
                    className={`${styles.backendCreateCard} ${
                      backendSel === 'awg' ? styles.backendCreateCardActive : ''
                    }`}
                    disabled={busy || creating}
                    onClick={() => setBackendSel(backendSel === 'awg' ? null : 'awg')}
                  >
                    <span className={`${styles.backendIcon} ${styles.backendIconAwg}`}>
                      <img src={amneziaLogo} alt="AmneziaWG" className={styles.backendIconImg} />
                    </span>
                    <span className={styles.backendCreateText}>
                      <span className={styles.backendCreateName}>AmneziaWG 3.1</span>
                      <span className={styles.backendCreateDesc}>
                        {t('settings.backendsCreateAwgDesc')}
                      </span>
                    </span>
                  </button>
                </div>
              </div>
              {/* Действие — в конце формы: поток «имя → счётчик → протокол → бэкенд»
                  идёт сверху вниз, а кнопка в середине строки читалась как «создать
                  только по имени», игнорируя выбранный ниже протокол. */}
              <div className={styles.createFooter}>
                {!name.trim() && (
                  <span className={styles.createDisabledHint}>
                    {t('settings.createNeedName')}
                  </span>
                )}
                <Button
                  variant="primary"
                  size="lg"
                  className={styles.createBtn}
                  isDisabled={busy || !accessReady || !name.trim()}
                  onPress={() => {
                    if (backendSel) void createBackendProfiles(backendSel)
                    else void create()
                  }}
                >
                  {busy && <Spinner size="sm" />}
                  {t('settings.createBtn')}
                </Button>
              </div>
            </section>
            </div>
            )}

            {mode === 'profiles' && (
            <section className={styles.listCard}>
              <div className={styles.profilesHead}>
                <div className={styles.profilesHeadText}>
                  <h2 className={styles.sectionTitle}>{t('settings.profilesHeading')}</h2>
                  <p className={styles.sectionHint}>{t('settings.profilesSubtitle')}</p>
                </div>
                <div className={styles.profilesTools}>
                  <div className={styles.profilesSearch}>
                    <Search size={15} className={styles.profilesSearchIcon} />
                    <input
                      className={styles.profilesSearchInput}
                      value={profileQuery}
                      onChange={(e) => setProfileQuery(e.target.value)}
                      placeholder={t('settings.profilesSearch')}
                      aria-label={t('settings.profilesSearch')}
                      type="search"
                    />
                  </div>
                  <Dropdown>
                    <Dropdown.Trigger
                      className={styles.profilesFilter}
                      aria-label={t('settings.profileFilterLabel')}
                    >
                      <Filter size={14} />
                      <span className={styles.profilesFilterLabel}>
                        {t(
                          profileFilter === 'active'
                            ? 'settings.profileFilterActive'
                            : profileFilter === 'disabled'
                              ? 'settings.profileFilterDisabled'
                              : 'settings.profileFilterAll'
                        )}
                      </span>
                      <ChevronDown size={14} />
                    </Dropdown.Trigger>
                    <Dropdown.Popover placement="bottom end" className={styles.updatePopover}>
                      <Dropdown.Menu>
                        {(['all', 'active', 'disabled'] as const).map((f) => (
                          <DropdownItem
                            key={f}
                            className={styles.updateItem}
                            onAction={() => setProfileFilter(f)}
                          >
                            {t(
                              f === 'active'
                                ? 'settings.profileFilterActive'
                                : f === 'disabled'
                                  ? 'settings.profileFilterDisabled'
                                  : 'settings.profileFilterAll'
                            )}
                          </DropdownItem>
                        ))}
                      </Dropdown.Menu>
                    </Dropdown.Popover>
                  </Dropdown>
                </div>
              </div>
              {profiles!.length > 0 && !expireSupported && (
                <p className={styles.serverTooOld}>{t('settings.serverTooOld')}</p>
              )}
              {profiles!.length === 0 && <div className={styles.empty}>{t('settings.empty')}</div>}
              {profiles!.length > 0 && visibleProfiles.length === 0 && (
                <div className={styles.empty}>{t('settings.profilesNotFound')}</div>
              )}
              {visibleProfiles.map((profile) => (
                <Fragment key={profile.name}>
                <div className={styles.profileCard}>
                  <span
                    className={`${styles.profileIcon} ${
                      profileOff(profile) ? styles.profileIconOff : ''
                    }`}
                  >
                    {transportIcon(profile)}
                  </span>
                  <div className={styles.profileMain}>
                    <div className={styles.profileNameRow}>
                      <span className={styles.profileName}>{profile.name}</span>
                      <span
                        className={`${styles.profileStatus} ${
                          profileOff(profile) ? styles.profileStatusOff : ''
                        }`}
                      >
                        <span className={styles.profileStatusDot} />
                        {profileOff(profile)
                          ? t('settings.profileStatusOff')
                          : t('settings.profileStatusOn')}
                      </span>
                      {profile.multi_route && <Chip size="sm" color="accent">{t('settings.happ')}</Chip>}
                      {(profile.pq_enabled || (profile.pq_routes ?? 0) > 0) && (<Chip size="sm" color="default">{(profile.pq_routes ?? 0) > 1 ? `PQ ×${profile.pq_routes}` : 'PQ'}</Chip>)}
                    </div>
                    <div className={styles.profileMeta}>
                      <Chip size="sm" color="default">{transportLabel(profile)}</Chip>
                      <Chip size="sm" color="default">:{profile.port}</Chip>
                      <span className={styles.profileSni} title={t('settings.sniSelect')}>
                        {profile.sni}
                      </span>
                      {expireChip(profile)}
                      {trafficChip(profile)}
                    </div>
                    {profile.subscription_url && (
                      <div className={styles.profileUrl} title={profile.subscription_url}>
                        <span className={styles.profileUrlText}>{profile.subscription_url}</span>
                      </div>
                    )}
                  </div>
                  <div className={styles.profileRowActions}>
                    {profile.subscription_url && (
                      <Button size="sm" variant="secondary" onPress={() => copyUrl(profile)}>
                        <Copy size={13} />
                        {t('settings.copy')}
                      </Button>
                    )}
                    <Button
                      size="sm"
                      variant="secondary"
                      isDisabled={busy}
                      onPress={() => setActionTarget({ kind: 'profile', profile })}
                    >
                      <Settings2 size={14} />
                      {t('settings.profileSettings')}
                    </Button>
                    {profile.multi_route && (
                      <span
                        className={styles.protectedProfile}
                        title={t('settings.mainProfileHint')}
                      >
                        <Lock size={13} />
                        {t('settings.mainProfile')}
                      </span>
                    )}
                  </div>
                  {/* Настройки профиля — отдельным окном, как остальные действия:
                      в строке остаются только «Копировать» и «Настройки». */}
                  <AlertDialog.Root
                    isOpen={
                      actionTarget?.kind === 'profile' &&
                      actionTarget.profile.name === profile.name
                    }
                    onOpenChange={(open) => {
                      if (!open) setActionTarget(null)
                    }}
                  >
                    <AlertDialog.Backdrop>
                      <AlertDialog.Container>
                        <AlertDialog.Dialog
                          className={`${styles.confirmDialog} ${styles.actionsDialog}`}
                        >
                          <AlertDialog.Header>
                            <div className={styles.actionsHead}>
                              <span className={styles.actionsHeadIcon}>
                                <Settings2 size={22} />
                              </span>
                              <div className={styles.actionsHeadText}>
                                <span className={styles.actionsKicker}>
                                  {t('settings.profileSettingsTitle')}
                                </span>
                                <AlertDialog.Heading className={styles.actionsTitle}>
                                  {profile.name}
                                </AlertDialog.Heading>
                                {/* Транспорт и число маршрутов в окне не дублируем: их
                                    видно в строке профиля, а в окне бэкенда эта плашка
                                    вообще не про то, что здесь делают. SNI из шапки убран
                                    в тело окна (см. .profileSniBar): отдельной mono-строкой
                                    под именем он в узком окне выглядел обрубком. */}
                              </div>
                            </div>
                          </AlertDialog.Header>
                          <AlertDialog.Body>

                            <div className={styles.actionGroups}>
                              <div className={styles.settingsGroup}>
                                {/* SNI — в правом верхнем углу коробки «Маршрут», на одной
                                    строке с её заголовком: голое значение без подписи, как
                                    раньше под именем профиля, но там оно спорило с названием
                                    и выглядело обрубком в узком окне. */}
                                <div className={styles.settingsGroupHead}>
                                  <span className={styles.settingsGroupIcon}>
                                    <Link2 size={15} />
                                  </span>
                                  <span className={styles.settingsGroupTitle}>
                                    {t('settings.groupRoute')}
                                  </span>
                                  {profile.sni && (
                                    <span className={styles.settingsGroupSni} title={profile.sni}>
                                      {profile.sni}
                                    </span>
                                  )}
                                </div>
                                <p className={styles.settingsHint}>
                                  {t('settings.groupRouteHint')}
                                </p>
                                <div className={styles.settingsButtons}>
                                  <Button
                                    size="sm"
                                    variant="secondary"
                                    isDisabled={busy}
                                    onPress={() => {
                                      setSniTarget(profile)
                                      setSniValue(profile.sni ?? '')
                                      setSniRoute(1)
                                      setSniList(null)
                                      setSniError(null)
                                    }}
                                  >
                                    <Globe2 size={14} />
                                    {t('settings.sniBtn')}
                                  </Button>
                                  <Button
                                    size="sm"
                                    variant="secondary"
                                    isDisabled={busy}
                                    onPress={() => {
                                      setFpTarget(profile)
                                      setFpValue(profile.fingerprint || 'firefox')
                                      setFpRoute(1)
                                      setFpError(null)
                                    }}
                                  >
                                    <Fingerprint size={14} />
                                    {t('settings.fpBtn')}
                                  </Button>
                                  <Button
                                    size="sm"
                                    variant="secondary"
                                    isDisabled={busy}
                                    onPress={() => {
                                      setPortTarget(profile)
                                      setPortRoute(1)
                                      setPortMode('random')
                                      setPortValue('')
                                      setPortError(null)
                                    }}
                                  >
                                    <EthernetPort size={14} />
                                    {t('settings.portBtn')}
                                  </Button>
                                  <Button
                                    size="sm"
                                    variant="secondary"
                                    isDisabled={busy}
                                    onPress={() => {
                                      setPqTarget(profile)
                                      setPqResult(null)
                                      setPqError(null)
                                      setPqTransport(
                                        PROTOCOLS.some((p) => p.id === profile.transport)
                                          ? profile.transport
                                          : 'tcp'
                                      )
                                    }}
                                  >
                                    <Zap size={14} />
                                    {t('settings.pqBtn')}
                                  </Button>
                                </div>
                              </div>
                              <div className={styles.settingsGroup}>
                                <div className={styles.settingsGroupHead}>
                                  <span className={styles.settingsGroupIcon}>
                                    <Gauge size={15} />
                                  </span>
                                  <span className={styles.settingsGroupTitle}>
                                    {t('settings.groupLimits')}
                                  </span>
                                </div>
                                <p className={styles.settingsHint}>
                                  {t('settings.groupLimitsHint')}
                                </p>
                                <div className={styles.settingsButtons}>
                                  <Button
                                    size="sm"
                                    variant="secondary"
                                    isDisabled={busy}
                                    onPress={() => openExpire(profile)}
                                  >
                                    <CalendarClock size={14} />
                                    {t('settings.expireBtn')}
                                  </Button>
                                  {trafficSupported && (
                                    <Button
                                      size="sm"
                                      variant="secondary"
                                      isDisabled={busy}
                                      onPress={() => openLimit(profile)}
                                    >
                                      <Gauge size={14} />
                                      {t('settings.trafficBtn')}
                                    </Button>
                                  )}
                                </div>
                              </div>
                              <div className={styles.settingsGroup}>
                                <div className={styles.settingsGroupHead}>
                                  <span className={styles.settingsGroupIcon}>
                                    <ShieldCheck size={15} />
                                  </span>
                                  <span className={styles.settingsGroupTitle}>
                                    {t('settings.groupAccess')}
                                  </span>
                                </div>
                                <p className={styles.settingsHint}>
                                  {t('settings.groupAccessHint')}
                                </p>
                                <div className={styles.settingsButtons}>
                                  {profile.subscription_url && (
                                    <Button
                                      size="sm"
                                      variant="secondary"
                                      isDisabled={busy}
                                      onPress={() => openRevoke(profile)}
                                    >
                                      <ShieldOff size={14} />
                                      {t('settings.revokeBtn')}
                                    </Button>
                                  )}
                                </div>
                              </div>
                              {profile.multi_route ? null : (
                                <div
                                  className={`${styles.settingsGroup} ${styles.settingsGroupDanger}`}
                                >
                                  <div className={styles.settingsGroupHead}>
                                    <span className={styles.settingsGroupIcon}>
                                      <Trash2 size={15} />
                                    </span>
                                    <span className={styles.settingsGroupTitle}>
                                      {t('settings.groupDelete')}
                                    </span>
                                  </div>
                                  <p className={styles.settingsHint}>
                                    {t('settings.groupDeleteHint')}
                                  </p>
                                  <div className={styles.settingsButtons}>
                                    <Button
                                      size="sm"
                                      variant="danger-soft"
                                      isDisabled={busy}
                                      onPress={() => setConfirmRemove(profile)}
                                    >
                                      <Trash2 size={14} />
                                      {t('settings.deleteKey')}
                                    </Button>
                                  </div>
                                </div>
                              )}
                            </div>
                          </AlertDialog.Body>
                          <AlertDialog.Footer>
                            <Button variant="secondary" onPress={() => setActionTarget(null)}>
                              {t('settings.done')}
                            </Button>
                          </AlertDialog.Footer>
                        </AlertDialog.Dialog>
                      </AlertDialog.Container>
                    </AlertDialog.Backdrop>
                  </AlertDialog.Root>
                </div>
                  {profile.backends?.hysteria2 && (
                    <div className={styles.backendProfileCard}>
                      <div className={styles.backendProfileHead}>
                        <span className={`${styles.backendIcon} ${styles.backendIconHyst}`}>
                          <img src={hystLogo} alt="Hysteria 2" className={styles.backendIconSvg} />
                        </span>
                        <div className={styles.backendProfileTitle}>
                          <div className={styles.backendName}>{profile.name}</div>
                          <div className={styles.backendProfileSub}>
                            {t('settings.backendsHyst')} · {t('settings.backendsHystSub')}
                          </div>
                          <div
                            className={`${styles.backendState} ${BACKEND_TONE_CLASS[hystTone]}`}
                          >
                            {hystTone === 'ok'
                              ? hyst?.sni
                                ? `${t('settings.backendsActive')} · SNI ${hyst.sni}`
                                : `${t('settings.backendsActive')} · UDP ${hyst?.port ?? '—'}`
                              : hystTone === 'down'
                                ? t('settings.backendsStopped')
                                : t('settings.backendsNotInstalled')}
                          </div>
                          {hystTone === 'down' && (
                            <p className={styles.backendStateHint}>
                              {t('settings.backendsStoppedHint', { unit: hyst?.unit ?? '—' })}
                            </p>
                          )}
                        </div>
                      </div>
                      <div className={styles.backendActions}>
                        {hystTone === 'down' && (
                          <Button
                            size="sm"
                            variant="primary"
                            isDisabled={busy || !accessReady}
                            onPress={() => void startBackend('hysteria2')}
                          >
                            <Play size={14} />
                            {backendBusy === 'hysteria2-start'
                              ? t('settings.backendsStarting')
                              : t('settings.backendsStart')}
                          </Button>
                        )}
                        <Button
                          size="sm"
                          variant="secondary"
                          isDisabled={busy || hystTone !== 'ok'}
                          onPress={() => void qrProfileHyst(profile)}
                        >
                          {t('keys.qr')}
                        </Button>
                        <Button
                          size="sm"
                          variant="secondary"
                          isDisabled={busy}
                          onPress={() => setActionTarget({ kind: 'hysteria2', profile })}
                        >
                          <Settings2 size={14} />
                          {t('settings.profileSettings')}
                        </Button>
                      </div>
                    </div>
                  )}
                  {profile.backends?.awg && (
                    <div className={styles.backendProfileCard}>
                      <div className={styles.backendProfileHead}>
                        <span className={`${styles.backendIcon} ${styles.backendIconAwg}`}>
                          <img src={amneziaLogo} alt="AmneziaWG" className={styles.backendIconImg} />
                        </span>
                        <div className={styles.backendProfileTitle}>
                          <div className={styles.backendName}>{profile.name}</div>
                          <div className={styles.backendProfileSub}>
                            {t('settings.backendsAwg')} · {t('settings.backendsAwgSub')}
                          </div>
                          <div
                            className={`${styles.backendState} ${BACKEND_TONE_CLASS[awgTone]}`}
                          >
                            {awgTone === 'ok'
                              ? `${t('settings.backendsActive')} · UDP ${awgEntry?.port ?? '—'}`
                              : awgTone === 'down'
                                ? t('settings.backendsStopped')
                                : t('settings.backendsNotInstalled')}
                          </div>
                          {awgTone === 'down' && (
                            <p className={styles.backendStateHint}>
                              {t('settings.backendsStoppedHint', { unit: awgEntry?.unit ?? '—' })}
                            </p>
                          )}
                        </div>
                      </div>
                      <div className={styles.backendActions}>
                        {awgTone === 'down' && (
                          <Button
                            size="sm"
                            variant="primary"
                            isDisabled={busy || !accessReady}
                            onPress={() => void startBackend('awg')}
                          >
                            <Play size={14} />
                            {backendBusy === 'awg-start'
                              ? t('settings.backendsStarting')
                              : t('settings.backendsStart')}
                          </Button>
                        )}
                        <Button
                          size="sm"
                          variant="secondary"
                          isDisabled={busy || awgTone !== 'ok'}
                          onPress={() => void qrProfileAwg(profile)}
                        >
                          {t('keys.qr')}
                        </Button>
                        <Button
                          size="sm"
                          variant="secondary"
                          isDisabled={busy || awgTone !== 'ok'}
                          onPress={() => void qrProfileAwgVpn(profile)}
                        >
                          {t('keys.backendsQrVpn')}
                        </Button>
                        <Button
                          size="sm"
                          variant="secondary"
                          isDisabled={busy}
                          onPress={() => setActionTarget({ kind: 'awg', profile })}
                        >
                          <Settings2 size={14} />
                          {t('settings.profileSettings')}
                        </Button>
                      </div>
                    </div>
                  )}
                </Fragment>
              ))}
              {visibleProfiles.length > 0 && (
                <p className={styles.profilesFooter}>
                  {t('settings.profilesShown', { count: visibleCardCount })}
                </p>
              )}
            </section>
            )}

            {mode === 'settings' && (
            <>
            <div {...sectionPaneProps('backends', section)}>
            <section>
              <div className={styles.listCard}>
                <h2 className={styles.sectionTitle}>
                  {t('settings.backendsTitle')}
                  <Chip size="sm" color="default">{t('settings.backendsDevBadge')}</Chip>
                </h2>
                <p className={styles.sectionHint}>{t('settings.backendsHint')}</p>
                <p className={styles.hint}>{t('settings.backendsDevNote')}</p>
                {backendsError !== null ? (
                  <>
                    <p className={styles.hint}>{t('settings.backendsUnsupported')}</p>
                    {/* Показываем и саму ошибку: без неё «старый менеджер» неотличим
                        от сетевого сбоя, прав или битого ответа сервера. */}
                    <p className={styles.error}>{backendsError}</p>
                  </>
                ) : backendsLoading || backends === null ? (
                  <>
                    <div className={styles.backendSkeleton} />
                    <div className={styles.backendSkeleton} />
                  </>
                ) : (
                  <>
                    <div className={styles.backendsInner}>
                      <div className={styles.backendBlock}>
                        <div className={styles.backendHead}>
                          <div className={`${styles.backendIcon} ${styles.backendIconHyst}`}>
                            <img src={hystLogo} alt="Hysteria" className={styles.backendIconSvg} />
                          </div>
                          <div className={styles.backendTitle}>
                            <div className={styles.backendName}>{t('settings.backendsHyst')}</div>
                            <div className={styles.backendSub}>{t('settings.backendsHystSub')}</div>
                          </div>
                        </div>
                        <div className={`${styles.backendState} ${BACKEND_TONE_CLASS[hystTone]}`}>
                          {hystTone === 'ok'
                            ? `${t('settings.backendsActive')} · UDP ${hyst?.port ?? '—'} · ${
                                hyst?.version ?? ''
                              }`
                            : hystTone === 'down'
                              ? t('settings.backendsStopped')
                              : t('settings.backendsNotInstalled')}
                        </div>
                        {hystTone === 'down' && (
                          <p className={styles.backendStateHint}>
                            {t('settings.backendsStoppedHint', { unit: hyst?.unit ?? '—' })}
                          </p>
                        )}
                        <p className={styles.backendNote}>{t('settings.backendsHystNote')}</p>
                        <div className={styles.backendActions}>
                          {hyst?.installed ? (
                            <>
                              {hystTone === 'down' && (
                                <Button
                                  size="sm"
                                  variant="primary"
                                  isDisabled={busy || !accessReady}
                                  onPress={() => void startBackend('hysteria2')}
                                >
                                  <Play size={14} />
                                  {backendBusy === 'hysteria2-start'
                                    ? t('settings.backendsStarting')
                                    : t('settings.backendsStart')}
                                </Button>
                              )}
                              <Button
                                size="sm"
                                variant={hyst.sub_body ? 'secondary' : 'primary'}
                                isDisabled={busy}
                                onPress={toggleSubbody}
                              >
                                {hyst.sub_body
                                  ? t('settings.backendsSubBodyOn')
                                  : t('settings.backendsSubBodyOff')}
                              </Button>
                              <Button
                                size="sm"
                                variant="secondary"
                                isDisabled={busy}
                                onPress={() => openBackendExpiry('hysteria2')}
                              >
                                <CalendarClock size={14} />
                                {t('settings.expireBtn')}
                              </Button>
                              <Button
                                size="sm"
                                variant="secondary"
                                isDisabled={busy}
                                onPress={() => setConfirmBackend('hysteria2-revoke-all')}
                              >
                                <ShieldOff size={14} />
                                {t('settings.revokeBtn')}
                              </Button>
                              <Button
                                size="sm"
                                variant="danger-soft"
                                isDisabled={busy}
                                onPress={() => setConfirmBackend('hysteria2-uninstall')}
                              >
                                {backendBusy === 'hysteria2-uninstall'
                                  ? t('settings.backendsUninstalling')
                                  : t('settings.backendsUninstall')}
                              </Button>
                            </>
                          ) : (
                            <Button size="sm" variant="primary" isDisabled={busy} onPress={installHysteria2}>
                              {backendBusy === 'hysteria2-install'
                                ? t('settings.backendsInstalling')
                                : t('settings.backendsInstall')}
                            </Button>
                          )}
                        </div>
                      </div>

                      <div className={styles.backendBlock}>
                        <div className={styles.backendHead}>
                          <div className={`${styles.backendIcon} ${styles.backendIconAwg}`}>
                            <img src={amneziaLogo} alt="Amnezia" className={styles.backendIconImg} />
                          </div>
                          <div className={styles.backendTitle}>
                            <div className={styles.backendName}>{t('settings.backendsAwg')}</div>
                            <div className={styles.backendSub}>{t('settings.backendsAwgSub')}</div>
                          </div>
                        </div>
                        <div className={`${styles.backendState} ${BACKEND_TONE_CLASS[awgTone]}`}>
                          {awgTone === 'ok'
                            ? `${t('settings.backendsActive')} · UDP ${awgEntry?.port ?? '—'} · ${
                                awgEntry?.three_enabled
                                  ? t('settings.backends31On')
                                  : t('settings.backends31Off')
                              }`
                            : awgTone === 'down'
                              ? t('settings.backendsStopped')
                              : t('settings.backendsNotInstalled')}
                        </div>
                        {awgTone === 'down' && (
                          <p className={styles.backendStateHint}>
                            {t('settings.backendsStoppedHint', { unit: awgEntry?.unit ?? '—' })}
                          </p>
                        )}
                        <p className={styles.backendNote}>{t('settings.backendsAwgNote')}</p>
                        <div className={styles.backendActions}>
                          {awgEntry?.installed ? (
                            <>
                              {awgTone === 'down' && (
                                <Button
                                  size="sm"
                                  variant="primary"
                                  isDisabled={busy || !accessReady}
                                  onPress={() => void startBackend('awg')}
                                >
                                  <Play size={14} />
                                  {backendBusy === 'awg-start'
                                    ? t('settings.backendsStarting')
                                    : t('settings.backendsStart')}
                                </Button>
                              )}
                              <Button
                                size="sm"
                                variant={awgEntry.three_enabled ? 'secondary' : 'primary'}
                                isDisabled={busy}
                                onPress={() => setConfirmBackend('awg31-on')}
                              >
                                {t(
                                  awgEntry.three_enabled
                                    ? 'settings.backends31Disable'
                                    : 'settings.backends31Enable'
                                )}
                              </Button>
                              <Button
                                size="sm"
                                variant="secondary"
                                isDisabled={busy}
                                onPress={() => openBackendExpiry('awg')}
                              >
                                <CalendarClock size={14} />
                                {t('settings.expireBtn')}
                              </Button>
                              <Button
                                size="sm"
                                variant="secondary"
                                isDisabled={busy}
                                onPress={() => setConfirmBackend('awg-revoke-all')}
                              >
                                <ShieldOff size={14} />
                                {t('settings.revokeBtn')}
                              </Button>
                              <Button
                                size="sm"
                                variant="danger-soft"
                                isDisabled={busy}
                                onPress={() => setConfirmBackend('awg-uninstall')}
                              >
                                {backendBusy === 'awg-uninstall'
                                  ? t('settings.backendsUninstalling')
                                  : t('settings.backendsUninstall')}
                              </Button>
                            </>
                          ) : (
                            <Button size="sm" variant="primary" isDisabled={busy} onPress={installAwg}>
                              {backendBusy === 'awg-install'
                                ? t('settings.backendsInstalling')
                                : t('settings.backendsInstall')}
                            </Button>
                          )}
                        </div>
                      </div>
                    </div>
                  </>
                )}
              </div>
            </section>
            </div>

            <div {...sectionPaneProps('subscription', section)}>
              <section className={styles.subCard}>
                <div className={styles.subHead}>
                  {/* Щит говорит о состоянии сам: зелёный — защита работает,
                      перечёркнутый — выключена или не установлена. */}
                  <span
                    className={`${styles.subIcon} ${
                      sshProtect?.active
                        ? styles.subIconOk
                        : sshProtect?.installed
                          ? styles.subIconOff
                          : styles.subIconIdle
                    }`}
                  >
                    {sshProtect?.active ? <ShieldCheck size={20} /> : <ShieldOff size={20} />}
                  </span>
                  <span className={styles.subHeadText}>
                    <span className={styles.subTitleRow}>
                      <span className={styles.subTitle}>{t('settings.sshProtectTitle')}</span>
                      <span
                        className={`${styles.subMode} ${
                          sshProtect?.active
                            ? styles.subModeOk
                            : sshProtect?.installed
                              ? styles.subModeWarn
                              : ''
                        }`}
                      >
                        {sshProtect?.active
                          ? t('settings.sshProtectOn')
                          : sshProtect?.installed
                            ? t('settings.sshProtectOff')
                            : t('settings.sshProtectNotInstalled')}
                      </span>
                    </span>
                    <span className={styles.subSubtitle}>
                      {sshProtect?.active
                        ? t('settings.sshProtectRule')
                        : t('settings.sshProtectSubtitle')}
                    </span>
                  </span>
                </div>

                <dl className={styles.subGrid}>
                  <div className={styles.subRow}>
                    <dt className={styles.subLabel}>{t('settings.sshProtectLabelFailed')}</dt>
                    <dd className={`${styles.subValue} ${styles.subValueBox}`}>
                      {sshProtect?.failed_24h ?? 0}
                    </dd>
                  </div>
                  <div className={styles.subRow}>
                    <dt className={styles.subLabel}>{t('settings.sshProtectLabelBanned')}</dt>
                    <dd className={`${styles.subValue} ${styles.subValueBox}`}>
                      {sshProtect?.banned_current ?? 0}
                    </dd>
                  </div>
                  <div className={styles.subRow}>
                    <dt className={styles.subLabel}>{t('settings.sshProtectLabelLimits')}</dt>
                    <dd className={`${styles.subValue} ${styles.subValueBox}`}>
                      {sshProtect?.sshd_hardened
                        ? `MaxAuthTries ${sshProtect?.max_auth_tries || '3'} · LoginGraceTime ${
                            sshProtect?.login_grace_time || '30'
                          }`
                        : t('settings.sshProtectLimitsNone')}
                    </dd>
                  </div>
                </dl>

                {(sshProtect?.banned_ips?.length ?? 0) > 0 && (
                  <p className={styles.subNotice}>
                    {t('settings.sshProtectBannedList', {
                      ips: (sshProtect?.banned_ips ?? []).join(', ')
                    })}
                  </p>
                )}
                {sshProtect && sshProtect.active !== true && sshProtect.supported !== false && (
                  <p className={styles.subNotice}>{t('settings.sshProtectDisabledNote')}</p>
                )}
                {sshProtect && sshProtect.supported === false && (
                  <p className={styles.subNotice}>{t('settings.sshProtectUnsupported')}</p>
                )}
                {sshProtectError && <p className={styles.error}>{sshProtectError}</p>}

                <div className={styles.subActions}>
                  <Button
                    size="sm"
                    variant={sshProtect?.active ? 'secondary' : 'primary'}
                    isDisabled={sshProtectBusy || sshProtect?.supported === false}
                    onPress={() => void toggleSshProtect(sshProtect?.active !== true)}
                  >
                    {sshProtectBusy
                      ? t('settings.sshProtectBusy')
                      : sshProtect?.active
                        ? t('settings.sshProtectDisable')
                        : t('settings.sshProtectEnable')}
                  </Button>
                  <Button
                    size="sm"
                    variant="secondary"
                    isDisabled={sshProtectBusy}
                    onPress={() => void refreshSshProtect()}
                  >
                    <RefreshCw size={14} />
                    {t('settings.sshProtectRefresh')}
                  </Button>
                </div>
                <p className={styles.fpNote}>{t('settings.sshProtectUnbanHint')}</p>
              </section>

            <section className={styles.subCard}>
              <button
                type="button"
                className={styles.subHead}
                aria-expanded={dns01Open}
                onClick={() => setDns01Open((v) => !v)}
              >
                <span className={styles.subIcon}>
                  <FileBadge size={20} />
                </span>
                <span className={styles.subHeadText}>
                  <span className={styles.subTitleRow}>
                    <span className={styles.subTitle}>{t('settings.dns01Title')}</span>
                    <span
                      className={`${styles.subMode} ${
                        dns01Tone === 'ok'
                          ? styles.subModeOk
                          : dns01Tone === 'warn'
                            ? styles.subModeWarn
                            : ''
                      }`}
                    >
                      {dns01Status?.tls_mode || t('settings.dns01ModeUnknown')}
                    </span>
                  </span>
                  <span className={styles.subSubtitle}>
                    {dns01Status?.domain || t('settings.dns01NoDomain')}
                  </span>
                </span>
                <span
                  className={`${styles.subChevron} ${dns01Open ? styles.subChevronOpen : ''}`}
                  aria-hidden="true"
                >
                  <ChevronDown size={16} />
                </span>
              </button>

              {/* Раньше статус шёл одной строкой через «·» и читался как предложение.
                  Теперь режим — бейджем у заголовка, а значения — одинаковыми
                  моно-боксами под подписями: иначе домен выглядел значением, а
                  провайдер и срок — просто текстом. */}
              <dl className={styles.subGrid}>
                <div className={styles.subRow}>
                  <dt className={styles.subLabel}>{t('settings.dns01Domain')}</dt>
                  <dd
                    className={`${styles.subValue} ${styles.subValueBox}`}
                    title={dns01Status?.domain ?? ''}
                  >
                    {dns01Status?.domain || '—'}
                  </dd>
                </div>
                <div className={styles.subRow}>
                  <dt className={styles.subLabel}>{t('settings.dns01Provider')}</dt>
                  <dd className={`${styles.subValue} ${styles.subValueBox}`}>
                    {dns01Status?.provider || '—'}
                  </dd>
                </div>
                <div className={styles.subRow}>
                  <dt className={styles.subLabel}>{t('settings.dns01Cert')}</dt>
                  <dd
                    className={`${styles.subValue} ${styles.subValueBox} ${
                      dns01CertSoon ? styles.subValueWarn : ''
                    }`}
                  >
                    {(dns01Status?.cert_expiry ?? 0) > 0
                      ? `${dns01Status?.days_left} ${t('settings.dns01Days')}`
                      : '—'}
                  </dd>
                </div>
              </dl>

              {dns01Error && <p className={styles.error}>{dns01Error}</p>}
              {dns01Status?.tls_mode === 'http_tls' && (
                <p className={styles.subNotice}>{t('settings.dns01Degraded')}</p>
              )}
              {dns01Status?.staging === true && (
                <p className={styles.subNotice}>{t('settings.dns01Staging')}</p>
              )}

              <div className={styles.subActions}>
                <Button
                  size="sm"
                  variant={dns01Open ? 'secondary' : 'primary'}
                  isDisabled={dns01Busy}
                  onPress={() => setDns01Open(true)}
                >
                  {dns01Status?.tls_mode === 'http_tls'
                    ? t('settings.dns01RepairBtn')
                    : t('settings.dns01Btn')}
                </Button>
                {dns01Status?.tls_mode === 'domain_tls' && (
                  <Chip size="sm" color="accent">
                    {t('settings.dns01Active')}
                  </Chip>
                )}
              </div>

              {dns01Open && (
                <div className={styles.subForm}>
                  <p className={styles.sectionHint}>{t('settings.dns01Hint')}</p>
                  {/* Провайдер: креденшелы Cloudflare и Route53 не взаимозаменяемы,
                      поэтому лишние поля не показываем и не отправляем. */}
                  <span className={styles.fieldLabel}>{t('settings.dns01Provider')}</span>
                  <div className={styles.profileActions}>
                    {(['cloudflare', 'route53'] as const).map((p) => (
                      <Button
                        key={p}
                        size="sm"
                        variant={dns01Provider === p ? 'primary' : 'secondary'}
                        isDisabled={dns01Busy}
                        onPress={() => setDns01Provider(p)}
                      >
                        {p === 'cloudflare' ? 'Cloudflare' : 'Route53'}
                      </Button>
                    ))}
                  </div>
                  <TextField variant="secondary">
                    <Label>{t('settings.dns01Domain')}</Label>
                    <Input
                      value={dns01Domain}
                      placeholder="sub.example.com"
                      disabled={dns01Busy}
                      onChange={(e) => setDns01Domain(e.target.value)}
                    />
                  </TextField>
                  <p className={styles.fpNote}>{t('settings.dns01DomainHint')}</p>
                  {dns01Provider === 'cloudflare' ? (
                    <TextField variant="secondary">
                      <Label>{t('settings.dns01Token')}</Label>
                      <Input
                        type="password"
                        value={dns01Token}
                        disabled={dns01Busy}
                        onChange={(e) => setDns01Token(e.target.value)}
                      />
                    </TextField>
                  ) : (
                    <>
                      <TextField variant="secondary">
                        <Label>{t('settings.dns01AwsKey')}</Label>
                        <Input
                          value={dns01AwsKeyId}
                          disabled={dns01Busy}
                          onChange={(e) => setDns01AwsKeyId(e.target.value)}
                        />
                      </TextField>
                      <TextField variant="secondary">
                        <Label>{t('settings.dns01AwsSecret')}</Label>
                        <Input
                          type="password"
                          value={dns01AwsSecret}
                          disabled={dns01Busy}
                          onChange={(e) => setDns01AwsSecret(e.target.value)}
                        />
                      </TextField>
                    </>
                  )}
                  <p className={styles.fpNote}>{t('settings.dns01SecretNote')}</p>
                  <div className={styles.profileActions}>
                    <Button
                      size="sm"
                      variant="primary"
                      isDisabled={dns01Busy || !isDns01Ready(dns01Input())}
                      onPress={() =>
                        void runDns01(dns01Status?.tls_mode === 'http_tls' ? 'repair' : 'setup')
                      }
                    >
                      {dns01Busy ? t('settings.dns01Running') : t('settings.dns01Submit')}
                    </Button>
                    <Button
                      size="sm"
                      variant="secondary"
                      isDisabled={dns01Busy}
                      onPress={() => setDns01Open(false)}
                    >
                      {t('dashboard.cancel')}
                    </Button>
                  </div>
                </div>
              )}
            </section>
            </div>
            </>
            )}

            <AlertDialog.Root
              isOpen={actionTarget !== null && actionTarget.kind !== 'profile'}
              onOpenChange={(open) => {
                if (!open) setActionTarget(null)
              }}
            >
              <AlertDialog.Backdrop>
                <AlertDialog.Container>
                  <AlertDialog.Dialog className={`${styles.confirmDialog} ${styles.actionsDialog}`}>
                    <AlertDialog.Header>
                      <div className={styles.actionsHead}>
                        <span
                          className={`${styles.actionsHeadIcon} ${
                            actionTarget?.kind === 'hysteria2'
                              ? styles.backendIconHyst
                              : styles.backendIconAwg
                          }`}
                        >
                          <img
                            src={actionTarget?.kind === 'hysteria2' ? hystLogo : amneziaLogo}
                            alt=""
                            className={styles.actionsHeadImg}
                          />
                        </span>
                        <div className={styles.actionsHeadText}>
                          <span className={styles.actionsKicker}>
                            {actionTarget?.kind === 'hysteria2'
                              ? t('settings.backendsHyst')
                              : t('settings.backendsAwg')}
                          </span>
                          <AlertDialog.Heading className={styles.actionsTitle}>
                            {actionTarget?.profile.name ?? ''}
                          </AlertDialog.Heading>
                        </div>
                      </div>
                    </AlertDialog.Header>
                    <AlertDialog.Body>
                      {actionTarget && actionTarget.kind !== 'profile' && (
                        <div className={styles.actionGroups}>
                          <p className={styles.settingsHint}>{t('settings.backendProfileHint')}</p>
                          <div className={styles.settingsGroup}>
                            <div className={styles.settingsGroupHead}>
                              <span className={styles.settingsGroupIcon}>
                                <Gauge size={15} />
                              </span>
                              <span className={styles.settingsGroupTitle}>
                                {t('settings.groupLimits')}
                              </span>
                            </div>
                            <p className={styles.settingsHint}>{t('settings.groupLimitsHint')}</p>
                            <div className={styles.settingsButtons}>
                              <Button
                                size="sm"
                                variant="secondary"
                                isDisabled={busy}
                                onPress={() => openExpire(actionTarget.profile)}
                              >
                                <CalendarClock size={14} />
                                {t('settings.backendsExpiryBtn')}
                              </Button>
                              {trafficSupported && (
                                <Button
                                  size="sm"
                                  variant="secondary"
                                  isDisabled={busy}
                                  onPress={() => openLimit(actionTarget.profile)}
                                >
                                  <Gauge size={14} />
                                  {t('settings.trafficBtn')}
                                </Button>
                              )}
                            </div>
                          </div>
                          <div className={styles.settingsGroup}>
                            <div className={styles.settingsGroupHead}>
                              <span className={styles.settingsGroupIcon}>
                                <ShieldCheck size={15} />
                              </span>
                              <span className={styles.settingsGroupTitle}>
                                {t('settings.groupAccess')}
                              </span>
                            </div>
                            <p className={styles.settingsHint}>{t('settings.groupAccessHint')}</p>
                            <div className={styles.settingsButtons}>
                              <Button
                                size="sm"
                                variant="secondary"
                                isDisabled={busy}
                                onPress={() => openRevoke(actionTarget.profile, true)}
                              >
                                <ShieldOff size={14} />
                                {t('settings.revokeBtn')}
                              </Button>
                            </div>
                          </div>
                          {!actionTarget.profile.multi_route && (
                            <div
                              className={`${styles.settingsGroup} ${styles.settingsGroupDanger}`}
                            >
                              <div className={styles.settingsGroupHead}>
                                <span className={styles.settingsGroupIcon}>
                                  <Trash2 size={15} />
                                </span>
                                <span className={styles.settingsGroupTitle}>
                                  {t('settings.groupDelete')}
                                </span>
                              </div>
                              <p className={styles.settingsHint}>
                                {t('settings.groupDeleteHint')}
                              </p>
                              <div className={styles.settingsButtons}>
                                <Button
                                  size="sm"
                                  variant="danger-soft"
                                  isDisabled={busy}
                                  onPress={() => setConfirmRemove(actionTarget.profile)}
                                >
                                  <Trash2 size={14} />
                                  {t('settings.deleteKey')}
                                </Button>
                              </div>
                            </div>
                          )}
                        </div>
                      )}
                    </AlertDialog.Body>
                    <AlertDialog.Footer>
                      <Button variant="secondary" onPress={() => setActionTarget(null)}>
                        {t('settings.done')}
                      </Button>
                    </AlertDialog.Footer>
                  </AlertDialog.Dialog>
                </AlertDialog.Container>
              </AlertDialog.Backdrop>
            </AlertDialog.Root>

            <AlertDialog.Root
              isOpen={pqTarget !== null}
              onOpenChange={(open) => {
                if (!open) {
                  setPqTarget(null)
                  setPqResult(null)
                  setPqError(null)
                }
              }}
            >
              <AlertDialog.Backdrop>
                <AlertDialog.Container>
                  <AlertDialog.Dialog className={styles.confirmDialog}>
                    <AlertDialog.Header>
                      <AlertDialog.Icon status="warning">
                        <Zap size={20} />
                      </AlertDialog.Icon>
                      <AlertDialog.Heading>
                        {t('settings.pqTitle')} — {pqTarget?.name ?? ''}
                      </AlertDialog.Heading>
                    </AlertDialog.Header>
                    <AlertDialog.Body>
                      <p className={styles.fpHint}>{t('settings.pqHint')}</p>
                      {!pqResult && (
                        <>
                          <span className={styles.fieldLabel}>{t('settings.pqTransport')}</span>
                          <div className={styles.profileActions}>
                            {PROTOCOLS.map((p) => (
                              <Button
                                key={p.id}
                                size="sm"
                                variant={pqTransport === p.id ? 'primary' : 'secondary'}
                                isDisabled={pqBusy}
                                onPress={() => setPqTransport(p.id)}
                              >
                                {p.label}
                              </Button>
                            ))}
                          </div>
                        </>
                      )}
                      {pqError && <p className={styles.error}>{pqError}</p>}
                      {pqResult?.link && (
                        <>
                          <p className={styles.fpHint}>{pqResult.note ?? t('settings.pqNote')}</p>
                          <div className={styles.profileActions}>
                            <Button
                              size="sm"
                              variant="secondary"
                              onPress={() =>
                                void copyWithToast(pqResult.link ?? '', t('settings.copied'))
                              }
                            >
                              <Copy size={13} />
                              {t('settings.pqCopy')}
                            </Button>
                          </div>
                          <p className={styles.fpNote}>{pqResult.link}</p>
                        </>
                      )}
                    </AlertDialog.Body>
                    <AlertDialog.Footer>
                      {!pqResult && (
                        <Button variant="primary" isDisabled={pqBusy} onPress={() => void addPqRoute()}>
                          {pqBusy ? t('settings.pqAdding') : t('settings.pqAdd')}
                        </Button>
                      )}
                      <Button
                        variant="secondary"
                        onPress={() => {
                          setPqTarget(null)
                          setPqResult(null)
                          setPqError(null)
                        }}
                      >
                        {t('settings.done')}
                      </Button>
                    </AlertDialog.Footer>
                  </AlertDialog.Dialog>
                </AlertDialog.Container>
              </AlertDialog.Backdrop>
            </AlertDialog.Root>
          </>
        )}
      </div>

      <AlertDialog.Root
        isOpen={confirmBackend !== null}
        onOpenChange={(open) => {
          if (!open) setConfirmBackend(null)
        }}
      >
        <AlertDialog.Backdrop>
          <AlertDialog.Container>
            <AlertDialog.Dialog className={styles.confirmDialog}>
              <AlertDialog.Header>
                <AlertDialog.Icon status="warning">
                  <Zap size={20} />
                </AlertDialog.Icon>
                <AlertDialog.Heading>
                  {t('settings.backendsConfirmTitleTemplate', {
                    action: confirmBackend ? t(BACKEND_CONFIRM_ACTION_KEYS[confirmBackend]) : ''
                  })}
                </AlertDialog.Heading>
              </AlertDialog.Header>
              <AlertDialog.Body>
                {confirmBackend === 'hysteria2-uninstall' && t('settings.backendsConfirmHyst')}
                {confirmBackend === 'awg-uninstall' && t('settings.backendsConfirmAwg')}
                {confirmBackend === 'awg31-on' && t('settings.backendsConfirm31On')}
                {confirmBackend === 'awg31-off' && t('settings.backendsConfirm31Off')}
                {confirmBackend === 'hysteria2-revoke-all' &&
                  t('settings.backendsConfirmRevokeHystAll')}
                {confirmBackend === 'awg-revoke-all' && t('settings.backendsConfirmRevokeAwgAll')}
              </AlertDialog.Body>
              <AlertDialog.Footer>
                <Button variant="secondary" onPress={() => setConfirmBackend(null)}>
                  {t('dashboard.cancel')}
                </Button>
                <Button
                  variant="danger"
                  onPress={() => {
                    if (confirmBackend === 'hysteria2-uninstall') void uninstallHysteria2()
                    else if (confirmBackend === 'awg-uninstall') void uninstallAwg()
                    else if (confirmBackend === 'awg31-on') void toggle31(true)
                    else if (confirmBackend === 'awg31-off') void toggle31(false)
                    else if (confirmBackend === 'hysteria2-revoke-all') void revokeBackendKeys('hysteria2')
                    else if (confirmBackend === 'awg-revoke-all') void revokeBackendKeys('awg')
                    setConfirmBackend(null)
                  }}
                >
                  {confirmBackend ? t(BACKEND_CONFIRM_ACTION_KEYS[confirmBackend]) : t('settings.done')}
                </Button>
              </AlertDialog.Footer>
            </AlertDialog.Dialog>
          </AlertDialog.Container>
        </AlertDialog.Backdrop>
      </AlertDialog.Root>

      <AlertDialog.Root
        isOpen={confirmRemove !== null}
        onOpenChange={(open) => {
          if (!open) setConfirmRemove(null)
        }}
      >
        <AlertDialog.Backdrop>
          <AlertDialog.Container>
            <AlertDialog.Dialog className={styles.confirmDialog}>
              <AlertDialog.Header>
                <AlertDialog.Icon status="danger">
                  <Trash2 size={20} />
                </AlertDialog.Icon>
                <AlertDialog.Heading>
                  {t('settings.deleteKeyTitle')}
                </AlertDialog.Heading>
              </AlertDialog.Header>
              <AlertDialog.Body>
                {t('settings.deleteKeyBody', {
                  name: confirmRemove?.name ?? '',
                  server: server.name,
                })}
              </AlertDialog.Body>
              <AlertDialog.Footer>
                <Button variant="secondary" onPress={() => setConfirmRemove(null)}>
                  {t('dashboard.cancel')}
                </Button>
                <Button
                  variant="danger"
                  onPress={() => {
                    if (confirmRemove) void remove(confirmRemove)
                    setConfirmRemove(null)
                  }}
                >
                  {t('settings.deleteKey')}
                </Button>
              </AlertDialog.Footer>
            </AlertDialog.Dialog>
          </AlertDialog.Container>
        </AlertDialog.Backdrop>
      </AlertDialog.Root>

      <AlertDialog.Root
        isOpen={revokeTarget !== null}
        onOpenChange={(open) => {
          if (!open && !revokeBusy) setRevokeTarget(null)
        }}
      >
        <AlertDialog.Backdrop className={styles.blurBackdrop}>
          <AlertDialog.Container>
            <AlertDialog.Dialog className={`${styles.confirmDialog} ${styles.revokeWide}`}>
              <AlertDialog.Header>
                <AlertDialog.Icon status="danger">
                  <ShieldOff size={20} />
                </AlertDialog.Icon>
                <AlertDialog.Heading>
                  {t('settings.revokeTitle')} — {revokeTarget?.name ?? ''}
                </AlertDialog.Heading>
              </AlertDialog.Header>
              <AlertDialog.Body>
                {revokeStep === 'choose' && (
                  <>
                    <p className={styles.fpHint}>{t('settings.revokeHint')}</p>
                    <div className={styles.revokeOptions}>
                      <button
                        type="button"
                        className={styles.revokeOption}
                        disabled={revokeBusy}
                        onClick={() => void runRevoke('token')}
                      >
                        <span className={styles.revokeOptionTitle}>
                          {/* Календарь здесь читался как «срок»: эта опция выдаёт новую
                              ссылку подписки, uuid не меняется. */}
                          <Link2 size={14} />
                          {t('settings.revokeTokenTitle')}
                        </span>
                        <span className={styles.revokeOptionDesc}>
                          {t('settings.revokeTokenDesc')}
                        </span>
                      </button>
                      <button
                        type="button"
                        className={`${styles.revokeOption} ${styles.revokeOptionDanger}`}
                        disabled={revokeBusy}
                        onClick={() => {
                          setRevokeStep('confirm')
                        }}
                      >
                        <span className={styles.revokeOptionTitle}>
                          <ShieldOff size={14} />
                          {t('settings.revokeFullTitle')}
                        </span>
                        <span className={styles.revokeOptionDesc}>
                          {t('settings.revokeFullDesc')}
                        </span>
                      </button>
                    </div>
                  </>
                )}

                {revokeStep === 'confirm' && (
                  <>
                    <p className={styles.sniWarning}>{t('settings.revokeFullWarning')}</p>
                    <p className={styles.fpNote}>{t('settings.revokeFullSecondConfirm')}</p>
                  </>
                )}

                {revokeStep === 'done' && (
                  <>
                    <p className={styles.fpCurrent}>
                      {t('settings.revokeDone', { name: revokeTarget?.name ?? '' })}
                    </p>
                    {revokeUrl && <p className={styles.revokeNewUrl}>{revokeUrl}</p>}
                    {revokeUrl && (
                      <Button
                        size="sm"
                        variant="secondary"
                        onPress={() => void copyWithToast(revokeUrl, t('settings.copied'))}
                      >
                        <Copy size={13} />
                        {t('settings.revokeCopyNew')}
                      </Button>
                    )}
                  </>
                )}
              </AlertDialog.Body>
              <AlertDialog.Footer>
                {revokeStep === 'done' ? (
                  <Button variant="primary" onPress={() => setRevokeTarget(null)}>
                    {t('settings.done')}
                  </Button>
                ) : (
                  <>
                    <Button
                      variant="secondary"
                      isDisabled={revokeBusy}
                      onPress={() =>
                        revokeStep === 'confirm'
                          ? (revokeFullOnly
                              ? setRevokeTarget(null)
                              : setRevokeStep('choose'))
                          : setRevokeTarget(null)
                      }
                    >
                      {t('dashboard.cancel')}
                    </Button>
                    {revokeStep === 'confirm' && (
                      <Button
                        variant="danger-soft"
                        isDisabled={revokeBusy}
                        onPress={() => void runRevoke('full')}
                      >
                        {revokeBusy
                          ? t('settings.revoking')
                          : t('settings.revokeFullConfirm')}
                      </Button>
                    )}
                  </>
                )}
              </AlertDialog.Footer>
            </AlertDialog.Dialog>
          </AlertDialog.Container>
        </AlertDialog.Backdrop>
      </AlertDialog.Root>

      <AlertDialog.Root
        isOpen={expireTarget !== null || expireChooser !== null}
        onOpenChange={(open) => {
          if (!open && !expireBusy) {
            setExpireTarget(null)
            setExpireChooser(null)
          }
        }}
      >
        <AlertDialog.Backdrop className={styles.blurBackdrop}>
          {/* placement="top": диалог прижат к верху. Иначе при центрировании
              шапка календаря уезжает вверх/вниз при смене месяца (5 недель ↔ 6),
              и стрелки «прыгают» под курсором. */}
          <AlertDialog.Container placement="top">
            <AlertDialog.Dialog className={styles.confirmDialog}>
              <AlertDialog.Header>
                <AlertDialog.Heading>
                  {t('settings.expireTitle')} — {expireTarget?.name ?? ''}
                </AlertDialog.Heading>
              </AlertDialog.Header>
              <AlertDialog.Body>
                {expireTarget === null && expireChooser !== null ? (
                  <div>
                    <p className={styles.fpHint}>{t('settings.backendsExpiryChoose')}</p>
                    <div className={styles.revokeOptions}>
                      {expireChooser.map((p) => (
                        <Button
                          key={p.name}
                          className={styles.revokeOption}
                          size="sm"
                          variant="secondary"
                          onPress={() => {
                            setExpireTarget(p)
                            setExpireChooser(null)
                          }}
                        >
                          {p.name}
                          {p.expire_date ? ` — ${p.expire_date}` : ''}
                        </Button>
                      ))}
                    </div>
                  </div>
                ) : (
                  <>
                    <p className={styles.fpHint}>{t('settings.expireHintBody')}</p>
                    {expireTarget && (
                      <p className={styles.fpCurrent}>
                        {t('settings.expireCurrent', {
                          value: expireTarget.expire
                            ? describeExpire(
                                expireTarget.expire,
                                false,
                                Date.now(),
                                expireTarget.expire_date
                              ).date
                            : t('settings.expireNever')
                        })}
                      </p>
                    )}
                    <div className={styles.fpField}>
                      <span className={styles.fieldLabel}>{t('settings.expireSelect')}</span>
                      <div className={styles.inlineRow}>
                        {[7, 30, 90, 365].map((d) => (
                          <Button
                            key={d}
                            size="sm"
                            variant="secondary"
                            isDisabled={expireBusy}
                            onPress={() => setExpireDate(presetDate(d, Date.now()))}
                          >
                            {t('settings.expirePreset', { count: d })}
                          </Button>
                        ))}
                      </div>
                    </div>
                    <div className={styles.fpField}>
                      <CalendarPicker
                        value={expireDate}
                        disabled={expireBusy}
                        onChange={setExpireDate}
                      />
                      {expireDate && (
                        <p className={styles.fpCurrent}>
                          {t('settings.expirePicked', { date: expireDate })}
                        </p>
                      )}
                    </div>
                    <p className={styles.fpNote}>{t('settings.expireEnforced')}</p>
                    {/* Снятие срока — отдельное осознанное действие в теле диалога:
                        раньше оно жило в футере рядом с «Сохранить» и требовало
                        второй кнопки «Готово», что путало (одно действие — два клика). */}
                    {expireTarget?.expire ? (
                      <div className={styles.expireClearRow}>
                        <Button
                          variant="danger-soft"
                          size="sm"
                          isDisabled={expireBusy}
                          onPress={() => void applyExpire(null)}
                        >
                          <CalendarX size={14} />
                          {t('settings.expireClear')}
                        </Button>
                        <span className={styles.expireClearHint}>
                          {t('settings.expireClearHint')}
                        </span>
                      </div>
                    ) : null}
                  </>
                )}
              </AlertDialog.Body>
              <AlertDialog.Footer>
                {/* Отмена — слева и всегда только закрывает диалог, без действий. */}
                <Button
                  variant="secondary"
                  isDisabled={expireBusy}
                  onPress={() => setExpireTarget(null)}
                >
                  {t('dashboard.cancel')}
                </Button>
                <Button
                  variant="primary"
                  className={
                    expireDone ? styles.btnSuccess : expireBusy ? styles.glowPulse : undefined
                  }
                  isDisabled={
                    expireBusy ||
                    expireDone ||
                    !isFutureDate(expireDate, Date.now())
                  }
                  onPress={() => void applyExpire(expireDate)}
                >
                  {expireDone ? <Check size={16} /> : null}
                  {expireDone
                    ? t('settings.done')
                    : t(expireBusy ? 'settings.expireSaving' : 'settings.expireSave')}
                </Button>
              </AlertDialog.Footer>
            </AlertDialog.Dialog>
          </AlertDialog.Container>
        </AlertDialog.Backdrop>
      </AlertDialog.Root>

      <AlertDialog.Root
        isOpen={limitTarget !== null}
        onOpenChange={(open) => {
          if (!open && !limitBusy) setLimitTarget(null)
        }}
      >
        <AlertDialog.Backdrop className={styles.blurBackdrop}>
          <AlertDialog.Container placement="top">
            <AlertDialog.Dialog className={styles.confirmDialog}>
              <AlertDialog.Header>
                <AlertDialog.Heading>
                  {t('settings.trafficTitle')} — {limitTarget?.name ?? ''}
                </AlertDialog.Heading>
              </AlertDialog.Header>
              <AlertDialog.Body>
                <p className={styles.fpHint}>{t('settings.trafficHintBody')}</p>
                {limitTarget && (
                  <p className={styles.fpCurrent}>
                    {limitTarget.traffic_disabled
                      ? t('settings.trafficDisabledNote')
                      : (limitTarget.traffic_limit ?? 0) > 0
                        ? t('settings.trafficUsedOf', {
                            used: formatBytes(limitTarget.traffic_used ?? 0),
                            limit: formatBytes(limitTarget.traffic_limit ?? 0)
                          })
                        : t('settings.trafficUsedOnly', {
                            used: formatBytes(limitTarget.traffic_used ?? 0)
                          })}
                  </p>
                )}
                <div className={styles.fpField}>
                  <span className={styles.fieldLabel}>{t('settings.trafficPresets')}</span>
                  <div className={styles.inlineRow}>
                    {TRAFFIC_PRESETS.map((preset) => (
                      <Button
                        key={preset}
                        size="sm"
                        variant="secondary"
                        isDisabled={limitBusy}
                        onPress={() => setLimitValue(preset)}
                      >
                        {preset.replace('GB', ' GB').replace('TB', ' TB')}
                      </Button>
                    ))}
                  </div>
                </div>
                <div className={styles.fpField}>
                  <span className={styles.fieldLabel}>{t('settings.trafficCustom')}</span>
                  <TextField variant="secondary" className={styles.nameField}>
                    <Input
                      value={limitValue}
                      disabled={limitBusy}
                      placeholder={t('settings.trafficPlaceholder')}
                      onChange={(e) => setLimitValue(e.target.value)}
                    />
                  </TextField>
                  {limitInputValue !== '' && !limitInputValid && (
                    <p className={styles.fpNote}>{t('settings.trafficInvalid')}</p>
                  )}
                </div>
                <div className={styles.expireClearRow}>
                  <Button
                    size="sm"
                    variant={limitReset ? 'primary' : 'secondary'}
                    isDisabled={limitBusy}
                    onPress={() => setLimitReset((value) => !value)}
                  >
                    <RefreshCw size={14} />
                    {t('settings.trafficReset')}
                  </Button>
                  <span className={styles.expireClearHint}>{t('settings.trafficResetHint')}</span>
                </div>
                {limitTarget && (limitTarget.traffic_limit ?? 0) > 0 ? (
                  <div className={styles.expireClearRow}>
                    <Button
                      variant="danger-soft"
                      size="sm"
                      isDisabled={limitBusy}
                      onPress={() => void applyLimit('none', false)}
                    >
                      <Gauge size={14} />
                      {t('settings.trafficClear')}
                    </Button>
                    <span className={styles.expireClearHint}>
                      {t('settings.trafficClearHint')}
                    </span>
                  </div>
                ) : null}
              </AlertDialog.Body>
              <AlertDialog.Footer>
                <Button
                  variant="secondary"
                  isDisabled={limitBusy}
                  onPress={() => setLimitTarget(null)}
                >
                  {t('dashboard.cancel')}
                </Button>
                <Button
                  variant="primary"
                  className={
                    limitDone ? styles.btnSuccess : limitBusy ? styles.glowPulse : undefined
                  }
                  isDisabled={limitBusy || limitDone || !canSaveLimit}
                  onPress={() => void applyLimit(limitInputValue || null, limitReset)}
                >
                  {limitDone ? <Check size={16} /> : null}
                  {limitDone
                    ? t('settings.done')
                    : t(limitBusy ? 'settings.trafficSaving' : 'settings.trafficSave')}
                </Button>
              </AlertDialog.Footer>
            </AlertDialog.Dialog>
          </AlertDialog.Container>
        </AlertDialog.Backdrop>
      </AlertDialog.Root>

      <AlertDialog.Root
        isOpen={createExpireOpen}
        onOpenChange={(open) => {
          if (!open) setCreateExpireOpen(false)
        }}
      >
        <AlertDialog.Backdrop className={styles.blurBackdrop}>
          {/* placement="top": диалог прижат к верху, поэтому шестая неделя
              календаря раскрывается ВНИЗ и не сдвигает шапку со стрелками. */}
          <AlertDialog.Container placement="top">
            <AlertDialog.Dialog className={styles.confirmDialog}>
              <AlertDialog.Header>
                <AlertDialog.Heading>{t('settings.createExpire')}</AlertDialog.Heading>
              </AlertDialog.Header>
              <AlertDialog.Body>
                <p className={styles.fpHint}>{t('settings.createExpireHint')}</p>
                <CalendarPicker
                  value={createExpire}
                  onChange={setCreateExpire}
                  min={todayIso()}
                />
              </AlertDialog.Body>
              <AlertDialog.Footer>
                {createExpire ? (
                  <Button variant="danger-soft" onPress={() => setCreateExpire('')}>
                    <CalendarX size={14} />
                    {t('settings.expireClear')}
                  </Button>
                ) : null}
                <Button variant="secondary" onPress={() => setCreateExpireOpen(false)}>
                  {t('settings.done')}
                </Button>
              </AlertDialog.Footer>
            </AlertDialog.Dialog>
          </AlertDialog.Container>
        </AlertDialog.Backdrop>
      </AlertDialog.Root>

      <AlertDialog.Root
        isOpen={fpTarget !== null}
        onOpenChange={(open) => {
          if (!open && !fpBusy) setFpTarget(null)
        }}
      >
        <AlertDialog.Backdrop>
          <AlertDialog.Container>
            <AlertDialog.Dialog className={styles.confirmDialog}>
              <AlertDialog.Header>
                <AlertDialog.Heading>
                  {t('settings.fpTitle')} — {fpTarget?.name ?? ''}
                </AlertDialog.Heading>
              </AlertDialog.Header>
              <AlertDialog.Body>
                <p className={styles.fpHint}>{t('settings.fpHint')}</p>
                {fpTarget && (
                  <p className={styles.fpCurrent}>
                    {t('settings.fpCurrent', { fp: fpTarget.fingerprint || '—' })}
                  </p>
                )}
                {fpTarget?.multi_route && (
                  <div className={styles.fpField}>
                    <span className={styles.fieldLabel}>{t('settings.fpRoute')}</span>
                    <div className={styles.fpRouteGrid}>
                      {Array.from({ length: fpTarget.routes }, (_, i) => i + 1).map((r) => (
                        <button
                          key={r}
                          type="button"
                          className={`${styles.fpRouteCard} ${
                            fpRoute === r ? styles.fpRouteCardActive : ''
                          }`}
                          disabled={fpBusy}
                          onClick={() => setFpRoute(r)}
                        >
                          {r}
                        </button>
                      ))}
                    </div>
                  </div>
                )}
                <div className={styles.fpField}>
                  <span className={styles.fieldLabel}>{t('settings.fpSelect')}</span>
                  <div className={styles.fpGrid}>
                    {FINGERPRINTS.map((fp) => (
                      <button
                        key={fp}
                        type="button"
                        className={`${styles.fpCard} ${
                          fpValue === fp ? styles.fpCardActive : ''
                        }`}
                        disabled={fpBusy}
                        onClick={() => setFpValue(fp)}
                      >
                        <span className={styles.fpCardName}>{fp}</span>
                        <span className={styles.fpCardDesc}>{t(`settings.fpOptions.${fp}`)}</span>
                      </button>
                    ))}
                  </div>
                </div>
                <p className={styles.fpNote}>{t('settings.fpRemember')}</p>
                {fpError && <p className={styles.error}>{fpError}</p>}
              </AlertDialog.Body>
              <AlertDialog.Footer>
                <Button variant="secondary" isDisabled={fpBusy} onPress={() => setFpTarget(null)}>
                  {t('dashboard.cancel')}
                </Button>
                <Button
                  variant="primary"
                  className={
                    fpDone ? styles.btnSuccess : fpBusy ? styles.glowPulse : undefined
                  }
                  isDisabled={fpBusy || fpDone || !fpValue}
                  onPress={changeFingerprint}
                >
                  {fpDone ? <Check size={16} /> : null}
                  {fpDone
                    ? t('settings.done')
                    : t(fpBusy ? 'settings.changingFingerprint' : 'settings.changeFingerprint')}
                </Button>
              </AlertDialog.Footer>
            </AlertDialog.Dialog>
          </AlertDialog.Container>
        </AlertDialog.Backdrop>
      </AlertDialog.Root>

      <AlertDialog.Root
        isOpen={sniTarget !== null}
        onOpenChange={(open) => {
          if (!open && !sniBusy) setSniTarget(null)
        }}
      >
        <AlertDialog.Backdrop>
          <AlertDialog.Container>
            <AlertDialog.Dialog className={styles.confirmDialog}>
              <AlertDialog.Header>
                <AlertDialog.Heading>
                  {t('settings.sniTitle')} — {sniTarget?.name ?? ''}
                </AlertDialog.Heading>
              </AlertDialog.Header>
              <AlertDialog.Body>
                <p className={styles.sniWarning}>{t('settings.sniWarning')}</p>
                {sniTarget && (
                  <p className={styles.fpCurrent}>
                    {t('settings.sniCurrent', { sni: sniTarget.sni || '—' })}
                  </p>
                )}
                {sniTarget?.multi_route && (
                  <div className={styles.fpField}>
                    <span className={styles.fieldLabel}>{t('settings.fpRoute')}</span>
                    <div className={styles.fpRouteGrid}>
                      {Array.from({ length: sniTarget.routes }, (_, i) => i + 1).map((r) => (
                        <button
                          key={r}
                          type="button"
                          className={`${styles.fpRouteCard} ${
                            sniRoute === r ? styles.fpRouteCardActive : ''
                          }`}
                          disabled={sniBusy}
                          onClick={() => setSniRoute(r)}
                        >
                          {r}
                        </button>
                      ))}
                    </div>
                  </div>
                )}
                <div className={styles.fpField}>
                  <span className={styles.fieldLabel}>{t('settings.sniSelect')}</span>
                  {sniList === null ? (
                    sniBusy ? (
                      <div className={styles.sniSkeleton}>
                        {Array.from({ length: 3 }, (_, i) => (
                          <div key={i} className={styles.sniSkeletonCat}>
                            <span className={styles.sniSkeletonLabel} />
                            <div className={styles.sniSkeletonGrid}>
                              {Array.from({ length: i === 1 ? 4 : 2 }, (_, j) => (
                                <span key={j} className={styles.sniSkeletonCard} />
                              ))}
                            </div>
                          </div>
                        ))}
                      </div>
                    ) : (
                      <div className={styles.loadRow}>
                        <Button
                          variant="secondary"
                          size="sm"
                          isDisabled={sniBusy}
                          onPress={async () => {
                            setSniBusy(true)
                            setError(null)
                            try {
                              const result = await window.api.profiles.sniList(server.id, access)
                              if (result.ok) {
                                setSniList(result.snis ?? [])
                              } else {
                                setError(result.error ?? t('settings.sniFailed'))
                              }
                            } catch (err) {
                              setError(err instanceof Error ? err.message : String(err))
                            } finally {
                              setSniBusy(false)
                            }
                          }}
                        >
                          <Download size={14} />
                          {t('settings.loadSni')}
                        </Button>
                      </div>
                    )
                  ) : (
                    <div className={styles.sniList}>
                      {SNI_CATEGORIES.map((category) => {
                        const items = sniList.filter((s) => s.category === category)
                        if (items.length === 0) return null
                        return (
                          <div key={category} className={styles.sniCat}>
                            <span className={styles.sniCatLabel}>
                              {t(`settings.sniCategories.${category}`)}
                            </span>
                            <div className={styles.sniGrid}>
                              {items.map((item) => (
                                <button
                                  key={item.sni}
                                  type="button"
                                  className={`${styles.sniCard} ${
                                    sniValue === item.sni ? styles.sniCardActive : ''
                                  }`}
                                  disabled={sniBusy}
                                  onClick={() => setSniValue(item.sni)}
                                >
                                  {item.sni}
                                </button>
                              ))}
                            </div>
                          </div>
                        )
                      })}
                    </div>
                  )}
                </div>
                <div className={styles.fpField}>
                  <TextField variant="secondary" className={styles.fieldWide}>
                    <Input
                      value={sniValue}
                      disabled={sniBusy}
                      placeholder="www.example.com"
                      onChange={(e) => setSniValue(e.target.value)}
                    />
                  </TextField>
                </div>
                <p className={styles.fpNote}>{t('settings.sniReconnectHint')}</p>
                {sniError && <p className={styles.error}>{sniError}</p>}
              </AlertDialog.Body>
              <AlertDialog.Footer>
                <Button variant="secondary" isDisabled={sniBusy} onPress={() => setSniTarget(null)}>
                  {t('dashboard.cancel')}
                </Button>
                <Button
                  variant="primary"
                  className={
                    sniDone ? styles.btnSuccess : sniBusy ? styles.glowPulse : undefined
                  }
                  isDisabled={sniBusy || sniDone || !sniValue.trim()}
                  onPress={changeSni}
                >
                  {sniDone ? <Check size={16} /> : null}
                  {sniDone
                    ? t('settings.done')
                    : t(sniBusy ? 'settings.changingSni' : 'settings.changeSni')}
                </Button>
              </AlertDialog.Footer>
            </AlertDialog.Dialog>
          </AlertDialog.Container>
        </AlertDialog.Backdrop>
      </AlertDialog.Root>

      <AlertDialog.Root
        isOpen={portTarget !== null}
        onOpenChange={(open) => {
          if (!open && !portBusy) setPortTarget(null)
        }}
      >
        <AlertDialog.Backdrop>
          <AlertDialog.Container>
            <AlertDialog.Dialog className={styles.confirmDialog}>
              <AlertDialog.Header>
                <AlertDialog.Heading>
                  {t('settings.portTitle')} — {portTarget?.name ?? ''}
                </AlertDialog.Heading>
              </AlertDialog.Header>
              <AlertDialog.Body>
                <p className={styles.portWarning}>{t('settings.portWarning')}</p>
                {portTarget && (
                  <p className={styles.fpCurrent}>
                    {t('settings.portCurrent', { port: portTarget.port ?? '—' })}
                  </p>
                )}
                {portTarget?.multi_route && (
                  <div className={styles.fpField}>
                    <span className={styles.fieldLabel}>{t('settings.fpRoute')}</span>
                    <div className={styles.fpRouteGrid}>
                      {Array.from({ length: portTarget.routes }, (_, i) => i + 1).map((r) => (
                        <button
                          key={r}
                          type="button"
                          className={`${styles.fpRouteCard} ${
                            portRoute === r ? styles.fpRouteCardActive : ''
                          }`}
                          disabled={portBusy}
                          onClick={() => setPortRoute(r)}
                        >
                          {r}
                        </button>
                      ))}
                    </div>
                  </div>
                )}
                <div className={styles.fpField}>
                  <span className={styles.fieldLabel}>{t('settings.portSelect')}</span>
                  <div className={styles.portGrid}>
                    <button
                      type="button"
                      className={`${styles.portCard} ${
                        portMode === 'random' ? styles.portCardActive : ''
                      }`}
                      disabled={portBusy}
                      onClick={() => {
                        setPortMode('random')
                        setPortValue('')
                      }}
                    >
                      <span className={styles.portCardName}>{t('settings.portRandom')}</span>
                      <span className={styles.portCardDesc}>{t('settings.portRandomHint')}</span>
                    </button>
                    {PORT_PRESETS.map((p) => (
                      <button
                        key={p}
                        type="button"
                        className={`${styles.portCard} ${
                          portMode === 'preset' && portValue === String(p)
                            ? styles.portCardActive
                            : ''
                        }`}
                        disabled={portBusy}
                        onClick={() => {
                          setPortMode('preset')
                          setPortValue(String(p))
                        }}
                      >
                        <span className={styles.portCardName}>{p}</span>
                      </button>
                    ))}
                  </div>
                </div>
                <div className={styles.fpField}>
                  <TextField variant="secondary" className={styles.fieldWide}>
                    <Input
                      type="number"
                      min={1}
                      max={65535}
                      value={portMode === 'custom' ? portValue : ''}
                      disabled={portBusy}
                      placeholder={t('settings.portCustomPlaceholder')}
                      onChange={(e) => {
                        setPortMode('custom')
                        setPortValue(e.target.value)
                      }}
                      onFocus={() => {
                        setPortMode('custom')
                        setPortValue('')
                      }}
                    />
                  </TextField>
                </div>
                <p className={styles.fpNote}>{t('settings.portReconnectHint')}</p>
                {portError && <p className={styles.error}>{portError}</p>}
              </AlertDialog.Body>
              <AlertDialog.Footer>
                <Button variant="secondary" isDisabled={portBusy} onPress={() => setPortTarget(null)}>
                  {t('dashboard.cancel')}
                </Button>
                <Button
                  variant="primary"
                  className={
                    portDone ? styles.btnSuccess : portBusy ? styles.glowPulse : undefined
                  }
                  isDisabled={
                    portBusy ||
                    portDone ||
                    (portMode !== 'random' &&
                      (!/^[0-9]+$/.test(portValue) ||
                        Number(portValue) < 1 ||
                        Number(portValue) > 65535))
                  }
                  onPress={changePort}
                >
                  {portDone ? <Check size={16} /> : null}
                  {portDone
                    ? t('settings.done')
                    : t(portBusy ? 'settings.changingPort' : 'settings.changePort')}
                </Button>
              </AlertDialog.Footer>
            </AlertDialog.Dialog>
          </AlertDialog.Container>
        </AlertDialog.Backdrop>
      </AlertDialog.Root>

      <AlertDialog.Root
        isOpen={confirmHostKeyReset}
        onOpenChange={(open) => {
          if (!open && !hostKeyResetBusy) setConfirmHostKeyReset(false)
        }}
      >
        <AlertDialog.Backdrop>
          <AlertDialog.Container>
            <AlertDialog.Dialog className={styles.confirmDialog}>
              <AlertDialog.Header>
                <AlertDialog.Icon status="danger">
                  <Fingerprint size={20} />
                </AlertDialog.Icon>
                <AlertDialog.Heading>{t('sshAccess.hostKeyResetTitle')}</AlertDialog.Heading>
              </AlertDialog.Header>
              <AlertDialog.Body>
                {t('sshAccess.hostKeyResetBody', {
                  server: server.name,
                  fingerprint: hostKeyFingerprint ?? '—'
                })}
              </AlertDialog.Body>
              <AlertDialog.Footer>
                <Button
                  variant="secondary"
                  isDisabled={hostKeyResetBusy}
                  onPress={() => setConfirmHostKeyReset(false)}
                >
                  {t('dashboard.cancel')}
                </Button>
                <Button
                  variant="danger"
                  isDisabled={hostKeyResetBusy}
                  onPress={forgetHostKey}
                >
                  {t('sshAccess.resetHostKey')}
                </Button>
              </AlertDialog.Footer>
            </AlertDialog.Dialog>
          </AlertDialog.Container>
        </AlertDialog.Backdrop>
      </AlertDialog.Root>

      <AlertDialog.Root
        isOpen={confirmUninstall}
        onOpenChange={(open) => {
          if (!open) setConfirmUninstall(false)
        }}
      >
        <AlertDialog.Backdrop>
          <AlertDialog.Container>
            <AlertDialog.Dialog className={styles.confirmDialog}>
              <AlertDialog.Header>
                <AlertDialog.Icon status="danger">
                  <Trash2 size={20} />
                </AlertDialog.Icon>
                <AlertDialog.Heading>
                  {t('settings.uninstallTitle')}
                </AlertDialog.Heading>
              </AlertDialog.Header>
              <AlertDialog.Body>
                {t('settings.uninstallBody', { name: server.name })}
              </AlertDialog.Body>
              <AlertDialog.Footer>
                <Button variant="secondary" onPress={() => setConfirmUninstall(false)}>
                  {t('dashboard.cancel')}
                </Button>
                <Button variant="danger" onPress={uninstallServer}>
                  {t('settings.uninstallServer')}
                </Button>
              </AlertDialog.Footer>
            </AlertDialog.Dialog>
          </AlertDialog.Container>
        </AlertDialog.Backdrop>
      </AlertDialog.Root>
    </div>
  )
}