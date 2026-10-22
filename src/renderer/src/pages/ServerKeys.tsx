import { useEffect, useRef, useState } from 'react'
import QRCode from 'qrcode'
import { Button, Chip, Spinner } from '@heroui/react'
import { Braces, Settings2 } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import type {
  ProfileExpiryCache,
  Server,
  ServerProfile,
  SshAccessInput,
  SubscriptionFormats,
  VlessLink
} from '@shared/types'
import { vlessPort } from '@shared/vless'
import { buildAwgVpnUrl, parseAwgClientConf, stripAwgComments } from '@shared/awg'
import { copyText } from '../lib/clipboard'
import { shouldAutoConnectServer } from './server-access'
import styles from './ServerKeys.module.css'

/** Форматы одной подписки: порядок фиксирован — Clash сверху, sing-box снизу. */
const FORMAT_KINDS = ['clash', 'singbox'] as const

/**
 * Ссылки Clash/mihomo и sing-box — необязательный вид, а не часть основного
 * набора: по умолчанию страница отдаёт те же ключи, что и раньше (подписка
 * HAPP/v2ray + VLESS-ссылки). Иначе на каждый профиль печатались три почти
 * одинаковых URL, и «ключ» выглядел задвоенным. Выбор запоминается, потому что
 * он про клиент оператора, а не про конкретный сервер.
 */
const FORMATS_STORAGE_KEY = 'xrayebator-keys-formats'

/**
 * Выбор форматов живёт в localStorage, но его может не быть (SSR в тестах,
 * приватный режим, выключенное хранилище) — тогда вид по умолчанию, без падения.
 */
function readFormatsPref(): boolean {
  if (typeof window === 'undefined') return false
  try {
    return window.localStorage.getItem(FORMATS_STORAGE_KEY) === '1'
  } catch {
    return false
  }
}

function writeFormatsPref(value: boolean): void {
  try {
    window.localStorage.setItem(FORMATS_STORAGE_KEY, value ? '1' : '0')
  } catch {
    // Хранилище недоступно — вид просто не запомнится до следующего открытия.
  }
}

interface ServerKeysProps {
  server: Server
  onBack: () => void
  /** Переход в настройки сервера из пустого состояния (там создаются профили). */
  onSettings?: () => void
}

