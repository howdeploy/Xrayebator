import { Client, SFTPWrapper, ConnectConfig } from 'ssh2'
import { randomBytes } from 'node:crypto'
import type { SshPrivilegeMode } from '@shared/types'
import { shellQuote } from './shell-command'

export interface SshCredentials {
  host: string
  port: number
  username: string
  password?: string
  privateKey?: Buffer
  passphrase?: string
  privilegeMode: SshPrivilegeMode
  sudoPassword?: string
  expectedHostKeyFingerprint?: string
  onHostKeyTrusted?: (fingerprint: string) => void
  onAuthenticated?: () => void
}

export interface ExecResult {
  code: number
  stdout: string
  stderr: string
}

export interface ExecOptions {
  elevated?: boolean
  stdin?: string
}

export function formatHostKeyFingerprint(sha256Hex: string): string {
  if (!/^[0-9a-f]{64}$/i.test(sha256Hex)) {
    throw new Error('SSH-сервер вернул некорректный host key fingerprint')
  }
  const base64 = Buffer.from(sha256Hex, 'hex').toString('base64').replace(/=+$/, '')
  return `SHA256:${base64}`
}

export function buildSudoCommand(command: string, withPassword: boolean): string {
  if (!withPassword) return `sudo -n -- sh -c ${shellQuote(command)}`

  const commandWithoutStdin = `exec </dev/null; ${command}`
  return (
    `IFS= read -r XRAYEBATOR_SUDO_PASSWORD && ` +
    `printf '%s\\n' "$XRAYEBATOR_SUDO_PASSWORD" | ` +
    `sudo -S -p '' -- sh -c ${shellQuote(commandWithoutStdin)}`
  )
}

export class SshClient {
  private client: Client | null = null
  private sftp: SFTPWrapper | null = null

  constructor(private readonly creds: SshCredentials) {}

  async connect(): Promise<void> {
    if (!this.creds.password && !this.creds.privateKey) {
      throw new Error('Не указан SSH-пароль или приватный ключ')
    }

    let presentedFingerprint: string | null = null
    let hostKeyError: Error | null = null
    const config: ConnectConfig = {
      host: this.creds.host,
      port: this.creds.port,
      username: this.creds.username,
      readyTimeout: 20000,
      keepaliveInterval: 10000,
      hostHash: 'sha256',
      hostVerifier: (hashedKey: string) => {
        try {
          presentedFingerprint = formatHostKeyFingerprint(hashedKey)
          const expected = this.creds.expectedHostKeyFingerprint
          if (expected && expected !== presentedFingerprint) {
            hostKeyError = new Error(
              `SSH host key изменился для ${this.creds.host}:${this.creds.port}. ` +
                `Ожидался ${expected}, получен ${presentedFingerprint}. Подключение остановлено.`
            )
            return false
          }
          return true
        } catch (error) {
          hostKeyError = error instanceof Error ? error : new Error(String(error))
          return false
        }
      }
    }
    if (this.creds.password) config.password = this.creds.password
    if (this.creds.privateKey) config.privateKey = this.creds.privateKey
    if (this.creds.passphrase) config.passphrase = this.creds.passphrase

    await new Promise<void>((resolve, reject) => {
      const client = new Client()
      let settled = false
      const fail = (error: Error): void => {
        if (settled) return
        settled = true
        client.end()
        reject(hostKeyError ?? error)
      }
      client.on('ready', () => {
        if (settled) return
        try {
          if (!presentedFingerprint) {
            throw new Error('SSH-сервер не предоставил host key fingerprint')
          }
          if (!this.creds.expectedHostKeyFingerprint) {
            this.creds.onHostKeyTrusted?.(presentedFingerprint)
          }
          this.creds.onAuthenticated?.()
          settled = true
          this.client = client
          resolve()
        } catch (error) {
          fail(error instanceof Error ? error : new Error(String(error)))
        }
      })
      client.on('error', (error) => fail(error))
      client.on('close', () => {
        if (!settled) fail(new Error('SSH-соединение закрыто до завершения аутентификации'))
      })
      client.connect(config)
    })
  }

  async exec(command: string, options: ExecOptions = {}): Promise<ExecResult> {
    if (!this.client) throw new Error('SSH client not connected')

    let remoteCommand = command
    let stdin = options.stdin
    if (options.elevated && this.creds.privilegeMode === 'sudo') {
      remoteCommand = buildSudoCommand(command, Boolean(this.creds.sudoPassword))
      if (this.creds.sudoPassword) {
        if (stdin !== undefined) {
          throw new Error('Нельзя одновременно передавать stdin и sudo-пароль')
        }
        stdin = `${this.creds.sudoPassword}\n`
      }
    }

    return new Promise((resolve, reject) => {
      this.client!.exec(remoteCommand, (err, stream) => {
        if (err) return reject(err)
        let stdout = ''
        let stderr = ''
        stream.on('data', (data: Buffer) => {
          stdout += data.toString('utf8')
        })
        stream.stderr.on('data', (data: Buffer) => {
          stderr += data.toString('utf8')
        })
        stream.on('close', (code: number) => {
          resolve({ code, stdout, stderr })
        })
        stream.on('error', reject)
        if (stdin !== undefined) stream.end(stdin)
      })
    })
  }

  async getSftp(): Promise<SFTPWrapper> {
    if (!this.client) throw new Error('SSH client not connected')
    if (this.sftp) return this.sftp

    this.sftp = await new Promise<SFTPWrapper>((resolve, reject) => {
      this.client!.sftp((err, sftp) => (err ? reject(err) : resolve(sftp)))
    })
    return this.sftp
  }

  /** Передача файла из локального буфера в удалённый путь. */
  async upload(buffer: Buffer, remotePath: string): Promise<void> {
    const sftp = await this.getSftp()
    await new Promise<void>((resolve, reject) => {
      const stream = sftp.createWriteStream(remotePath, { mode: 0o755 })
      stream.on('close', () => resolve())
      stream.on('error', reject)
      stream.end(buffer)
    })
  }

  /** Случайный токен для имени временной папки на сервере. */
  static randomToken(): string {
    return randomBytes(6).toString('hex')
  }

  close(): void {
    if (this.client) this.client.end()
    this.client = null
    this.sftp = null
    this.creds.privateKey?.fill(0)
  }
}
