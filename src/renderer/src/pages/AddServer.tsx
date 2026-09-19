import { useEffect, useRef, useState } from 'react'
import { Button, TextField, Label, Input, Spinner } from '@heroui/react'
import { CheckCircle2, Circle } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import type { DeployEvent, DeployStep, Server, SshAccessInput } from '@shared/types'
import { isSshAccessReady, SshAccessForm } from '../components/SshAccessForm'
import styles from './AddServer.module.css'

interface AddServerProps {
  onDone: (server: Server) => void
  onBack: () => void
}

const STEP_ORDER: DeployStep[] = [
  'ssh',
  'os_check',
  'upload',
  'install',
  'binary',
  'quickstart',
  'save'
]

interface FormState {
  host: string
  port: string
  email: string
}

export function AddServer({ onDone, onBack }: AddServerProps): React.JSX.Element {
  const { t } = useTranslation()
  const [form, setForm] = useState<FormState>({
    host: '',
    port: '22',
    email: ''
  })
  const [access, setAccess] = useState<SshAccessInput>({
    username: 'root',
    authMethod: 'password',
    password: '',
    privilegeMode: 'root'
  })
  const [deploying, setDeploying] = useState(false)
  const [currentStep, setCurrentStep] = useState<DeployStep | null>(null)
  const [completedSteps, setCompletedSteps] = useState<Set<DeployStep>>(new Set())
  const [stepLabels, setStepLabels] = useState<Partial<Record<DeployStep, string>>>({})
  const [log, setLog] = useState<string[]>([])
  const [error, setError] = useState<string | null>(null)
  const currentStepRef = useRef<DeployStep | null>(null)
  const logPanelRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const panel = logPanelRef.current
    if (panel) panel.scrollTop = panel.scrollHeight
  }, [log, error])

  useEffect(() => {
    if (!deploying) return
    const unsubscribe = window.api.deploy.onEvent((event: DeployEvent) => {
      if (event.type === 'step') {
        const prev = currentStepRef.current
        if (prev && prev !== event.step) {
          setCompletedSteps((p) => new Set(p).add(prev))
        }
        currentStepRef.current = event.step
        setCurrentStep(event.step)
        setStepLabels((prev) => ({ ...prev, [event.step]: event.label }))
      } else if (event.type === 'log') {
        setLog((prev) => [...prev, event.text])
      } else if (event.type === 'done') {
        const last = currentStepRef.current
        if (last) {
          setCompletedSteps((p) => new Set(p).add(last))
        }
        window.api.servers
          .get(event.payload.serverId)
          .then((server) => server && onDone(server))
      } else if (event.type === 'error') {
        setError(event.message)
        setDeploying(false)
      }
    })
    return unsubscribe
  }, [deploying, onDone])

  const startDeploy = (): void => {
    setError(null)
    setLog([])
    setCompletedSteps(new Set())
    setStepLabels({})
    currentStepRef.current = null
    setCurrentStep(null)
    setDeploying(true)
    window.api.deploy.start({
      host: form.host.trim(),
      port: Number(form.port) || 22,
      email: form.email.trim(),
      access
    })
  }

  const input = (
    label: string,
    key: keyof FormState,
    placeholder = '',
    type: 'text' | 'password' | 'email' = 'text'
  ): React.JSX.Element => (
    <TextField variant="secondary">
      <Label>{label}</Label>
      <Input
        type={type}
        value={form[key]}
        placeholder={placeholder}
        disabled={deploying}
        onChange={(e) => setForm((f) => ({ ...f, [key]: e.target.value }))}
      />
    </TextField>
  )

  return (
    <div className={styles.root}>
      <header className={styles.header}>
        <Button
          variant="secondary"
          size="sm"
          isDisabled={deploying}
          onPress={onBack}
        >
          {t('dashboard.back')}
        </Button>
        <h1 className={styles.title}>{t('deploy.title')}</h1>
      </header>

      <div className={styles.body}>
        <div className={styles.form}>
          {input(t('deploy.host'), 'host', '185.23.xx.xx')}
          {input(t('deploy.port'), 'port', '22')}
          <SshAccessForm value={access} onChange={setAccess} disabled={deploying} />
          {input(t('deploy.email'), 'email', 'user@example.com', 'email')}

          <Button
            className={styles.deployBtn}
            variant="primary"
            size="lg"
            fullWidth
            isDisabled={
              deploying ||
              !form.host.trim() ||
              !form.email.trim() ||
              !isSshAccessReady(access)
            }
            onPress={startDeploy}
          >
            {deploying && <Spinner size="sm" />}
            {deploying ? t('deploy.running') : t('deploy.button')}
          </Button>

          {error && (
            <div className={styles.error}>
              {t('deploy.error')}: {error}
            </div>
          )}
        </div>

        <div className={styles.status}>
          <div className={styles.statusTitle}>{t('deploy.progress')}</div>
          <ol className={styles.steps}>
            {STEP_ORDER.map((step) => {
              const state = completedSteps.has(step)
                ? 'done'
                : currentStep === step
                  ? 'active'
                  : 'todo'
              const statusText =
                state === 'done'
                  ? t('deploy.status.done')
                  : state === 'active'
                    ? stepLabels[step] ?? t(`deploy.active.${step}`)
                    : t('deploy.status.pending')
              return (
                <li
                  key={step}
                  className={`${styles.step} ${state === 'todo' ? '' : styles[state]}`}
                >
                  <div className={styles.stepRow}>
                    <span className={styles.stepIcon}>
                      {state === 'done' ? (
                        <CheckCircle2 className={styles.stepCheck} size={20} />
                      ) : state === 'active' ? (
                        <span className={styles.stepDot} />
                      ) : (
                        <Circle className={styles.stepTodo} size={16} />
                      )}
                    </span>
                    <span className={styles.stepLabel}>
                      {t(`deploy.steps.${step}`)}
                    </span>
                  </div>
                  <div className={styles.stepStatus} data-state={state}>
                    {statusText}
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
