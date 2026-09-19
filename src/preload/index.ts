import { contextBridge, ipcRenderer } from 'electron'
import type {
  DeployEvent,
  DeployStartPayload,
  ElectronAPI,
  PrivateKeySelection,
  ProfileCreateInput,
  ProfileCreateResult,
  ProfileDeleteResult,
  ProfileFingerprintInput,
  ProfileFingerprintResult,
  ProfilePortInput,
  ProfilePortResult,
  ProfileSniInput,
  ProfileSniResult,
  SniListResult,
  Server,
  ServerMaintenanceResult,
  ServerProfile,
  SshAccessInput,
  SubscriptionResult
} from '@shared/types'

const api: ElectronAPI = {
  ssh: {
    selectPrivateKey: (): Promise<PrivateKeySelection | null> =>
      ipcRenderer.invoke('ssh:selectPrivateKey')
  },

  servers: {
    list: (): Promise<Server[]> => ipcRenderer.invoke('servers:list'),
    remove: (id: string): Promise<void> => ipcRenderer.invoke('servers:remove', id),
    get: (id: string): Promise<Server | null> => ipcRenderer.invoke('servers:get', id),
    check: (id: string): Promise<boolean> => ipcRenderer.invoke('servers:check', id),
    forgetHostKey: (id: string): Promise<void> =>
      ipcRenderer.invoke('servers:forgetHostKey', id)
  },

  deploy: {
    start: (payload: DeployStartPayload): void => {
      ipcRenderer.send('deploy:start', payload)
    },
    onEvent: (callback: (event: DeployEvent) => void): (() => void) => {
      const listener = (_e: Electron.IpcRendererEvent, event: DeployEvent): void =>
        callback(event)
      ipcRenderer.on('deploy:event', listener)
      return () => ipcRenderer.removeListener('deploy:event', listener)
    }
  },

  subscription: {
    fetch: (serverId: string): Promise<SubscriptionResult> =>
      ipcRenderer.invoke('subscription:fetch', serverId)
  },

  profiles: {
    list: (
      serverId: string,
      access: SshAccessInput
    ): Promise<{ ok: boolean; profiles: ServerProfile[]; error?: string }> =>
      ipcRenderer.invoke('profiles:list', serverId, access),
    create: (
      serverId: string,
      access: SshAccessInput,
      input: ProfileCreateInput
    ): Promise<ProfileCreateResult> =>
      ipcRenderer.invoke('profiles:create', serverId, access, input),
    remove: (
      serverId: string,
      access: SshAccessInput,
      name: string
    ): Promise<ProfileDeleteResult> =>
      ipcRenderer.invoke('profiles:remove', serverId, access, name),
    changeFingerprint: (
      serverId: string,
      access: SshAccessInput,
      input: ProfileFingerprintInput
    ): Promise<ProfileFingerprintResult> =>
      ipcRenderer.invoke('profiles:changeFingerprint', serverId, access, input),
    changeSni: (
      serverId: string,
      access: SshAccessInput,
      input: ProfileSniInput
    ): Promise<ProfileSniResult> =>
      ipcRenderer.invoke('profiles:changeSni', serverId, access, input),
    sniList: (serverId: string, access: SshAccessInput): Promise<SniListResult> =>
      ipcRenderer.invoke('profiles:sniList', serverId, access),
    changePort: (
      serverId: string,
      access: SshAccessInput,
      input: ProfilePortInput
    ): Promise<ProfilePortResult> =>
      ipcRenderer.invoke('profiles:changePort', serverId, access, input)
  },

  server: {
    update: (
      serverId: string,
      access: SshAccessInput
    ): Promise<ServerMaintenanceResult> =>
      ipcRenderer.invoke('server:update', serverId, access),
    uninstall: (serverId: string, access: SshAccessInput): Promise<ServerMaintenanceResult> =>
      ipcRenderer.invoke('server:uninstall', serverId, access)
  }
}

if (process.contextIsolated) {
  try {
    contextBridge.exposeInMainWorld('api', api)
  } catch (error) {
    console.error(error)
  }
} else {
  // @ts-ignore (define in dts)
  window.api = api
}
