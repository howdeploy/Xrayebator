import { readFileSync, statSync } from 'node:fs'
import { resolve } from 'node:path'
import type { SshAccessInput } from '@shared/types'
import type { SshCredentials } from './ssh-client'

const MAX_PRIVATE_KEY_BYTES = 1024 * 1024
const MAX_SECRET_LENGTH = 16 * 1024

export interface SshTarget {
  host: string
  port: number
}

export interface SshCredentialOptions {
  approvedPrivateKeyPaths: ReadonlySet<string>
  expectedHostKeyFingerprint?: string
  fallbackPrivateKeyPath?: string | null
  onHostKeyTrusted?: (fingerprint: string) => void
  onAuthenticated?: () => void
}

export function normalizeSshAccess(
  access: SshAccessInput,
  fallbackPrivateKeyPath?: string | null
): SshAccessInput {
  return {
    username: access.username.trim(),
    authMethod: access.authMethod,
    password: access.password,
    privateKeyPath: access.privateKeyPath?.trim() || fallbackPrivateKeyPath || undefined,
    passphrase: access.passphrase,
    privilegeMode: access.privilegeMode,
    sudoPassword: access.sudoPassword
  }
}

function validateSecret(value: string | undefined, label: string): void {
  if (value === undefined) return
  if (value.length > MAX_SECRET_LENGTH) throw new Error(`${label} слишком длинный`)
  if (/[\r\n]/.test(value)) throw new Error(`${label} не может содержать перевод строки`)
}

export function createSshCredentials(
  target: SshTarget,
  input: SshAccessInput,
  options: SshCredentialOptions
): SshCredentials {
  const access = normalizeSshAccess(input, options.fallbackPrivateKeyPath)
  if (!target.host || target.host.length > 255 || /[\s\0-\x1f\x7f]/.test(target.host)) {
    throw new Error('Некорректный SSH host')
  }
  if (!Number.isInteger(target.port) || target.port < 1 || target.port > 65535) {
    throw new Error('Некорректный SSH-порт')
  }
  if (!/^[A-Za-z_][A-Za-z0-9_.-]{0,63}\$?$/.test(access.username)) {
    throw new Error('Некорректное имя SSH-пользователя')
  }
  if (access.authMethod !== 'password' && access.authMethod !== 'privateKey') {
    throw new Error('Неизвестный способ SSH-аутентификации')
  }
  if (access.privilegeMode !== 'root' && access.privilegeMode !== 'sudo') {
    throw new Error('Неизвестный режим привилегий')
  }

  validateSecret(access.password, 'SSH-пароль')
  validateSecret(access.passphrase, 'Passphrase')
  validateSecret(access.sudoPassword, 'Пароль sudo')

  let approvedKeyPath: string | undefined
  if (access.privateKeyPath) {
    approvedKeyPath = resolve(access.privateKeyPath)
    if (!options.approvedPrivateKeyPaths.has(approvedKeyPath)) {
      throw new Error('SSH-ключ должен быть выбран через диалог приложения')
    }
  }

  let privateKey: Buffer | undefined
  if (access.authMethod === 'password') {
    if (!access.password) throw new Error('Не указан SSH-пароль')
  } else {
    if (!approvedKeyPath) throw new Error('Не выбран приватный SSH-ключ')
    const stat = statSync(approvedKeyPath)
    if (!stat.isFile() || stat.size < 1 || stat.size > MAX_PRIVATE_KEY_BYTES) {
      throw new Error('Файл приватного SSH-ключа пустой или слишком большой')
    }
    privateKey = readFileSync(approvedKeyPath)
  }

  const sudoPassword =
    access.privilegeMode === 'sudo'
      ? access.sudoPassword || (access.authMethod === 'password' ? access.password : undefined)
      : undefined

  return {
    host: target.host,
    port: target.port,
    username: access.username,
    password: access.authMethod === 'password' ? access.password : undefined,
    privateKey,
    passphrase: access.authMethod === 'privateKey' ? access.passphrase : undefined,
    privilegeMode: access.privilegeMode,
    sudoPassword,
    expectedHostKeyFingerprint: options.expectedHostKeyFingerprint,
    onHostKeyTrusted: options.onHostKeyTrusted,
    onAuthenticated: options.onAuthenticated
  }
}
