import keytar from 'keytar'

export const SSH_KEYCHAIN_SERVICE = 'com.xrayebator.gui.ssh-key'
export const SSH_PASSWORD_SERVICE = 'com.xrayebator.gui.ssh-password'
export const MAX_PRIVATE_KEY_BYTES = 1024 * 1024

export interface KeychainApi {
  getPassword(service: string, account: string): Promise<string | null>
  setPassword(service: string, account: string, password: string): Promise<void>
  deletePassword(service: string, account: string): Promise<boolean>
}

export interface SshKeychain {
  save(credentialId: string, key: Buffer): Promise<void>
  load(credentialId: string): Promise<Buffer | null>
  remove(credentialId: string): Promise<void>
}

export interface SshPasswordStore {
  save(credentialId: string, password: string): Promise<void>
  load(credentialId: string): Promise<string | null>
  remove(credentialId: string): Promise<void>
}

const MAX_SSH_PASSWORD_LENGTH = 16 * 1024

function validateCredentialId(credentialId: string): void {
  if (!/^[A-Za-z0-9_-]{8,128}$/.test(credentialId)) {
    throw new Error('Некорректный идентификатор SSH-ключа')
  }
}

function decodeKey(encoded: string): Buffer {
  if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(encoded)) {
    throw new Error('SSH-ключ в системном хранилище повреждён')
  }
  const key = Buffer.from(encoded, 'base64')
  if (key.length < 1) {
    key.fill(0)
    throw new Error('SSH-ключ в системном хранилище повреждён')
  }
  if (key.length > MAX_PRIVATE_KEY_BYTES) {
    key.fill(0)
    throw new Error('SSH-ключ в системном хранилище слишком большой')
  }
  return key
}

export function createSshPasswordStore(api: KeychainApi = keytar): SshPasswordStore {
  const validatePassword = (password: string): void => {
    if (!password || password.length > MAX_SSH_PASSWORD_LENGTH) {
      throw new Error('SSH-пароль пустой или слишком большой')
    }
    if (/[\r\n\0]/.test(password)) {
      throw new Error('SSH-пароль не может содержать перевод строки')
    }
  }

  return {
    async save(credentialId, password) {
      validateCredentialId(credentialId)
      if (!password) return
      validatePassword(password)
      await api.setPassword(SSH_PASSWORD_SERVICE, credentialId, password)
    },

    async load(credentialId) {
      validateCredentialId(credentialId)
      const password = await api.getPassword(SSH_PASSWORD_SERVICE, credentialId)
      if (password === null) return null
      validatePassword(password)
      return password
    },

    async remove(credentialId) {
      validateCredentialId(credentialId)
      await api.deletePassword(SSH_PASSWORD_SERVICE, credentialId)
    }
  }
}

export function createSshKeychain(api: KeychainApi = keytar): SshKeychain {
  return {
    async save(credentialId, key) {
      validateCredentialId(credentialId)
      if (key.length < 1 || key.length > MAX_PRIVATE_KEY_BYTES) {
        throw new Error('Приватный SSH-ключ пустой или слишком большой')
      }
      await api.setPassword(SSH_KEYCHAIN_SERVICE, credentialId, key.toString('base64'))
    },

    async load(credentialId) {
      validateCredentialId(credentialId)
      const encoded = await api.getPassword(SSH_KEYCHAIN_SERVICE, credentialId)
      return encoded === null ? null : decodeKey(encoded)
    },

    async remove(credentialId) {
      validateCredentialId(credentialId)
      await api.deletePassword(SSH_KEYCHAIN_SERVICE, credentialId)
    }
  }
}
