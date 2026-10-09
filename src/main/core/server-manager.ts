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
 * Ветка обновления: закреплённая на сервере (.current_branch) или явная.
 * Явная ветка — бета-режим «обновиться с dev, не трогая main» (см. ServerManager.update).
 * Префикс xrayebator- — тег v0.6.0: legacy-серверы с .current_branch=xrayebator-0.2.0.
 */
export function isAllowedUpdateBranch(branch: string): boolean {
  if (branch === 'main' || branch === 'dev' || branch === 'experimental') return true
  if (branch.startsWith('xrayebator-')) return true
  return isSafeUpdateBranch(branch)
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
   * Явная ветка (например, dev) — управляемая бета: сервер забирает менеджера с dev,
   * не дожидаясь вливания в main; .current_branch на сервере переписывается на dev.
   */
  async update(branch?: string): Promise<ServerMaintenanceResult> {
    const client = new SshClient(this.creds)
    // Ветка берётся из .current_branch на сервере (её закрепляет
    // `xrayebator update <branch>`); main — только дефолт для серверов,
    // где ветка ещё не закреплена. Явная ветка перекрывает обе.
    let tracked = 'main'
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
      tracked = result.stdout.trim() || 'main'
      const target = branch ?? tracked
      if (!isAllowedUpdateBranch(target)) {
        return {
          ok: false,
          error:
            branch !== undefined
              ? `Ветка обновления «${branch}» не разрешена: используйте main, dev или experimental`
              : 'На сервере записано некорректное имя ветки обновления'
        }
      }

      const command = shellCommand('xrayebator', ['update', target])
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
