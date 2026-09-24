import { readFileSync, statSync } from 'node:fs'
import { resolve } from 'node:path'
import type { Server, SshAccessInput } from '@shared/types'
import type { SshKeychain, SshPasswordStore } from './ssh-keychain'
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
  privateKey?: Buffer
}

export interface ResolvedSshAccess {
  access: SshAccessInput
  privateKey?: Buffer
}

export async function resolvePrivateKey(
  input: SshAccessInput,
  server: Pick<Server, 'privateKeyCredentialId' | 'privateKeyPath' | 'privateKeyName' | 'privateKeyPersisted'> | null,
  approvedPrivateKeyPaths: ReadonlySet<string>,
  keychain: SshKeychain
): Promise<ResolvedSshAccess> {
  const access = normalizeSshAccess(input, server?.privateKeyPath)
  // Любая заявленная renderer'ом path обязана быть одобрена dialog'ом — проверяем до
  // всех остальных веток, чтобы произвольный путь не использовался как fallback.
  if (access.privateKeyPath) {
    const requestedPath = resolve(access.privateKeyPath)
    if (!approvedPrivateKeyPaths.has(requestedPath)) {
      throw new Error('SSH-ключ должен быть выбран через диалог приложения')
    }
  }
  if (access.authMethod !== 'privateKey') return { access }

  const credentialId = access.privateKeyCredentialId ?? server?.privateKeyCredentialId ?? undefined
  if (credentialId) {
    const privateKey = await keychain.load(credentialId)
    if (privateKey) {
      access.privateKeyCredentialId = credentialId
      access.privateKeyName = access.privateKeyName ?? server?.privateKeyName ?? undefined
      if (access.privateKeyPersisted === undefined) {
        access.privateKeyPersisted = server?.privateKeyPersisted ?? true
      }
      return { access, privateKey }
    }
    // Ключевой материал недоступен; разрешаем только одобренный legacy-путь ниже.
  }

  const approvedPath = access.privateKeyPath ? resolve(access.privateKeyPath) : undefined
  if (!approvedPath) {
    throw new Error(
      credentialId
        ? 'SSH-ключ не найден в системном хранилище; выберите его заново'
        : 'Не выбран приватный SSH-ключ'
    )
  }
  const stat = statSync(approvedPath)
  if (!stat.isFile() || stat.size < 1 || stat.size > MAX_PRIVATE_KEY_BYTES) {
    throw new Error('Файл приватного SSH-ключа пустой или слишком большой')
  }
  access.privateKeyPersisted = false
  return { access, privateKey: readFileSync(approvedPath) }
}

export async function resolveStoredSshPassword(
  input: SshAccessInput,
  server: Pick<Server, 'passwordCredentialId'> | null,
  passwordStore: SshPasswordStore
): Promise<SshAccessInput> {
  const access = normalizeSshAccess(input)
  if (access.authMethod !== 'password' || access.password) return access

  const credentialId = access.passwordCredentialId ?? server?.passwordCredentialId ?? undefined
  if (!credentialId) return access

  const password = await passwordStore.load(credentialId)
  if (!password) {
    throw new Error('SSH-пароль не найден в системном хранилище; введите его заново')
  }
  access.password = password
  access.passwordCredentialId = credentialId
  access.passwordPersisted = true
  return access
}

export function normalizeSshAccess(
  access: SshAccessInput,
  fallbackPrivateKeyPath?: string | null
): SshAccessInput {
  return {
    username: access.username.trim(),
    authMethod: access.authMethod,
    password: access.password,
    passwordCredentialId: access.passwordCredentialId,
    passwordPersisted: access.passwordPersisted,
    privateKeyPath: access.privateKeyPath?.trim() || fallbackPrivateKeyPath || undefined,
    privateKeyCredentialId: access.privateKeyCredentialId,
    privateKeyName: access.privateKeyName,
    privateKeyPersisted: access.privateKeyPersisted,
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
  } else if (options.privateKey) {
    if (options.privateKey.length < 1 || options.privateKey.length > MAX_PRIVATE_KEY_BYTES) {
      throw new Error('SSH-ключ в системном хранилище пустой или слишком большой')
    }
    privateKey = options.privateKey
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
    privateKey: options.privateKey ?? privateKey,
    passphrase: access.authMethod === 'privateKey' ? access.passphrase : undefined,
    privilegeMode: access.privilegeMode,
    sudoPassword,
    expectedHostKeyFingerprint: options.expectedHostKeyFingerprint,
    onHostKeyTrusted: options.onHostKeyTrusted,
    onAuthenticated: options.onAuthenticated
  }
}
