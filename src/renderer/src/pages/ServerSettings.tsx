import { Fragment, useEffect, useMemo, useRef, useState } from 'react'
import QRCode from 'qrcode'
import { Button, TextField, Label, Input, Chip, Spinner, AlertDialog } from '@heroui/react'
import {
  Settings2,
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
  Zap
} from 'lucide-react'
import { useTranslation } from 'react-i18next'
import type {
  BackendStatusResult,
  Server,
  ServerProfile,
  SniEntry,
  SshAccessInput
} from '@shared/types'
import { describeExpire, isFutureDate, presetDate } from '@shared/expire'
import { todayIso } from '@shared/calendar'
import { buildAwgVpnUrl, stripAwgComments } from '@shared/awg'
import { isSshAccessReady, SshAccessForm } from '../components/SshAccessForm'
import { CalendarPicker } from '../components/CalendarPicker'
import { shouldAutoConnectServer } from './server-access'
import styles from './ServerSettings.module.css'
import hystLogo from '../assets/hysteria-logo.svg'
import amneziaLogo from '../assets/amnezia-logo.jpg'

interface ServerSettingsProps {
  server: Server
  /** Открыт по «Изменить доступ» с карточки сервера: показать форму, не автоподключаясь. */
  editingAccess?: boolean
  onBack: () => void
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

export const SNI_CATEGORIES = [
  'ru_whitelist',
  'yandex_cdn',
  'foreign',
  'fallback'
] as const

export const PORT_PRESETS = [443, 8443, 2053, 2083, 2087, 2096, 9443, 8080] as const

export function ServerSettings({
  server,
  editingAccess = false,
  onBack
}: ServerSettingsProps): React.JSX.Element {
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
  // QR-модалка выдачи ключей бэкенд-боксов. Диалог «Ключи» убран:
  // полное копирование только на странице Ключей (решение 2026-10-06).
  const [keysQrUrl, setKeysQrUrl] = useState<string | null>(null)
  const [keysQrData, setKeysQrData] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [toast, setToast] = useState<string | null>(null)
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
  const [updateMenuOpen, setUpdateMenuOpen] = useState(false)
  const [uninstalling, setUninstalling] = useState(false)
  const [confirmUninstall, setConfirmUninstall] = useState(false)
  const [confirmRemove, setConfirmRemove] = useState<ServerProfile | null>(null)

  const [fpTarget, setFpTarget] = useState<ServerProfile | null>(null)
  const [fpRoute, setFpRoute] = useState<number>(1)
  const [fpValue, setFpValue] = useState<string>('firefox')
  const [fpBusy, setFpBusy] = useState(false)
  const [fpDone, setFpDone] = useState(false)

  const [sniTarget, setSniTarget] = useState<ServerProfile | null>(null)
  const [sniRoute, setSniRoute] = useState<number>(1)
  const [sniValue, setSniValue] = useState('')
  const [sniBusy, setSniBusy] = useState(false)
  const [sniDone, setSniDone] = useState(false)
  const [sniList, setSniList] = useState<SniEntry[] | null>(null)

  const [portTarget, setPortTarget] = useState<ServerProfile | null>(null)
  const [portRoute, setPortRoute] = useState<number>(1)
  const [portMode, setPortMode] = useState<'preset' | 'custom' | 'random'>('random')
  const [portValue, setPortValue] = useState('')
  const [portBusy, setPortBusy] = useState(false)
  const [portDone, setPortDone] = useState(false)

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
    const onEsc = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') setKeysQrUrl(null)
    }
    document.addEventListener('keydown', onEsc)
    return () => document.removeEventListener('keydown', onEsc)
  }, [keysQrUrl])

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
        setError(result.error ?? t('settings.fpFailed'))
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setFpBusy(false)
    }
  }

  const changeSni = async (): Promise<void> => {
    if (!sniTarget || !sniValue.trim() || !accessReady) return
    setSniBusy(true)
    setError(null)
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
        setError(result.error ?? t('settings.sniFailed'))
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setSniBusy(false)
    }
  }

  const changePort = async (): Promise<void> => {
    if (!portTarget || !accessReady) return
    setPortBusy(true)
    setError(null)
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
          setError(t('settings.firewallWarning'))
          return
        }
        toastText(t('settings.portChanged', { name: portTarget.name, port: result.port ?? input.port }))
        setPortDone(true)
        setTimeout(() => {
          setPortTarget(null)
          setPortDone(false)
        }, 400)
      } else {
        setError(result.error ?? t('settings.portFailed'))
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setPortBusy(false)
    }
  }

  const copyUrl = async (profile: ServerProfile): Promise<void> => {
    if (!profile.subscription_url) return
    await navigator.clipboard.writeText(profile.subscription_url)
    toastText(t('settings.copied'))
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
        {expired
          ? t('settings.expireExpired')
          : t('settings.expireUntil', { date: info.date })}
      </Chip>
    )
  }

  /**
   * Сервер старой версии не отдаёт поле expire: управление сроками недоступно.
   * Без этой проверки GUI молча показывал «бессрочно» — как будто срока нет.
   */
  const expireSupported = (profiles ?? []).some((p) => p.expire_supported === true)

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
      setUpdateMenuOpen(false)
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
      await action()
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

  const transportLabel = (profile: ServerProfile): string =>
    profile.multi_route ? `${profile.transport} · ${profile.routes} ${t('settings.routes')}` : profile.transport

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
          <Settings2 size={20} className={styles.titleIcon} />
          {t('settings.title')}
        </h1>
        <span className={styles.serverName}>{server.name}</span>
        {connected && (
          <div className={styles.headerActions}>
            <div className={styles.updateMenuWrap}>
              <Button
                variant="secondary"
                size="sm"
                isDisabled={busy}
                onPress={() => setUpdateMenuOpen((open) => !open)}
              >
                <CloudDownload
                  size={16}
                  className={updating ? styles.iconDownloading : undefined}
                />
                {updating ? t('settings.updating') : t('settings.updateServer')}
              </Button>
              {updateMenuOpen && (
                <div className={styles.updateMenu}>
                  <button
                    className={styles.updateMenuItem}
                    disabled={busy}
                    onClick={() => void updateServer()}
                  >
                    {t('settings.updateBranchAuto')}
                    <span className={styles.updateMenuHint}>
                      {t('settings.updateBranchAutoHint')}
                    </span>
                  </button>
                  <button
                    className={styles.updateMenuItem}
                    disabled={busy}
                    onClick={() => void updateServer('main')}
                  >
                    {t('settings.updateBranchMain')}
                    <span className={styles.updateMenuHint}>
                      {t('settings.updateBranchMainHint')}
                    </span>
                  </button>
                  <button
                    className={`${styles.updateMenuItem} ${styles.updateMenuBeta}`}
                    disabled={busy}
                    onClick={() => void updateServer('dev')}
                  >
                    {t('settings.updateBranchDev')}
                    <span className={styles.updateMenuHint}>
                      {t('settings.updateBranchDevHint')}
                    </span>
                  </button>
                </div>
              )}
            </div>
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
            aria-label="QR"
            onClick={() => setKeysQrUrl(null)}
          >
            {keysQrData ? <img src={keysQrData} alt="QR" /> : null}
          </div>
        )}

        {connected && (
          <>
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
            </section>

            <section className={styles.listCard}>
              <h2 className={styles.sectionTitle}>{t('settings.listTitle')}</h2>
              {profiles!.length > 0 && !expireSupported && (
                <p className={styles.serverTooOld}>{t('settings.serverTooOld')}</p>
              )}
              {profiles!.length === 0 && <div className={styles.empty}>{t('settings.empty')}</div>}
              {profiles!.map((profile) => (
                <Fragment key={profile.name}>
                <div className={styles.profileCard}>
                  <div className={styles.profileMain}>
                    <div className={styles.profileNameRow}>
                      <span className={styles.profileName}>{profile.name}</span>
                      {profile.multi_route && <Chip size="sm" color="accent">{t('settings.happ')}</Chip>}
                      {profile.pq_enabled && <Chip size="sm" color="default">PQ</Chip>}
                    </div>
                    <div className={styles.profileMeta}>
                      <Chip size="sm" color="default">{transportLabel(profile)}</Chip>
                      <Chip size="sm" color="default">:{profile.port}</Chip>
                      <span className={styles.profileSni}>{profile.sni}</span>
                      {expireChip(profile)}
                    </div>
                    {profile.subscription_url && (
                      <div className={styles.profileUrl} title={profile.subscription_url}>
                        <span className={styles.profileUrlText}>{profile.subscription_url}</span>
                      </div>
                    )}
                  </div>
                  <div className={styles.profileActions}>
                    <Button
                      size="sm"
                      variant="secondary"
                      isDisabled={busy}
                      onPress={() => {
                        setSniTarget(profile)
                        setSniValue(profile.sni ?? '')
                        setSniRoute(1)
                        setSniList(null)
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
                      }}
                    >
                      <EthernetPort size={14} />
                      {t('settings.portBtn')}
                    </Button>
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
                      onPress={() => openExpire(profile)}
                    >
                      <CalendarClock size={14} />
                      {t('settings.expireBtn')}
                    </Button>
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
                    {profile.multi_route ? (
                      <span className={styles.protectedProfile} title={t('settings.mainProfileHint')}>
                        <Lock size={13} />
                        {t('settings.mainProfile')}
                      </span>
                    ) : (
                      <Button
                        size="sm"
                        variant="danger-soft"
                        isDisabled={busy}
                        onPress={() => setConfirmRemove(profile)}
                      >
                        <Trash2 size={14} />
                        {t('settings.deleteKey')}
                      </Button>
                    )}
                  </div>
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
                            className={`${styles.backendState} ${
                              hyst?.state === 'active' ? styles.backendStateOk : ''
                            }`}
                          >
                            {hyst?.state === 'active'
                              ? hyst.sni
                                ? `${t('settings.backendsActive')} · SNI ${hyst.sni}`
                                : `${t('settings.backendsActive')} · UDP ${hyst.port ?? '—'}`
                              : t('settings.backendsNotInstalled')}
                          </div>
                        </div>
                      </div>
                      <div className={styles.backendActions}>
                        <Button
                          size="sm"
                          variant="secondary"
                          isDisabled={busy || hyst?.state !== 'active'}
                          onPress={() => void qrProfileHyst(profile)}
                        >
                          {t('keys.qr')}
                        </Button>
                        <Button
                          size="sm"
                          variant="secondary"
                          isDisabled={busy}
                          onPress={() => openExpire(profile)}
                        >
                          <CalendarClock size={14} />
                          {t('settings.backendsExpiryBtn')}
                        </Button>
                        <Button
                          size="sm"
                          variant="secondary"
                          isDisabled={busy || hyst?.state !== 'active'}
                          onPress={() => openRevoke(profile, true)}
                        >
                          <ShieldOff size={14} />
                          {t('settings.revokeBtn')}
                        </Button>
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
                            className={`${styles.backendState} ${
                              awgEntry?.state === 'active' ? styles.backendStateOk : ''
                            }`}
                          >
                            {awgEntry?.state === 'active'
                              ? `${t('settings.backendsActive')} · UDP ${awgEntry.port ?? '—'}`
                              : t('settings.backendsNotInstalled')}
                          </div>
                        </div>
                      </div>
                      <div className={styles.backendActions}>
                        <Button
                          size="sm"
                          variant="secondary"
                          isDisabled={busy || awgEntry?.state !== 'active'}
                          onPress={() => void qrProfileAwg(profile)}
                        >
                          {t('keys.qr')}
                        </Button>
                        <Button
                          size="sm"
                          variant="secondary"
                          isDisabled={busy || awgEntry?.state !== 'active'}
                          onPress={() => void qrProfileAwgVpn(profile)}
                        >
                          {t('keys.backendsQrVpn')}
                        </Button>
                        <Button
                          size="sm"
                          variant="secondary"
                          isDisabled={busy}
                          onPress={() => openExpire(profile)}
                        >
                          <CalendarClock size={14} />
                          {t('settings.backendsExpiryBtn')}
                        </Button>
                        <Button
                          size="sm"
                          variant="secondary"
                          isDisabled={busy || awgEntry?.state !== 'active'}
                          onPress={() => openRevoke(profile, true)}
                        >
                          <ShieldOff size={14} />
                          {t('settings.revokeBtn')}
                        </Button>
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
                </Fragment>
              ))}
            </section>

            <section>
              <div className={styles.listCard}>
                <h2 className={styles.sectionTitle}>
                  {t('settings.backendsTitle')}
                  <Chip size="sm" color="default">{t('settings.backendsDevBadge')}</Chip>
                </h2>
                <p className={styles.sectionHint}>{t('settings.backendsHint')}</p>
                <p className={styles.hint}>{t('settings.backendsDevNote')}</p>
                {backendsError !== null ? (
                  <p className={styles.hint}>{t('settings.backendsUnsupported')}</p>
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
                        <div
                          className={`${styles.backendState} ${
                            hyst?.state === 'active' ? styles.backendStateOk : ''
                          }`}
                        >
                          {hyst?.installed
                            ? `${t('settings.backendsActive')} · UDP ${hyst.port ?? '—'} · ${
                                hyst.version ?? ''
                              }`
                            : t('settings.backendsNotInstalled')}
                        </div>
                        <p className={styles.backendNote}>{t('settings.backendsHystNote')}</p>
                        <div className={styles.backendActions}>
                          {hyst?.installed ? (
                            <>
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
                        <div
                          className={`${styles.backendState} ${
                            awgEntry?.state === 'active' ? styles.backendStateOk : ''
                          }`}
                        >
                          {awgEntry?.installed
                            ? `${t('settings.backendsActive')} · UDP ${awgEntry.port ?? '—'} · ${
                                awgEntry.three_enabled
                                  ? t('settings.backends31On')
                                  : t('settings.backends31Off')
                              }`
                            : t('settings.backendsNotInstalled')}
                        </div>
                        <p className={styles.backendNote}>{t('settings.backendsAwgNote')}</p>
                        <div className={styles.backendActions}>
                          {awgEntry?.installed ? (
                            <>
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
                <AlertDialog.Heading>{t('settings.backendsConfirmTitle')}</AlertDialog.Heading>
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
                  {t('settings.done')}
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
                          <CalendarClock size={14} />
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
                        onPress={() => void navigator.clipboard.writeText(revokeUrl)}
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
