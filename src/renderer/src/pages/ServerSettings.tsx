import { useMemo, useState } from 'react'
import { Button, TextField, Label, Input, Chip, Spinner, AlertDialog } from '@heroui/react'
import {
  Settings2,
  Play,
  Trash2,
  Power,
  Lock,
  CloudDownload,
  CloudOff,
  Fingerprint,
  Globe2,
  EthernetPort,
  Copy,
  Download,
  Check
} from 'lucide-react'
import { useTranslation } from 'react-i18next'
import type { Server, ServerProfile, SniEntry, SshAccessInput } from '@shared/types'
import { isSshAccessReady, SshAccessForm } from '../components/SshAccessForm'
import styles from './ServerSettings.module.css'

interface ServerSettingsProps {
  server: Server
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

export function ServerSettings({ server, onBack }: ServerSettingsProps): React.JSX.Element {
  const { t } = useTranslation()
  const [access, setAccess] = useState<SshAccessInput>({
    username: server.username || 'root',
    authMethod: server.authMethod ?? 'password',
    password: '',
    privateKeyPath: server.privateKeyPath ?? undefined,
    passphrase: '',
    privilegeMode: server.privilegeMode ?? 'root',
    sudoPassword: ''
  })
  const [busy, setBusy] = useState(false)
  const [profiles, setProfiles] = useState<ServerProfile[] | null>(null)
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

  const [updating, setUpdating] = useState(false)
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
      const result = await window.api.profiles.list(server.id, access)
      setProfiles(result.profiles ?? [])
      void window.api.servers
        .get(server.id)
        .then((refreshed) => setHostKeyFingerprint(refreshed?.hostKeyFingerprint ?? null))
        .catch(() => {})
    } catch (err) {
      setProfiles(null)
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
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
        count: Math.min(Math.max(Number(count) || 1, 1), 50)
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

  const updateServer = async (): Promise<void> => {
    if (!accessReady) return
    setBusy(true)
    setUpdating(true)
    setError(null)
    try {
      const result = await window.api.server.update(server.id, access)
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

  const transportLabel = (profile: ServerProfile): string =>
    profile.multi_route ? `${profile.transport} · ${profile.routes} ${t('settings.routes')}` : profile.transport

  const reset = (): void => {
    setProfiles(null)
    setError(null)
    setAccess((current) => ({
      ...current,
      password: '',
      passphrase: '',
      sudoPassword: ''
    }))
  }

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
            <Button
              variant="secondary"
              size="sm"
              isDisabled={busy}
              onPress={updateServer}
            >
              <CloudDownload
                size={16}
                className={updating ? styles.iconDownloading : undefined}
              />
              {updating ? t('settings.updating') : t('settings.updateServer')}
            </Button>
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
            {!connected ? (
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
            ) : (
              <Button variant="secondary" size="lg" isDisabled={busy} onPress={reset}>
                <Power size={16} />
                {t('settings.changePassword')}
              </Button>
            )}
          </div>
          <p className={styles.passwordNote}>{t('settings.passwordNote')}</p>
        </section>

        {error && <div className={styles.error}>{t('settings.error')}: {error}</div>}
        {toast && <div className={styles.toast}>{toast}</div>}

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
                  variant="primary"
                  size="lg"
                  className={styles.createBtn}
                  isDisabled={busy || !accessReady || !name.trim()}
                  onPress={create}
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
                    const active = transport === proto.id
                    return (
                      <button
                        key={proto.id}
                        type="button"
                        className={`${styles.transportCard} ${
                          active ? styles.transportCardActive : ''
                        }`}
                        disabled={busy}
                        onClick={() => setTransport(proto.id)}
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
            </section>

            <section className={styles.listCard}>
              <h2 className={styles.sectionTitle}>{t('settings.listTitle')}</h2>
              {profiles!.length === 0 && <div className={styles.empty}>{t('settings.empty')}</div>}
              {profiles!.map((profile) => (
                <div key={profile.name} className={styles.profileCard}>
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
              ))}
            </section>
          </>
        )}
      </div>

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
                      <div className={styles.bypassLoadRow}>
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
                  <TextField variant="secondary" className={styles.bypassDomainField}>
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
                  <TextField variant="secondary" className={styles.bypassDomainField}>
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
