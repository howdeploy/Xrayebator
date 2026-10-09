import { contextBridge, ipcRenderer } from 'electron'
import type {
  AwgConfResult,
  BackendGrantResult,
  BackendSimpleResult,
  BackendStatusResult,
  BackendToggleResult,
  DeployEvent,
  Hysteria2LinkResult,
  Hysteria2SubbodyResult,
  DeployStartPayload,
  ElectronAPI,
  ImportProgressEvent,
  PrivateKeyReference,
  ImportResult,
  ImportServerPayload,
  ProfileCreateInput,
  ProfileCreateResult,
  ProfileDeleteResult,
  ProfileExpireInput,
  ProfileExpireResult,
  ProfileFingerprintInput,
  ProfileFingerprintResult,
  ProfilePortInput,
  ProfilePortResult,
  ProfileRevokeInput,
  ProfileRevokeResult,
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
    selectPrivateKey: (): Promise<PrivateKeyReference | null> =>
      ipcRenderer.invoke('ssh:selectPrivateKey')
  },

  servers: {
    list: (): Promise<Server[]> => ipcRenderer.invoke('servers:list'),
    import: (payload: ImportServerPayload): Promise<ImportResult> =>
      ipcRenderer.invoke('servers:import', payload),
    onImportEvent: (callback: (event: ImportProgressEvent) => void): (() => void) => {
      const listener = (_e: Electron.IpcRendererEvent, event: ImportProgressEvent): void =>
        callback(event)
      ipcRenderer.on('servers:importEvent', listener)
      return () => ipcRenderer.removeListener('servers:importEvent', listener)
    },
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
      ipcRenderer.invoke('profiles:changePort', serverId, access, input),
    revoke: (
      serverId: string,
      access: SshAccessInput,
      input: ProfileRevokeInput
    ): Promise<ProfileRevokeResult> =>
      ipcRenderer.invoke('profiles:revoke', serverId, access, input),
    setExpire: (
      serverId: string,
      access: SshAccessInput,
      input: ProfileExpireInput
    ): Promise<ProfileExpireResult> =>
      ipcRenderer.invoke('profiles:setExpire', serverId, access, input)
  },

  backends: {
    status: (serverId: string, access: SshAccessInput): Promise<BackendStatusResult> =>
      ipcRenderer.invoke('backends:status', serverId, access),
    hysteria2Grant: (
      serverId: string,
      access: SshAccessInput,
      name: string
    ): Promise<BackendGrantResult> =>
      ipcRenderer.invoke('backends:hysteria2Grant', serverId, access, name),
    hysteria2Install: (
      serverId: string,
      access: SshAccessInput,
      grantAll: boolean
    ): Promise<BackendSimpleResult> =>
      ipcRenderer.invoke('backends:hysteria2Install', serverId, access, grantAll),
    hysteria2Uninstall: (
      serverId: string,
      access: SshAccessInput
    ): Promise<BackendSimpleResult> =>
      ipcRenderer.invoke('backends:hysteria2Uninstall', serverId, access),
    hysteria2Subbody: (
      serverId: string,
      access: SshAccessInput,
      on: boolean
    ): Promise<Hysteria2SubbodyResult> =>
      ipcRenderer.invoke('backends:hysteria2Subbody', serverId, access, on),
    hysteria2Link: (
      serverId: string,
      access: SshAccessInput,
      name: string
    ): Promise<Hysteria2LinkResult> =>
      ipcRenderer.invoke('backends:hysteria2Link', serverId, access, name),
    awgGrant: (
      serverId: string,
      access: SshAccessInput,
      name: string
    ): Promise<BackendGrantResult> =>
      ipcRenderer.invoke('backends:awgGrant', serverId, access, name),
    awgInstall: (
      serverId: string,
      access: SshAccessInput,
      grantAll: boolean
    ): Promise<BackendSimpleResult> =>
      ipcRenderer.invoke('backends:awgInstall', serverId, access, grantAll),
    awgUninstall: (serverId: string, access: SshAccessInput): Promise<BackendSimpleResult> =>
      ipcRenderer.invoke('backends:awgUninstall', serverId, access),
    awgConf: (serverId: string, access: SshAccessInput, name: string): Promise<AwgConfResult> =>
      ipcRenderer.invoke('backends:awgConf', serverId, access, name),
    awg31: (serverId: string, access: SshAccessInput, on: boolean): Promise<BackendToggleResult> =>
      ipcRenderer.invoke('backends:awg31', serverId, access, on)
  },

  server: {
    update: (
      serverId: string,
      access: SshAccessInput,
      branch?: string
    ): Promise<ServerMaintenanceResult> =>
      ipcRenderer.invoke('server:update', serverId, access, branch),
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
