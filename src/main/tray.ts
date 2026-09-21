import { Tray, Menu, app, BrowserWindow, nativeImage } from 'electron'
import { join } from 'node:path'

let tray: Tray | null = null

export function createTray(): void {
  const iconPath = app.isPackaged
    ? join(process.resourcesPath, 'icons', 'icon.png')
    : join(__dirname, '../../resources/icons/icon.png')
  const icon = nativeImage.createFromPath(iconPath)
  tray = new Tray(icon)
  tray.setToolTip('Xrayebator')

  const menu = Menu.buildFromTemplate([
    {
      label: 'Открыть',
      click: () => {
        const [win] = BrowserWindow.getAllWindows()
        if (win) {
          win.show()
          win.focus()
        }
      }
    },
    { type: 'separator' },
    {
      label: 'Выход',
      click: () => app.quit()
    }
  ])
  tray.setContextMenu(menu)
}
