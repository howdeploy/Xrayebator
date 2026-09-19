export type SshAuthMethod = 'password' | 'privateKey'

export type SshPrivilegeMode = 'root' | 'sudo'

export interface SshAccessInput {
  username: string
  authMethod: SshAuthMethod
  password?: string
  privateKeyPath?: string
  passphrase?: string
  privilegeMode: SshPrivilegeMode
  sudoPassword?: string
}

export interface PrivateKeySelection {
  path: string
  name: string
}

export interface Server {
  id: string
  name: string
  host: string
  port: number
  username: string
  os: string | null
  country: string | null
  city: string | null
  flag: string | null
  createdAt: string
  routesCount: number | null
  subscriptionUrl: string
  keys: VlessLink[]
  authMethod?: SshAuthMethod
  privilegeMode?: SshPrivilegeMode
  privateKeyPath?: string | null
  hostKeyFingerprint?: string | null
}

export interface VlessLink {
  name: string
  url: string
  transport: 'tcp' | 'grpc' | 'xhttp'
}

export interface SubscriptionResult {
  serverId: string
  subscriptionUrl: string
  keys: VlessLink[]
}

export interface ServerProfile {
  name: string
  uuid: string
  transport: string
  port: number
  fingerprint: string
  sni: string
  created: string
  sub_token: string
  multi_route: boolean
  routes: number
  pq_enabled: boolean
  subscription_url: string
}

export interface ProfileCreateInput {
  name: string
  transport: string
  port?: number
  count?: number
}

export interface ProfileCreateResult {
  ok: boolean
  names: string[]
  errors: string[]
}

export interface ProfileDeleteResult {
  ok: boolean
  name?: string
  error?: string
}

export interface ProfileFingerprintInput {
  name: string
  route?: number
  fingerprint: string
}

export interface ProfileFingerprintResult {
  ok: boolean
  name?: string
  fingerprint?: string
  route?: string
  error?: string
}

export interface ProfileSniInput {
  name: string
  route?: number
  sni: string
}

export interface ProfileSniResult {
  ok: boolean
  name?: string
  sni?: string
  port?: number
  transport?: string
  route?: string
  affected?: string[]
  unchanged?: boolean
  reconnect?: boolean
  error?: string
}

export interface ProfilePortInput {
  name: string
  route?: number
  port: number | 'random'
}

export interface ProfilePortResult {
  ok: boolean
  name?: string
  port?: number
  old_port?: number
  transport?: string
  route?: string
  unchanged?: boolean
  reconnect?: boolean
  warning?: string
  firewall_warning?: boolean
  error?: string
}

export interface SniEntry {
  sni: string
  category: string
  priority: string
}

export interface SniListResult {
  ok: boolean
  snis?: SniEntry[]
  error?: string
}

export interface ServerMaintenanceResult {
  ok: boolean
  output?: string
  error?: string
}

export type DeployStep =
  | 'ssh'
  | 'os_check'
  | 'upload'
  | 'install'
  | 'binary'
  | 'quickstart'
  | 'save'

export type DeployStatus = 'pending' | 'running' | 'done' | 'error'

export interface DeployStartPayload {
  host: string
  port: number
  email: string
  access: SshAccessInput
}

export interface DeployDonePayload {
  serverId: string
  subscriptionUrl: string
  keys: VlessLink[]
}

export type DeployEvent =
  | { type: 'step'; step: DeployStep; status: DeployStatus; label: string }
  | { type: 'log'; text: string }
  | { type: 'done'; payload: DeployDonePayload }
  | { type: 'error'; message: string }

export interface ElectronAPI {
  ssh: {
    selectPrivateKey: () => Promise<PrivateKeySelection | null>
  }
  servers: {
    list: () => Promise<Server[]>
    remove: (id: string) => Promise<void>
    get: (id: string) => Promise<Server | null>
    check: (id: string) => Promise<boolean>
    forgetHostKey: (id: string) => Promise<void>
  }
  deploy: {
    start: (payload: DeployStartPayload) => void
    onEvent: (callback: (event: DeployEvent) => void) => () => void
  }
  subscription: {
    fetch: (serverId: string) => Promise<SubscriptionResult>
  }
  profiles: {
    list: (
      serverId: string,
      access: SshAccessInput
    ) => Promise<{ ok: boolean; profiles: ServerProfile[]; error?: string }>
    create: (
      serverId: string,
      access: SshAccessInput,
      input: ProfileCreateInput
    ) => Promise<ProfileCreateResult>
    remove: (
      serverId: string,
      access: SshAccessInput,
      name: string
    ) => Promise<ProfileDeleteResult>
    changeFingerprint: (
      serverId: string,
      access: SshAccessInput,
      input: ProfileFingerprintInput
    ) => Promise<ProfileFingerprintResult>
    changeSni: (
      serverId: string,
      access: SshAccessInput,
      input: ProfileSniInput
    ) => Promise<ProfileSniResult>
    sniList: (serverId: string, access: SshAccessInput) => Promise<SniListResult>
    changePort: (
      serverId: string,
      access: SshAccessInput,
      input: ProfilePortInput
    ) => Promise<ProfilePortResult>
  }
  server: {
    update: (
      serverId: string,
      access: SshAccessInput
    ) => Promise<ServerMaintenanceResult>
    uninstall: (
      serverId: string,
      access: SshAccessInput
    ) => Promise<ServerMaintenanceResult>
  }
}
