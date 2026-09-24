import { useEffect, useState } from 'react'
import {
  Button,
  AlertDialog,
  Dropdown,
  DropdownItem
} from '@heroui/react'
import {
  Settings2,
  Trash2,
  TriangleAlert,
  KeyRound,
  ChevronDown,
  Check,
  Rocket,
  Link2,
  Lock,
  MapPin,
  MonitorCog,
  Route,
  User,
  EllipsisVertical
} from 'lucide-react'
import { useTranslation } from 'react-i18next'
import { setLanguage, supportedLngs, type SupportedLng } from '../i18n'
import type { Server } from '@shared/types'
import { CountryFlag } from '../components/CountryFlag'
import { accessSummary, type AccessSecretState } from './server-access'
import styles from './Dashboard.module.css'

const LANG_LABELS: Record<SupportedLng, string> = {
  ru: 'RU',
  en: 'EN',
  zh: '中文'
}

// Где лежит секрет доступа — ключ i18n; предупреждающий тон для не-персистентных случаев.
const SECRET_I18N: Record<AccessSecretState, string> = {
  passwordSaved: 'dashboard.secretPasswordSaved',
  keySaved: 'dashboard.secretKeySaved',
  sessionOnly: 'dashboard.secretSessionOnly',
  notSaved: 'dashboard.secretNotSaved'
}
const SECRET_WARN: Record<AccessSecretState, boolean> = {
  passwordSaved: false,
  keySaved: false,
  sessionOnly: true,
  notSaved: true
}

interface DashboardProps {
  servers: Server[]
  onAdd: () => void
  onImport: () => void
  onOpen: (server: Server) => void
  onSettings: (server: Server) => void
  onEditAccess: (server: Server) => void
  onRemove: (id: string) => void
}

