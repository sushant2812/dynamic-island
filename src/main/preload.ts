import { contextBridge, ipcRenderer } from 'electron'

type IslandAPI = {
  setExpanded: (expanded: boolean) => Promise<{ expanded: boolean }>
  setInteractive: (interactive: boolean) => Promise<{ interactive: boolean }>
}

const api: IslandAPI = {
  setExpanded: (expanded) => ipcRenderer.invoke('island:setExpanded', expanded),
  setInteractive: (interactive) => ipcRenderer.invoke('island:setInteractive', interactive),
}

contextBridge.exposeInMainWorld('island', api)

