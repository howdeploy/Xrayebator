import { useState } from 'react'
import { Button, Input, Label, TextField } from '@heroui/react'
import { FileKey2, KeyRound, LockKeyhole, ShieldCheck, ShieldQuestion } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import type { SshAccessInput } from '@shared/types'
import styles from './SshAccessForm.module.css'

interface SshAccessFormProps {
  value: SshAccessInput
  onChange: (value: SshAccessInput) => void
  disabled?: boolean
  hostKeyFingerprint?: string | null
  onForgetHostKey?: () => void
}

export function isSshAccessReady(access: SshAccessInput): boolean {
  if (!access.username.trim()) return false
  if (access.authMethod === 'password') return Boolean(access.password)
  return Boolean(access.privateKeyPath)
}

export function SshAccessForm({
  value,
  onChange,
  disabled = false,
  hostKeyFingerprint,
  onForgetHostKey
}: SshAccessFormProps): React.JSX.Element {
  const { t } = useTranslation()
  const [keyError, setKeyError] = useState<string | null>(null)
  const keyName = value.privateKeyPath?.split(/[\\/]/).pop()

  const update = (patch: Partial<SshAccessInput>): void => {
    onChange({ ...value, ...patch })
  }

  const selectPrivateKey = async (): Promise<void> => {
    setKeyError(null)
    try {
      const selection = await window.api.ssh.selectPrivateKey()
      if (selection) update({ privateKeyPath: selection.path })
    } catch (error) {
      setKeyError(error instanceof Error ? error.message : String(error))
    }
  }

  return (
    <div className={styles.root}>
      <TextField variant="secondary">
        <Label>{t('sshAccess.username')}</Label>
        <Input
          value={value.username}
          disabled={disabled}
          placeholder="root"
          autoComplete="username"
          onChange={(event) => update({ username: event.target.value })}
        />
      </TextField>

      <div className={styles.fieldGroup}>
        <span className={styles.label}>{t('sshAccess.authMethod')}</span>
        <div className={styles.choiceGrid}>
          <button
            type="button"
            className={`${styles.choice} ${
              value.authMethod === 'password' ? styles.choiceActive : ''
            }`}
            disabled={disabled}
            aria-pressed={value.authMethod === 'password'}
            onClick={() => update({ authMethod: 'password' })}
          >
            <LockKeyhole size={17} />
            <span>
              <strong>{t('sshAccess.password')}</strong>
              <small>{t('sshAccess.passwordHint')}</small>
            </span>
          </button>
          <button
            type="button"
            className={`${styles.choice} ${
              value.authMethod === 'privateKey' ? styles.choiceActive : ''
            }`}
            disabled={disabled}
            aria-pressed={value.authMethod === 'privateKey'}
            onClick={() => update({ authMethod: 'privateKey' })}
          >
            <KeyRound size={17} />
            <span>
              <strong>{t('sshAccess.privateKey')}</strong>
              <small>{t('sshAccess.privateKeyHint')}</small>
            </span>
          </button>
        </div>
      </div>

      {value.authMethod === 'password' ? (
        <TextField variant="secondary">
          <Label>{t('sshAccess.sshPassword')}</Label>
          <Input
            type="password"
            value={value.password ?? ''}
            disabled={disabled}
            placeholder="••••••••"
            autoComplete="current-password"
            onChange={(event) => update({ password: event.target.value })}
          />
        </TextField>
      ) : (
        <div className={styles.keyFields}>
          <div className={styles.keyPicker}>
            <Button variant="secondary" isDisabled={disabled} onPress={selectPrivateKey}>
              <FileKey2 size={16} />
              {keyName ? t('sshAccess.changeKey') : t('sshAccess.selectKey')}
            </Button>
            <span className={keyName ? styles.keyName : styles.keyMissing}>
              {keyName ?? t('sshAccess.noKey')}
            </span>
          </div>
          <TextField variant="secondary">
            <Label>{t('sshAccess.passphrase')}</Label>
            <Input
              type="password"
              value={value.passphrase ?? ''}
              disabled={disabled}
              placeholder={t('sshAccess.optional')}
              autoComplete="off"
              onChange={(event) => update({ passphrase: event.target.value })}
            />
          </TextField>
          {keyError && <div className={styles.error}>{keyError}</div>}
        </div>
      )}

      <div className={styles.fieldGroup}>
        <span className={styles.label}>{t('sshAccess.privileges')}</span>
        <div className={styles.choiceGrid}>
          <button
            type="button"
            className={`${styles.choice} ${
              value.privilegeMode === 'root' ? styles.choiceActive : ''
            }`}
            disabled={disabled}
            aria-pressed={value.privilegeMode === 'root'}
            onClick={() => update({ privilegeMode: 'root' })}
          >
            <ShieldCheck size={17} />
            <span>
              <strong>
                {t('sshAccess.directRoot')}
                <em>{t('sshAccess.default')}</em>
              </strong>
              <small>{t('sshAccess.directRootHint')}</small>
            </span>
          </button>
          <button
            type="button"
            className={`${styles.choice} ${
              value.privilegeMode === 'sudo' ? styles.choiceActive : ''
            }`}
            disabled={disabled}
            aria-pressed={value.privilegeMode === 'sudo'}
            onClick={() => update({ privilegeMode: 'sudo' })}
          >
            <ShieldQuestion size={17} />
            <span>
              <strong>{t('sshAccess.sudo')}</strong>
              <small>{t('sshAccess.sudoHint')}</small>
            </span>
          </button>
        </div>
      </div>

      {value.privilegeMode === 'sudo' && (
        <TextField variant="secondary">
          <Label>{t('sshAccess.sudoPassword')}</Label>
          <Input
            type="password"
            value={value.sudoPassword ?? ''}
            disabled={disabled}
            placeholder={t('sshAccess.optional')}
            autoComplete="off"
            onChange={(event) => update({ sudoPassword: event.target.value })}
          />
          <span className={styles.note}>{t('sshAccess.sudoPasswordHint')}</span>
        </TextField>
      )}

      <div className={styles.hostKey}>
        {hostKeyFingerprint ? <ShieldCheck size={15} /> : <ShieldQuestion size={15} />}
        <span className={styles.hostKeyText}>
          {hostKeyFingerprint
            ? t('sshAccess.hostKeyPinned', { fingerprint: hostKeyFingerprint })
            : t('sshAccess.hostKeyFirstUse')}
        </span>
        {hostKeyFingerprint && onForgetHostKey && (
          <button
            type="button"
            className={styles.hostKeyReset}
            disabled={disabled}
            onClick={onForgetHostKey}
          >
            {t('sshAccess.resetHostKey')}
          </button>
        )}
      </div>
    </div>
  )
}
