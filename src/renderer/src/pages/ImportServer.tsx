import { useEffect, useRef, useState } from 'react'
import { Button, TextField, Label, Input, Spinner } from '@heroui/react'
import { CheckCircle2, Circle } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import type { ImportProgressEvent, ImportStep, Server, SshAccessInput } from '@shared/types'
import { SshAccessForm, isSshAccessReady } from '../components/SshAccessForm'
import styles from './ImportServer.module.css'

interface ImportServerProps {
  onDone: (server: Server) => void
  onBack: () => void
}

const STEP_ORDER: ImportStep[] = ['ssh', 'inspect', 'subscription', 'save']

interface FormState {
  host: string
  port: string
}

export function ImportServer({ onDone, onBack }: ImportServerProps): React.JSX.Element {
  const { t } = useTranslation()
  const [form, setForm] = useState<FormState>({ host: '', port: '22' })
  const [access, setAccess] = useState<SshAccessInput>({
    username: 'root',
    authMethod: 'password',
    password: '',
    privilegeMode: 'root'
  })
  const [running, setRunning] = useState(false)
  const [currentStep, setCurrentStep] = useState<ImportStep | null>(null)
  const [log, setLog] = useState<string[]>([])
  const [error, setError] = useState<string | null>(null)
  const logPanelRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const panel = logPanelRef.current
    if (panel) panel.scrollTop = panel.scrollHeight
  }, [log, error])

  // Main process отправляет переходы фаз и строки консоли только при реальном ходе работ.
  useEffect(() => {
    if (!running) return
    return window.api.servers.onImportEvent((event: ImportProgressEvent) => {
      if ('step' in event) setCurrentStep(event.step)
      else setLog((prev) => [...prev, event.log])
    })
  }, [running])

  const ready = form.host.trim().length > 0 && isSshAccessReady(access)

  const startImport = (): void => {
    setError(null)
    setLog([])
    setRunning(true)
    setCurrentStep(null)
    window.api.servers
      .import({
        host: form.host.trim(),
        port: Number(form.port) || 22,
        access
      })
      .then((result) => window.api.servers.get(result.serverId))
      .then((server) => {
        if (!server) throw new Error(t('import.notSaved'))
        onDone(server)
      })
      .catch((err: unknown) => {
        setError(err instanceof Error ? err.message : String(err))
        setRunning(false)
      })
  }

  return (
    <div className={styles.root}>
      <header className={styles.header}>
        <Button variant="secondary" size="sm" isDisabled={running} onPress={onBack}>
          {t('dashboard.back')}
        </Button>
        <h1 className={styles.title}>{t('import.title')}</h1>
      </header>

      <div className={styles.body}>
        <div className={styles.form}>
          <p className={styles.hint}>{t('import.hint')}</p>
          <TextField variant="secondary">
            <Label>{t('deploy.host')}</Label>
            <Input
              value={form.host}
              placeholder="185.23.xx.xx"
              disabled={running}
              onChange={(e) => setForm((f) => ({ ...f, host: e.target.value }))}
            />
          </TextField>
          <TextField variant="secondary">
            <Label>{t('deploy.port')}</Label>
            <Input
              value={form.port}
              placeholder="22"
              disabled={running}
              onChange={(e) => setForm((f) => ({ ...f, port: e.target.value }))}
            />
          </TextField>
          <SshAccessForm value={access} onChange={setAccess} disabled={running} />

          <Button
            className={styles.importBtn}
            variant="primary"
            size="lg"
            fullWidth
            isDisabled={running || !ready}
            onPress={startImport}
          >
            {running && <Spinner size="sm" />}
            {running ? t('import.running') : t('import.button')}
          </Button>

          {access.authMethod === 'privateKey' &&
            !access.privateKeyCredentialId &&
            !running && (
              <div className={styles.note}>{t('import.selectKeyNote')}</div>
            )}
          {error && (
            <div className={styles.error}>
              {t('deploy.error')}: {error}
            </div>
          )}
        </div>

        <div className={styles.status}>
          <div className={styles.statusTitle}>{t('import.progress')}</div>
          <ol className={styles.steps}>
            {STEP_ORDER.map((step) => {
              const currentIndex = currentStep ? STEP_ORDER.indexOf(currentStep) : -1
              const state =
                currentIndex > STEP_ORDER.indexOf(step)
                  ? 'done'
                  : currentStep === step
                    ? 'active'
                    : 'todo'
              return (
                <li key={step} className={`${styles.step} ${state === 'todo' ? '' : styles[state]}`}>
                  <div className={styles.stepRow}>
                    <span className={styles.stepIcon}>
                      {state === 'done' ? (
                        <CheckCircle2 size={20} className={styles.stepCheck} />
                      ) : state === 'active' ? (
                        <span className={styles.stepDot} />
                      ) : (
                        <Circle size={16} className={styles.stepTodo} />
                      )}
                    </span>
                    <span>{t(`import.steps.${step}`)}</span>
                  </div>
                </li>
              )
            })}
          </ol>

          <div className={styles.logTitle}>{t('deploy.log')}</div>
          <div className={styles.logPanel} ref={logPanelRef}>
            {log.length === 0 && !error && (
              <div className={styles.logLine}>{t('deploy.waiting')}</div>
            )}
            {log.map((line, i) => (
              <div key={i} className={styles.logLine}>
                &gt; {line}
              </div>
            ))}
            {error && <div className={styles.logError}>&gt; {error}</div>}
          </div>
        </div>
      </div>
    </div>
  )
}
