import { useEffect, useState } from 'react'
import QRCode from 'qrcode'
import { Button, Chip, Spinner } from '@heroui/react'
import { useTranslation } from 'react-i18next'
import type {
  Server,
  ServerProfile,
  SshAccessInput,
  VlessLink
} from '@shared/types'
import { vlessPort } from '@shared/vless'
import { buildAwgVpnUrl, parseAwgClientConf, stripAwgComments } from '@shared/awg'
import { shouldAutoConnectServer } from './server-access'
import styles from './ServerKeys.module.css'

interface ServerKeysProps {
  server: Server
  onBack: () => void
}

export function ServerKeys({ server, onBack }: ServerKeysProps): React.JSX.Element {
  const { t } = useTranslation()
  const [keys, setKeys] = useState<VlessLink[]>(server.keys ?? [])
  // Бэкенд-ключи инициализируются из карточки сервера — мгновенно, как vless.
  const [hysteria2Links, setHysteria2Links] = useState<string[]>(server.hysteria2Keys ?? [])
  const [awgConfs, setAwgConfs] = useState<Record<string, string>>(server.awgConfs ?? {})
  const [subscriptionUrl, setSubscriptionUrl] = useState(server.subscriptionUrl)
  const [toast, setToast] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)
  const [qrUrl, setQrUrl] = useState<string | null>(null)
  const [qrData, setQrData] = useState<string | null>(null)

  // Мультипротокольные бэкенды: hysteria2 приходит из подписки, AWG — по SSH.
  const [profiles, setProfiles] = useState<ServerProfile[]>([])
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
        const fresh = await window.api.servers.get(server.id)
        if (!cancelled && fresh?.awgConfs) setAwgConfs(fresh.awgConfs)
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
    const onEsc = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') closeQr()
    }
    document.addEventListener('keydown', onEsc)
    return () => document.removeEventListener('keydown', onEsc)
  }, [qrUrl])

  const copy = async (text: string): Promise<void> => {
    await navigator.clipboard.writeText(text)
    setToast(t('keys.copied'))
    setTimeout(() => setToast(null), 1500)
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

  const expiryLine = (profile: ServerProfile | undefined): React.JSX.Element | null =>
    profile ? (
      <p className={styles.keyNote}>
        {profile.expire_date
          ? t('keys.backendsExpiryDate', { date: profile.expire_date })
          : t('keys.backendsExpiryNone')}
      </p>
    ) : null

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

  return (
    <div className={styles.root}>
      <header className={styles.header}>
        <Button variant="secondary" size="sm" onPress={onBack}>
          {t('dashboard.back')}
        </Button>
        <h1 className={styles.title}>{server.name}</h1>
      </header>

      <p className={styles.hint}>{t('keys.hint')}</p>

      <div className={styles.content}>
        {loading && keys.length === 0 && (
          <div className={styles.loading}>
            <Spinner size="sm" />
          </div>
        )}
        {!loading && keys.length === 0 && <div className={styles.empty}>{t('keys.none')}</div>}

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
          const profile = profiles.find((p) => p.name === user)
          return (
            <div key={link} className={styles.keyCard}>
              <div className={styles.keyHeader}>
                <Chip size="sm" color="accent">
                  HYSTERIA2 · {user} · UDP :{hysteria2Port(link)}
                </Chip>
              </div>
              <p className={styles.keyNote}>{t('keys.backendsHystNote')}</p>
              {expiryLine(profile)}
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
              {expiryLine(profile)}
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
          aria-label="QR"
          onClick={closeQr}
        >
          {qrData ? <img src={qrData} alt="QR" /> : null}
        </div>
      )}
    </div>
  )
}