export function Dashboard({
  servers,
  onAdd,
  onImport,
  onOpen,
  onSettings,
  onEditAccess,
  onRemove
}: DashboardProps): React.JSX.Element {
  const { t, i18n } = useTranslation()
  const [pendingRemove, setPendingRemove] = useState<Server | null>(null)
  const [online, setOnline] = useState<Record<string, boolean>>({})

  useEffect(() => {
    const result: Record<string, boolean> = {}
    const checks = servers.map((server) =>
      window.api.servers.check(server.id).then((ok) => {
        result[server.id] = ok
      })
    )
    Promise.all(checks).then(() => setOnline(result))
    return () => {
      setOnline({})
    }
  }, [servers])

  const confirmRemove = (): void => {
    if (!pendingRemove) return
    onRemove(pendingRemove.id)
    setPendingRemove(null)
  }

  return (
    <div className={styles.root}>
      <header className={styles.header}>
        <h1 className={styles.title}>{t('dashboard.title')}</h1>
        <div className={styles.headerActions}>
          <Dropdown>
            <Dropdown.Trigger
              className={styles.langSelect}
              aria-label={t('settings.language')}
            >
              <span className={styles.langSelectValue}>
                {LANG_LABELS[i18n.language as SupportedLng] ?? 'RU'}
              </span>
              <ChevronDown size={14} className={styles.langSelectChevron} />
            </Dropdown.Trigger>
            <Dropdown.Popover placement="bottom end" className={styles.langPopup}>
              <Dropdown.Menu>
                {supportedLngs.map((lng) => (
                  <DropdownItem
                    key={lng}
                    className={styles.langItem}
                    onAction={() => {
                      setLanguage(lng as SupportedLng)
                    }}
                  >
                    <span className={styles.langItemLabel}>
                      {LANG_LABELS[lng as SupportedLng]}
                    </span>
                    {lng === i18n.language && (
                      <Check size={14} className={styles.langItemCheck} />
                    )}
                  </DropdownItem>
                ))}
              </Dropdown.Menu>
            </Dropdown.Popover>
          </Dropdown>
          {servers.length > 0 && (
            <Dropdown>
              <Dropdown.Trigger className={styles.langSelect} aria-label={t('dashboard.add')}>
                <span className={styles.langSelectValue}>{t('dashboard.add')}</span>
                <ChevronDown size={14} className={styles.langSelectChevron} />
              </Dropdown.Trigger>
              <Dropdown.Popover placement="bottom end" className={styles.langPopup}>
                <Dropdown.Menu>
                  <DropdownItem key="deploy" className={styles.langItem} onAction={onAdd}>
                    <Rocket size={14} />
                    <span className={styles.langItemLabel}>{t('dashboard.addDeploy')}</span>
                  </DropdownItem>
                  <DropdownItem key="import" className={styles.langItem} onAction={onImport}>
                    <Link2 size={14} />
                    <span className={styles.langItemLabel}>{t('dashboard.addImport')}</span>
                  </DropdownItem>
                </Dropdown.Menu>
              </Dropdown.Popover>
            </Dropdown>
          )}
        </div>
      </header>

      <div className={styles.list}>
        {servers.map((server) => {
          const summary = accessSummary(server)
          return (
            <div key={server.id} className={styles.card}>
              <div className={styles.cardHead}>
                <div className={styles.cardHeader}>
                  <span
                    className={`${styles.statusDot} ${
                      online[server.id] ? styles.statusDotOnline : styles.statusDotOffline
                    }`}
                  />
                  <div className={styles.cardInfo}>
                    <div className={styles.cardTitle}>
                      <CountryFlag flag={server.flag} className={styles.flag} />
                      {server.name}
                    </div>
                    <div className={styles.cardLocation}>
                      <MapPin size={13} className={styles.cardLocationIcon} />
                      {[server.country, server.city].filter(Boolean).join(' · ') || '—'}
                    </div>
                  </div>
                </div>
                <span
                  className={`${styles.setupBadge} ${
                    server.setupStatus === 'ready'
                      ? styles.setupBadgeReady
                      : server.setupStatus === 'partial'
                        ? styles.setupBadgePartial
                        : styles.setupBadgeDefault
                  }`}
                >
                  {t(`dashboard.setup.${server.setupStatus ?? 'unknown'}`)}
                </span>
              </div>

              <div className={styles.cardStats}>
                <div className={styles.statCard}>
                  <MonitorCog size={18} className={styles.statIcon} />
                  <div className={styles.statText}>
                    <span className={styles.statValue}>{server.os ?? '—'}</span>
                    <span className={styles.statLabel}>{t('dashboard.statOs')}</span>
                  </div>
                </div>
                <div className={styles.statCard}>
                  <Route size={18} className={styles.statIcon} />
                  <div className={styles.statText}>
                    <span className={styles.statValue}>{server.routesCount ?? 0}</span>
                    <span className={styles.statLabel}>{t('dashboard.statRoutes')}</span>
                  </div>
                </div>
                <div className={styles.statCard}>
                  <User size={18} className={styles.statIcon} />
                  <div className={styles.statText}>
                    <span className={styles.statValue}>{summary.endpoint}</span>
                    <span
                      className={`${styles.statLabel} ${
                        SECRET_WARN[summary.secret] ? styles.accessSecretWarn : ''
                      }`}
                    >
                      <Lock size={11} className={styles.accessSecretIcon} />
                      {t(SECRET_I18N[summary.secret])}
                    </span>
                  </div>
                  <Dropdown>
                    <Dropdown.Trigger
                      className={styles.statMenuBtn}
                      aria-label={t('dashboard.changeAccess')}
                    >
                      <EllipsisVertical size={16} />
                    </Dropdown.Trigger>
                    <Dropdown.Popover placement="bottom end" className={styles.langPopup}>
                      <Dropdown.Menu>
                        <DropdownItem
                          key="access"
                          className={styles.langItem}
                          onAction={() => onEditAccess(server)}
                        >
                          <Lock size={14} />
                          <span className={styles.langItemLabel}>
                            {t('dashboard.changeAccess')}
                          </span>
                        </DropdownItem>
                      </Dropdown.Menu>
                    </Dropdown.Popover>
                  </Dropdown>
                </div>
              </div>

              <div className={styles.cardActions}>
                <Button size="sm" variant="secondary" onPress={() => onOpen(server)}>
                  <KeyRound size={16} />
                  {t('dashboard.keys')}
                </Button>
                <Button size="sm" variant="secondary" onPress={() => onSettings(server)}>
                  <Settings2 size={16} />
                  {t('dashboard.settings')}
                </Button>
                <Button
                  size="sm"
                  variant="danger-soft"
                  onPress={() => setPendingRemove(server)}
                >
                  <Trash2 size={16} />
                  {t('dashboard.delete')}
                </Button>
              </div>
            </div>
          )
        })}

        {servers.length === 0 && (
          <div className={styles.onboardingGrid}>
            <button type="button" className={styles.onboardingCard} onClick={onAdd}>
              <span className={styles.onboardingIcon}>
                <Rocket size={26} />
              </span>
              <span className={styles.onboardingBody}>
                <strong>{t('dashboard.onboardDeployTitle')}</strong>
                <small>{t('dashboard.onboardDeployHint')}</small>
              </span>
            </button>
            <button
              type="button"
              className={`${styles.onboardingCard} ${styles.onboardingCardSecondary}`}
              onClick={onImport}
            >
              <span className={styles.onboardingIcon}>
                <Link2 size={26} />
              </span>
              <span className={styles.onboardingBody}>
                <strong>{t('dashboard.onboardImportTitle')}</strong>
                <small>{t('dashboard.onboardImportHint')}</small>
              </span>
            </button>
          </div>
        )}
      </div>

      <AlertDialog.Root
        isOpen={pendingRemove !== null}
        onOpenChange={(open) => {
          if (!open) setPendingRemove(null)
        }}
      >
        <AlertDialog.Backdrop>
          <AlertDialog.Container>
            <AlertDialog.Dialog className={styles.confirmDialog}>
              <AlertDialog.Header>
                <AlertDialog.Icon status="danger">
                  <TriangleAlert size={20} />
                </AlertDialog.Icon>
                <AlertDialog.Heading>
                  {t('dashboard.confirmDeleteTitle')}
                </AlertDialog.Heading>
              </AlertDialog.Header>
              <AlertDialog.Body>
                {t('dashboard.confirmDeleteBody', {
                  name: pendingRemove?.name ?? ''
                })}
              </AlertDialog.Body>
              <AlertDialog.Footer>
                <Button variant="secondary" onPress={() => setPendingRemove(null)}>
                  {t('dashboard.cancel')}
                </Button>
                <Button variant="danger" onPress={confirmRemove}>
                  {t('dashboard.delete')}
                </Button>
              </AlertDialog.Footer>
            </AlertDialog.Dialog>
          </AlertDialog.Container>
        </AlertDialog.Backdrop>
      </AlertDialog.Root>
    </div>
  )
}
