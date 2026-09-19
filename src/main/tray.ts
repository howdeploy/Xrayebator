import { Tray, Menu, app, BrowserWindow, nativeImage } from 'electron'

let tray: Tray | null = null

export function createTray(): void {
  const icon = nativeImage.createFromDataURL(
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='
  )
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
