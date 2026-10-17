import { useEffect, useRef, useState } from 'react'
import { Button, TextField, Label, Input, Spinner } from '@heroui/react'
import { CheckCircle2, Circle, Mail, MailX, ShieldCheck, Zap } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import type {
  DeployEvent,
  DeployStep,
  Server,
  SshAccessInput
} from '@shared/types'
import { isDns01Ready } from '@shared/dns01'
import { SshAccessForm } from '../components/SshAccessForm'
import { buildDeployPayload, dns01FromForm, isDeployReady, type DeployFormState } from './deploy-readiness'
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

interface FormState extends DeployFormState {}

export function AddServer({ onDone, onBack }: AddServerProps): React.JSX.Element {
  const { t } = useTranslation()
  const [form, setForm] = useState<FormState>({
    host: '',
    port: '22',
    emailMode: 'provided',
    email: '',
    // PQ и DNS-01 — осознанный opt-in: PQ-порт бесполезен для клиента без ML-KEM,
    // а DNS-01 требует домена и токена, которых у большинства пользователей нет.
    pq: false,
    dns01Enabled: false,
    dns01Provider: 'cloudflare',
    dns01Domain: '',
    dns01Token: '',
    dns01AwsKeyId: '',
    dns01AwsSecret: ''
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
    window.api.deploy.start(buildDeployPayload(form, access))
  }

  const input = (
    label: string,
    key: Extract<keyof FormState, string>,
    placeholder = '',
    type: 'text' | 'password' | 'email' = 'text'
  ): React.JSX.Element => (
    <TextField variant="secondary">
      <Label>{label}</Label>
      <Input
        type={type}
        value={form[key] as string}
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

          <div className={styles.fieldGroup}>
            <span className={styles.groupLabel}>{t('deploy.emailMode')}</span>
            <div className={styles.choiceGrid}>
              <button
                type="button"
                className={`${styles.choice} ${
                  form.emailMode === 'provided' ? styles.choiceActive : ''
                }`}
                disabled={deploying}
                aria-pressed={form.emailMode === 'provided'}
                onClick={() => setForm((f) => ({ ...f, emailMode: 'provided' }))}
              >
                <Mail size={17} />
                <span>
                  <strong>{t('deploy.emailProvided')}</strong>
                  <small>{t('deploy.emailProvidedHint')}</small>
                </span>
              </button>
              <button
                type="button"
                className={`${styles.choice} ${
                  form.emailMode === 'without' ? styles.choiceActive : ''
                }`}
                disabled={deploying}
                aria-pressed={form.emailMode === 'without'}
                onClick={() => setForm((f) => ({ ...f, emailMode: 'without' }))}
              >
                <MailX size={17} />
                <span>
                  <strong>{t('deploy.emailWithout')}</strong>
                  <small>{t('deploy.emailWithoutHint')}</small>
                </span>
              </button>
            </div>
          </div>

          {form.emailMode === 'provided' ? (
            input(t('deploy.email'), 'email', 'user@example.com', 'email')
          ) : (
            <div className={styles.warning}>{t('deploy.withoutEmailWarning')}</div>
          )}

          <div className={styles.fieldGroup}>
            <span className={styles.groupLabel}>{t('deploy.pq')}</span>
            <div className={styles.choiceGrid}>
              <button
                type="button"
                className={`${styles.choice} ${form.pq ? styles.choiceActive : ''}`}
                disabled={deploying}
                aria-pressed={form.pq === true}
                onClick={() => setForm((f) => ({ ...f, pq: !f.pq }))}
              >
                <Zap size={17} />
                <span>
                  <strong>{form.pq ? t('deploy.pq') : t('deploy.pqOff')}</strong>
                  <small>{t('deploy.pqHint')}</small>
                </span>
              </button>
            </div>
            {form.pq && <div className={styles.warning}>{t('deploy.pqWarning')}</div>}
          </div>

          <div className={styles.fieldGroup}>
            <span className={styles.groupLabel}>{t('deploy.dns01')}</span>
            <div className={styles.choiceGrid}>
              <button
                type="button"
                className={`${styles.choice} ${form.dns01Enabled ? styles.choiceActive : ''}`}
                disabled={deploying}
                aria-pressed={form.dns01Enabled === true}
                onClick={() => setForm((f) => ({ ...f, dns01Enabled: !f.dns01Enabled }))}
              >
                <ShieldCheck size={17} />
                <span>
                  <strong>
                    {form.dns01Enabled ? t('deploy.dns01On') : t('deploy.dns01Off')}
                  </strong>
                  <small>{t('deploy.dns01Hint')}</small>
                </span>
              </button>
            </div>

            {form.dns01Enabled && (
              <>
                {/* Провайдер выбирается явно: креденшелы Cloudflare и Route53
                    не взаимозаменяемы, и лишние поля только путают. */}
                <div className={styles.choiceGrid}>
                  {(['cloudflare', 'route53'] as const).map((p) => (
                    <button
                      key={p}
                      type="button"
                      className={`${styles.choice} ${
                        (form.dns01Provider ?? 'cloudflare') === p ? styles.choiceActive : ''
                      }`}
                      disabled={deploying}
                      aria-pressed={(form.dns01Provider ?? 'cloudflare') === p}
                      onClick={() => setForm((f) => ({ ...f, dns01Provider: p }))}
                    >
                      <ShieldCheck size={17} />
                      <span>
                        <strong>{p === 'cloudflare' ? 'Cloudflare' : 'Route53'}</strong>
                      </span>
                    </button>
                  ))}
                </div>

                <TextField variant="secondary">
                  <Label>{t('deploy.dns01Domain')}</Label>
                  <Input
                    value={form.dns01Domain ?? ''}
                    placeholder="sub.example.com"
                    disabled={deploying}
                    onChange={(e) => setForm((f) => ({ ...f, dns01Domain: e.target.value }))}
                  />
                </TextField>
                <div className={styles.warning}>{t('deploy.dns01DomainHint')}</div>

                {(form.dns01Provider ?? 'cloudflare') === 'cloudflare' ? (
                  <TextField variant="secondary">
                    <Label>{t('deploy.dns01Token')}</Label>
                    <Input
                      type="password"
                      value={form.dns01Token ?? ''}
                      disabled={deploying}
                      onChange={(e) => setForm((f) => ({ ...f, dns01Token: e.target.value }))}
                    />
                  </TextField>
                ) : (
                  <>
                    <TextField variant="secondary">
                      <Label>{t('deploy.dns01AwsKey')}</Label>
                      <Input
                        value={form.dns01AwsKeyId ?? ''}
                        disabled={deploying}
                        onChange={(e) => setForm((f) => ({ ...f, dns01AwsKeyId: e.target.value }))}
                      />
                    </TextField>
                    <TextField variant="secondary">
                      <Label>{t('deploy.dns01AwsSecret')}</Label>
                      <Input
                        type="password"
                        value={form.dns01AwsSecret ?? ''}
                        disabled={deploying}
                        onChange={(e) => setForm((f) => ({ ...f, dns01AwsSecret: e.target.value }))}
                      />
                    </TextField>
                  </>
                )}
                <div className={styles.warning}>{t('deploy.dns01SecretNote')}</div>
                {!isDns01Ready(dns01FromForm(form)) && (
                  <div className={styles.warning}>{t('settings.dns01Incomplete')}</div>
                )}
              </>
            )}
          </div>

          <Button
            className={styles.deployBtn}
            variant="primary"
            size="lg"
            fullWidth
            isDisabled={deploying || !isDeployReady(form, access)}
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
