import type { SshAuthMethod } from '@shared/types'

export interface SavedServerAccess {
  authMethod?: SshAuthMethod
  passwordCredentialId?: string | null
  privateKeyCredentialId?: string | null
  privateKeyPersisted?: boolean | null
}

/** Auto-connect only when a secret is known to live in the OS keychain. */
export function shouldAutoConnectServer(server: SavedServerAccess): boolean {
  if (server.authMethod === 'password') return Boolean(server.passwordCredentialId)
  if (server.authMethod === 'privateKey') {
    return Boolean(server.privateKeyCredentialId) && server.privateKeyPersisted !== false
  }
  return false
}