export function ServerKeys({ server, onBack, onSettings }: ServerKeysProps): React.JSX.Element {
  const { t } = useTranslation()
  const [keys, setKeys] = useState<VlessLink[]>(server.keys ?? [])
  // Бэкенд-ключи инициализируются из карточки сервера — мгновенно, как vless.
  const [hysteria2Links, setHysteria2Links] = useState<string[]>(server.hysteria2Keys ?? [])
  const [awgConfs, setAwgConfs] = useState<Record<string, string>>(server.awgConfs ?? {})
  // Ссылки форматов клиентов лежат в карточке сервера — как остальные ключи:
  // категория рисуется сразу из кэша, а не после ответа SSH.
  const [formats, setFormats] = useState<Record<string, SubscriptionFormats>>(
    server.subscriptionFormats ?? {}
  )
  const [subscriptionUrl, setSubscriptionUrl] = useState(server.subscriptionUrl)
  // Дополнительный вид ключей (Clash/mihomo, sing-box) — выключен по умолчанию.
  const [showFormats, setShowFormats] = useState<boolean>(readFormatsPref)
  const [toast, setToast] = useState<string | null>(null)
  const qrModalRef = useRef<HTMLDivElement>(null)
  const [loading, setLoading] = useState(false)
  const [qrUrl, setQrUrl] = useState<string | null>(null)
  const [qrData, setQrData] = useState<string | null>(null)

  // Мультипротокольные бэкенды: hysteria2 приходит из подписки, AWG — по SSH.
  const [profiles, setProfiles] = useState<ServerProfile[]>([])
  // Сроки профилей: кэш из карточки сервера — подпись рисуется мгновенно, как и
  // остальные ключи. Без него абзац «Действует до …» появлялся только после ответа
  // SSH и карточка дёргалась, дорастая на строку (жалоба 2026-10-20).
  const [expiryCache, setExpiryCache] = useState<Record<string, ProfileExpiryCache>>(
    server.profileExpiry ?? {}
  )
  const [beBusy, setBeBusy] = useState(false)

  // Доступ из сохранённой карточки сервера (секрет — в keychain).
  const storedAccess: SshAccessInput = {
    username: server.username,
    authMethod: server.authMethod ?? 'password',
    passwordCredentialId: server.passwordCredentialId ?? undefined,
    passwordPersisted: server.passwordPersisted ?? false,
    privateKeyCredentialId: server.privateKeyCredentialId ?? undefined,
    privateKeyPersisted: server.privateKeyPersisted ?? false,
    privilegeMode: server.privilegeMode ?? 'root'
  }

  useEffect(() => {
    let cancelled = false
    // 1) МГНОВЕННАЯ отрисовка из персистентного стора: пропса server может быть
    // устаревшим снимком Dashboard'а (без hysteria2Keys/awgConfs) — поэтому
    // перечитываем свежую запись напрямую.
    window.api.servers
      .get(server.id)
      .then((fresh) => {
        if (cancelled || !fresh) return
        setKeys(fresh.keys ?? [])
        setHysteria2Links(fresh.hysteria2Keys ?? [])
        setAwgConfs(fresh.awgConfs ?? {})
        setFormats(fresh.subscriptionFormats ?? {})
        setSubscriptionUrl(fresh.subscriptionUrl)
      })
      .catch(() => {
        // стора нет — остаёмся на пропсе
      })

    // 2) Фоновое обновление: подписка + бэкенды, ВСЁ параллельно одним Promise.all
    //    (равный тайминг с vless; без каскада и разнобоя).
    const beReady = shouldAutoConnectServer(server)
    setLoading(true)
    if (beReady) setBeBusy(true)
    const subscriptionP = server.subscriptionUrl
      ? window.api.subscription
          .fetch(server.id)
          .then((result) => {
            if (cancelled) return
            setKeys(result.keys)
            setHysteria2Links(result.hysteria2Links ?? [])
            setSubscriptionUrl(result.subscriptionUrl)
          })
          .catch(() => {
            if (!cancelled) setKeys(server.keys ?? [])
          })
      : Promise.resolve()

    const backendP = (async (): Promise<void> => {
      if (!beReady) return
      try {
        const [pl] = await Promise.all([
          window.api.profiles.list(server.id, storedAccess)
        ])
        if (cancelled) return
        const list = pl.profiles ?? []
        setProfiles(list)
        // Сроки обновились — переносим в кэш полным набором (удалённый профиль
        // исчезает, продлённый получает новую дату). main-процесс пишет то же
        // самое в карточку сервера, так что следующее открытие страницы покажет
        // уже новые сроки, а не старые.
        setExpiryCache(() => {
          const next: Record<string, ProfileExpiryCache> = {}
          for (const p of list) {
            next[p.name] = {
              expire: p.expire,
              expire_date: p.expire_date,
              expire_disabled: p.expire_disabled
            }
          }
          return next
        })
        // Конфы granted-профилей — параллельно; кэш в сторе делает повторные
        // открытия мгновенными. backends.status здесь не нужен — он тормозит.
        const targets = list.filter((p) => p.backends?.awg)
        const confEntries = await Promise.all(
          targets.map(async (p) => {
            const conf = await window.api.backends
              .awgConf(server.id, storedAccess, p.name)
              .catch(() => null)
            return [p.name, conf?.ok ? (conf.conf ?? '') : ''] as const
          })
        )
        if (cancelled) return
        setAwgConfs((current) => {
          const merged: Record<string, string> = { ...current }
          for (const [name, conf] of confEntries) {
            // Неудачный refetch НЕ стирает сохранённый конфиг (last known good).
            if (conf) merged[name] = conf
          }
          return merged
        })
        // Финальная синхронизация со стором: состояние == персистентные данные.
        // Ссылки форматов пишет main-процесс (profiles:list) — берём их оттуда,
        // чтобы кэш и экран не расходились.
        const fresh = await window.api.servers.get(server.id)
        if (!cancelled && fresh?.awgConfs) setAwgConfs(fresh.awgConfs)
        if (!cancelled && fresh?.subscriptionFormats) setFormats(fresh.subscriptionFormats)
        // Сроки — из стора: там же, где их только что записал main-процесс.
        if (!cancelled && fresh?.profileExpiry) setExpiryCache(fresh.profileExpiry)
      } catch {
        if (!cancelled) setProfiles([])
      }
    })()

    void Promise.all([subscriptionP, backendP]).finally(() => {
      if (!cancelled) {
        setLoading(false)
        setBeBusy(false)
      }
    })

    return () => {
      cancelled = true
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [server.id])

  useEffect(() => {
    if (!qrUrl) return
    // Оверлей забирает фокус сам: иначе Esc и Tab остаются в интерфейсе под ним.
    qrModalRef.current?.focus()
    const onEsc = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') closeQr()
    }
    document.addEventListener('keydown', onEsc)
    return () => document.removeEventListener('keydown', onEsc)
  }, [qrUrl])

  const copy = async (text: string): Promise<void> => {
    // Буфер обмена может отказать (нет разрешения/API): без проверки пользователь
    // видел «Скопировано!» и уносил пустой буфер.
    const ok = await copyText(text)
    setToast(ok ? t('keys.copied') : t('keys.copyFailed'))
    setTimeout(() => setToast(null), ok ? 1500 : 2600)
  }

  const closeQr = (): void => {
    setQrUrl(null)
    setQrData(null)
  }

  const showQr = async (url: string): Promise<void> => {
    setQrUrl(url)
    setQrData(null)
    const dataUrl = await QRCode.toDataURL(url, { width: 320, margin: 2 })
    setQrData(dataUrl)
  }

  /** QR для импорта в AmneziaWG-клиент: без комментариев-шапки. */
  const awgQrPayload = (conf: string): string => stripAwgComments(conf)

  const hystUserFromLink = (link: string): string => {
    const user = link.match(/^hysteria2:\/\/([^:]+):/)?.[1] ?? ''
    try {
      return decodeURIComponent(user)
    } catch {
      return user
    }
  }

  // Срок профиля по имени: свежий список профилей главнее кэша (срок могли
  // продлить или снять с другой вкладки), кэш закрывает окно до ответа SSH.
  // Если ни там, ни там записи нет — строку не рисуем вовсе: пустая подпись
  // «Бессрочно» на чужой профиль была бы враньём.
  const expiryFor = (name: string): { expire_date?: string } | undefined => {
    const fresh = profiles.find((p) => p.name === name)
    if (fresh) return fresh
    const cached = expiryCache[name]
    return cached ? { expire_date: cached.expire_date } : undefined
  }

  const expiryLine = (name: string): React.JSX.Element | null => {
    const profile = expiryFor(name)
    return profile ? (
      <p className={styles.keyNote}>
        {profile.expire_date
          ? t('keys.backendsExpiryDate', { date: profile.expire_date })
          : t('keys.backendsExpiryNone')}
      </p>
    ) : null
  }

  const hysteria2Port = (link: string): string => {
    const m = link.match(/@[^/:]+:(\d+)/)
    return m ? m[1] : ''
  }

  // Карточки AWG: из стора (мгновенно, до ответа SSH) + granted-профили, у
  // которых конфига ещё нет (для них — спиннер внутри карточки).
  const awgNames = [
    ...new Set([
      ...Object.keys(awgConfs),
      ...profiles.filter((p) => p.backends?.awg).map((p) => p.name)
    ])
  ]

  // Профили, для которых сервер отдал ссылки форматов.
  const formatNames = Object.keys(formats)

  const toggleFormats = (): void => {
    setShowFormats((prev) => {
      const next = !prev
      writeFormatsPref(next)
      return next
    })
  }

  return (
    <div className={styles.root}>
      <header className={styles.header}>
        <Button variant="secondary" size="sm" onPress={onBack}>
          {t('dashboard.back')}
        </Button>
        <h1 className={styles.title}>{server.name}</h1>
        {formatNames.length > 0 && (
          <span className={styles.formatsToggleWrap} title={t('keys.formatsToggleHint')}>
            <Button
              className={styles.formatsToggle}
              variant="secondary"
              size="sm"
              aria-pressed={showFormats}
              onPress={toggleFormats}
            >
              <Braces size={14} />
              {t('keys.formatsToggle')}
            </Button>
          </span>
        )}
      </header>

      <p className={styles.hint}>{t('keys.hint')}</p>

      <div className={styles.content}>
        {loading && keys.length === 0 && (
          <div className={styles.loading}>
            <Spinner size="sm" />
          </div>
        )}
        {!loading && keys.length === 0 && (
          <div className={styles.empty}>
            {/* Пустое состояние без выхода: единственный путь к ключам — создать
                профиль в настройках, поэтому ведём туда прямо отсюда. */}
            <span>{t('keys.none')}</span>
            {onSettings && (
              <Button size="sm" variant="secondary" onPress={onSettings}>
                <Settings2 size={14} />
                {t('keys.gotoProfiles')}
              </Button>
            )}
          </div>
        )}

        {keys.map((key) => (
          <div key={key.url} className={styles.keyCard}>
            <div className={styles.keyHeader}>
              <Chip size="sm" color="accent">
                {key.transport.toUpperCase()} :{vlessPort(key.url)}
              </Chip>
            </div>
            <div className={styles.keyUrl} title={key.url}>
              {key.url}
            </div>
            <div className={styles.keyActions}>
              <Button size="sm" variant="secondary" onPress={() => copy(key.url)}>
                {t('keys.copy')}
              </Button>
              <Button size="sm" variant="secondary" onPress={() => showQr(key.url)}>
                {t('keys.qr')}
              </Button>
            </div>
          </div>
        ))}

        {hysteria2Links.map((link) => {
          const user = hystUserFromLink(link)
          return (
            <div key={link} className={styles.keyCard}>
              <div className={styles.keyHeader}>
                <Chip size="sm" color="accent">
                  HYSTERIA2 · {user} · UDP :{hysteria2Port(link)}
                </Chip>
              </div>
              <p className={styles.keyNote}>{t('keys.backendsHystNote')}</p>
              {expiryLine(user)}
              <div className={styles.keyUrl} title={link}>
                {link}
              </div>
              <div className={styles.keyActions}>
                <Button size="sm" variant="secondary" onPress={() => copy(link)}>
                  {t('keys.copy')}
                </Button>
                <Button size="sm" variant="secondary" onPress={() => showQr(link)}>
                  {t('keys.qr')}
                </Button>
              </div>
            </div>
          )
        })}

        {awgNames.map((name) => {
          const conf = awgConfs[name]
          const fields = conf ? parseAwgClientConf(conf) : null
          const profile = profiles.find((p) => p.name === name)
          const granted = Boolean(profile?.backends?.awg) || Boolean(conf)
          return (
            <div key={name} className={styles.keyCard}>
              <div className={styles.keyHeader}>
                <Chip size="sm" color="default">
                  AMNEZIAWG 3.1 · {name}
                </Chip>
              </div>
              <p className={styles.keyNote}>{t('keys.backendsAwgNote')}</p>
              {expiryLine(name)}
              {fields ? (
                <>
                  <div className={styles.keysFields}>
                    <div className={styles.keysField}>
                      <span className={styles.keysFieldLabel}>
                        {t('keys.backendsEndpoint')}
                      </span>
                      <span className={styles.keysFieldValue}>{fields.endpoint}</span>
                    </div>
                    <div className={styles.keysField}>
                      <span className={styles.keysFieldLabel}>
                        {t('keys.backendsAddress')}
                      </span>
                      <span className={styles.keysFieldValue}>{fields.address}</span>
                    </div>
                  </div>
                  <div className={styles.keyActions}>
                    <Button
                      size="sm"
                      variant="secondary"
                      onPress={() => copy(awgQrPayload(conf))}
                    >
                      {t('keys.copy')}
                    </Button>
                    <Button
                      size="sm"
                      variant="secondary"
                      onPress={() => showQr(awgQrPayload(conf))}
                    >
                      {t('keys.backendsQrAwg')}
                    </Button>
                    <Button
                      size="sm"
                      variant="secondary"
                      onPress={async () =>
                        showQr(
                          await buildAwgVpnUrl(conf, name, {
                            clientPubKey: profile?.backends?.awg?.client_public_key,
                          })
                        )
                      }
                    >
                      {t('keys.backendsQrVpn')}
                    </Button>
                  </div>
                </>
              ) : granted && beBusy ? (
                <Spinner size="sm" />
              ) : (
                <div className={styles.empty}>{t('keys.backendsNotReady')}</div>
              )}
            </div>
          )
        })}

        {showFormats && formatNames.length > 0 && (
          <div className={styles.keyCard}>
            <div className={styles.keyHeader}>
              <Chip size="sm" color="default">
                {t('keys.formatsTitle')}
              </Chip>
            </div>
            <p className={styles.keyNote}>{t('keys.formatsNote')}</p>
            {formatNames.map((name) => (
              <div key={name} className={styles.formatProfile}>
                <div className={styles.formatProfileName}>{name}</div>
                {FORMAT_KINDS.map((kind) => {
                  const url = formats[name]?.[kind]
                  if (!url) return null
                  return (
                    <div key={kind} className={styles.formatItem}>
                      <div className={styles.formatItemHead}>
                        <span className={styles.formatLabel}>
                          {t(kind === 'clash' ? 'keys.formatClash' : 'keys.formatSingbox')}
                        </span>
                        <div className={styles.formatActions}>
                          <Button size="sm" variant="secondary" onPress={() => copy(url)}>
                            {t('keys.copy')}
                          </Button>
                          <Button size="sm" variant="secondary" onPress={() => showQr(url)}>
                            {t('keys.qr')}
                          </Button>
                        </div>
                      </div>
                      <div className={styles.keyUrl} title={url}>
                        {url}
                      </div>
                    </div>
                  )
                })}
              </div>
            ))}
          </div>
        )}

        {subscriptionUrl && (
          <div className={styles.keyCard}>
            <div className={styles.keyHeader}>
              <Chip size="sm" color="default">
                {t('keys.subscription')}
              </Chip>
            </div>
            <div className={styles.keyUrl} title={subscriptionUrl}>
              {subscriptionUrl}
            </div>
            <div className={styles.keyActions}>
              <Button size="sm" variant="secondary" onPress={() => copy(subscriptionUrl)}>
                {t('keys.copy')}
              </Button>
            </div>
          </div>
        )}

        {keys.length > 0 && (
          <Button
            className={styles.copyAllBtn}
            variant="primary"
            size="lg"
            onPress={() =>
              copy(
                keys.map((k) => k.url).join('\n') +
                  '\n' +
                  hysteria2Links.join('\n') +
                  '\n' +
                  subscriptionUrl
              )
            }
          >
            {t('keys.copy_all')}
          </Button>
        )}
      </div>

      {toast && <div className={styles.toast}>{toast}</div>}

      {qrUrl && (
        <div
          className={styles.qrModal}
          role="dialog"
          aria-modal="true"
          aria-label={t('keys.qr')}
          tabIndex={-1}
          ref={qrModalRef}
          onClick={closeQr}
        >
          {qrData ? <img src={qrData} alt={t('keys.qr')} /> : null}
        </div>
      )}
    </div>
  )
}
