import { BrowserWindow, app } from 'electron'
import { autoUpdater } from 'electron-updater'

let initialized = false

async function checkForUpdatesSafely(): Promise<void> {
  try {
    await autoUpdater.checkForUpdates()
  } catch (error) {
    console.error('[auto-updater] update check failed', error)
  }
}

export function initAutoUpdater(): void {
  if (initialized || !app.isPackaged) return
  initialized = true

  autoUpdater.autoDownload = true
  autoUpdater.autoInstallOnAppQuit = true

  autoUpdater.on('update-available', (info) => {
    const win = BrowserWindow.getAllWindows()[0]
    if (win && !win.isDestroyed()) {
      win.webContents.send('update:available', info.version)
    }
  })

  autoUpdater.on('error', (error) => {
    console.error('[auto-updater] error', error)
  })

  void checkForUpdatesSafely()
  setInterval(() => void checkForUpdatesSafely(), 4 * 60 * 60 * 1000).unref()
}
