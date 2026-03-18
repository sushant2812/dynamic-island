import { app, BrowserWindow, ipcMain, screen } from 'electron'
import path from 'node:path'
import fs from 'node:fs'

type RendererConfig = {
  rendererUrl: string
  rendererDist: string
}

function readRendererConfig(): RendererConfig {
  const configPath = path.resolve(app.getAppPath(), 'electron.vite.json')
  const raw = fs.readFileSync(configPath, 'utf-8')
  return JSON.parse(raw) as RendererConfig
}

function getRendererTarget() {
  const { rendererUrl, rendererDist } = readRendererConfig()
  const devUrl = process.env.ELECTRON_START_URL ?? rendererUrl

  if (process.env.NODE_ENV === 'development' || process.env.ELECTRON_START_URL) {
    return { kind: 'url' as const, value: devUrl }
  }

  return { kind: 'file' as const, value: path.resolve(app.getAppPath(), rendererDist) }
}

function fullWidthTopBounds(windowHeight: number) {
  const display = screen.getPrimaryDisplay()
  // Use full screen bounds (not workArea) so we can sit "on" the menu bar area.
  const bounds = display.bounds
  const x = Math.round(bounds.x)
  const y = Math.round(bounds.y)
  return { x, y, width: Math.round(bounds.width), height: windowHeight }
}

function createIslandWindow() {
  const COLLAPSED_HEIGHT = 48
  const EXPANDED_HEIGHT = 220

  const bounds = fullWidthTopBounds(COLLAPSED_HEIGHT)
  const win = new BrowserWindow({
    ...bounds,
    frame: false,
    transparent: true,
    resizable: false,
    movable: false,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    hasShadow: false,
    alwaysOnTop: true,
    skipTaskbar: true,
    show: false,
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      sandbox: true,
      preload: path.join(app.getAppPath(), 'dist/main/preload.js'),
    },
  })

  win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true })
  win.setAlwaysOnTop(true, 'screen-saver')
  // Start as click-through; renderer will enable interaction over the pill/panel.
  win.setIgnoreMouseEvents(true, { forward: true })

  const target = getRendererTarget()
  if (target.kind === 'url') {
    void win.loadURL(target.value)
  } else {
    void win.loadFile(target.value)
  }

  win.once('ready-to-show', () => {
    win.showInactive()
  })

  let isExpanded = false
  let isInteractive = false

  const setExpanded = (expanded: boolean) => {
    isExpanded = expanded
    const nextHeight = expanded ? EXPANDED_HEIGHT : COLLAPSED_HEIGHT
    const next = fullWidthTopBounds(nextHeight)
    win.setBounds(next, false)
  }

  const reposition = () => {
    const nextHeight = isExpanded ? EXPANDED_HEIGHT : COLLAPSED_HEIGHT
    const next = fullWidthTopBounds(nextHeight)
    win.setBounds(next, false)
  }

  ipcMain.handle('island:setExpanded', (_event, expanded: boolean) => {
    setExpanded(Boolean(expanded))
    return { expanded: isExpanded }
  })

  ipcMain.handle('island:setInteractive', (_event, interactive: boolean) => {
    isInteractive = Boolean(interactive)
    win.setIgnoreMouseEvents(!isInteractive, { forward: true })
    return { interactive: isInteractive }
  })

  screen.on('display-metrics-changed', reposition)
  screen.on('display-added', reposition)
  screen.on('display-removed', reposition)

  win.on('closed', () => {
    ipcMain.removeHandler('island:setExpanded')
    ipcMain.removeHandler('island:setInteractive')
    screen.removeListener('display-metrics-changed', reposition)
    screen.removeListener('display-added', reposition)
    screen.removeListener('display-removed', reposition)
  })

  return win
}

app.commandLine.appendSwitch('disable-backgrounding-occluded-windows', 'true')

app.whenReady().then(() => {
  createIslandWindow()
})

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit()
})

