import { useEffect, useState } from 'react'
import { Button, Chip, AlertDialog, Dropdown, DropdownItem } from '@heroui/react'
import {
  Settings2,
  Trash2,
  TriangleAlert,
  KeyRound,
  ChevronDown,
  Check
} from 'lucide-react'
import { useTranslation } from 'react-i18next'
import { setLanguage, supportedLngs, type SupportedLng } from '../i18n'
import type { Server } from '@shared/types'
import { CountryFlag } from '../components/CountryFlag'
import styles from './Dashboard.module.css'

const LANG_LABELS: Record<SupportedLng, string> = {
  ru: 'RU',
  en: 'EN',
  zh: '中文'
}

interface DashboardProps {
  servers: Server[]
  onAdd: () => void
  onOpen: (server: Server) => void
  onSettings: (server: Server) => void
  onRemove: (id: string) => void
}

export function Dashboard({
  servers,
  onAdd,
  onOpen,
  onSettings,
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
            <Button variant="primary" size="md" onPress={onAdd}>
              + {t('dashboard.add')}
            </Button>
          )}
        </div>
      </header>

      <div className={styles.list}>
        {servers.map((server) => (
          <div key={server.id} className={styles.card}>
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
                <div className={styles.cardMeta}>
                  <Chip size="sm" color="default">
                    {server.country || '—'}
                  </Chip>
                  {server.city && <span>{server.city}</span>}
                  <Chip size="sm" color="default">
                    {server.os ?? '—'}
                  </Chip>
                  <span>
                    {t('dashboard.routes', { count: server.routesCount ?? 0 })}
                  </span>
                </div>
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
        ))}

        {servers.length === 0 && (
          <Button
            className={styles.emptyCard}
            variant="ghost"
            size="lg"
            onPress={onAdd}
          >
            <span className={styles.emptyPlus}>+</span>
            <span className={styles.emptyText}>{t('dashboard.empty')}</span>
          </Button>
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
