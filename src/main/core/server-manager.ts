import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { app } from 'electron'
import { SshClient, SshCredentials } from './ssh-client'
import { shellCommand } from './shell-command'
import type { ServerMaintenanceResult } from '@shared/types'

/** Путь к сценариям: в собранном приложении — resources/scripts, в dev — корень проекта. */
function scriptsDir(): string {
  if (app.isPackaged) {
    return join(process.resourcesPath, 'scripts')
  }
  return app.getAppPath()
}

export function isSafeUpdateBranch(branch: string): boolean {
  return (
    /^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$/.test(branch) &&
    !branch.includes('..') &&
    !branch.includes('//')
  )
}

/**
 * Операции над установкой на сервере: обновление скрипта/Xray и полное удаление.
 * Требует root-доступа напрямую или через sudo.
 */
export class ServerManager {
  constructor(private readonly creds: SshCredentials) {}

  /**
   * Обновление: self-update скрипта xrayebator с ветки + обновление Xray-core.
   * update_command с аргументом ветки делает self-update и exec'ится в свежий скрипт.
   */
  async update(): Promise<ServerMaintenanceResult> {
    const client = new SshClient(this.creds)
    let branch = 'main'
    try {
      await client.connect()
      const result = await client.exec(
        shellCommand('sh', [
          '-c',
          'if [ -f /usr/local/etc/xray/.current_branch ]; then cat /usr/local/etc/xray/.current_branch; fi'
        ]),
        { elevated: true }
      )
      if (result.code !== 0) {
        return { ok: false, error: 'Не удалось прочитать закреплённую ветку обновления' }
      }
      const tracked = result.stdout.trim()
      if (tracked) branch = tracked
      if (!isSafeUpdateBranch(branch)) {
        return { ok: false, error: 'На сервере записано некорректное имя ветки обновления' }
      }

      const command = shellCommand('xrayebator', ['update', branch])
      const updated = await client.exec(
        shellCommand('timeout', ['600', 'sh', '-c', command]),
        { elevated: true }
      )
      const output = `${updated.stdout}\n${updated.stderr}`.trim()
      if (updated.code !== 0) {
        return { ok: false, error: output || `команда завершилась с кодом ${updated.code}` }
      }
      return { ok: true, output }
    } catch (err) {
      return { ok: false, error: err instanceof Error ? err.message : String(err) }
    } finally {
      client.close()
    }
  }

  /**
   * Полное удаление: загружает uninstall.sh на сервер и запускает в неинтерактивном
   * режиме (подтверждение "yes" подаётся через stdin).
   */
  async uninstall(): Promise<ServerMaintenanceResult> {
    const client = new SshClient(this.creds)
    try {
      await client.connect()
      const remote = `/tmp/xrayebator-uninstall-${SshClient.randomToken()}.sh`
      await client.upload(readFileSync(join(scriptsDir(), 'uninstall.sh')), remote)
      const res = await client.exec(`yes | ${shellCommand('bash', [remote])}`, {
        elevated: true
      })
      const output = `${res.stdout}\n${res.stderr}`.trim()
      if (res.code !== 0) {
        return { ok: false, error: output || `uninstall завершился с кодом ${res.code}` }
      }
      return { ok: true, output }
    } catch (err) {
      return { ok: false, error: err instanceof Error ? err.message : String(err) }
    } finally {
      client.close()
    }
  }
}
