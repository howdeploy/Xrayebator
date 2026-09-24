import type { SshAuthMethod } from '@shared/types'

export interface SavedServerAccess {
  authMethod?: SshAuthMethod
  username?: string | null
  host?: string | null
  port?: number | null
  passwordCredentialId?: string | null
  privateKeyCredentialId?: string | null
  privateKeyPersisted?: boolean | null
  passwordPersisted?: boolean | null
}

/** Auto-connect only when a secret is known to live in the OS keychain. */
export function shouldAutoConnectServer(server: SavedServerAccess): boolean {
  if (server.authMethod === 'password') return Boolean(server.passwordCredentialId)
  if (server.authMethod === 'privateKey') {
    return Boolean(server.privateKeyCredentialId) && server.privateKeyPersisted !== false
  }
  return false
}

/** Где сейчас лежит секрет доступа — ключ i18n для подписи в карточке сервера. */
export type AccessSecretState = 'passwordSaved' | 'keySaved' | 'sessionOnly' | 'notSaved'

export interface AccessSummary {
  /** root@host:port — фактический SSH-endpoint входа. */
  endpoint: string
  secret: AccessSecretState
}

/** Компактное описание доступа для карточки сервера на дашборде. */
export function accessSummary(server: SavedServerAccess): AccessSummary {
  const endpoint = `${server.username ?? ''}@${server.host ?? ''}:${server.port ?? 22}`
  if (server.authMethod === 'privateKey') {
    const secret: AccessSecretState = !server.privateKeyCredentialId
      ? 'notSaved'
      : server.privateKeyPersisted === false
        ? 'sessionOnly'
        : 'keySaved'
    return { endpoint, secret }
  }
  // password (default)
  const secret: AccessSecretState = !server.passwordCredentialId
    ? 'notSaved'
    : server.passwordPersisted === false
      ? 'sessionOnly'
      : 'passwordSaved'
  return { endpoint, secret }
}
