export type SshAuthMethod = 'password' | 'privateKey'

export type SshPrivilegeMode = 'root' | 'sudo'

export type EmailMode = 'provided' | 'without'

export type ServerSetupStatus = 'ready' | 'partial' | 'unknown'

export type DiagnosticState = 'detected' | 'missing' | 'invalid' | 'unknown'

export type XrayState = 'running' | 'stopped' | 'missing' | 'unknown'

export type ProfilesState = 'available' | 'empty' | 'missing' | 'unknown'

/**
 * Состояние подписки с сервера (inspect/normalize):
 * public — HTTPS endpoint работает; fallback — http_tls-режим (endpoint с
 * server'а работает, из интернета может быть недоступен: hoster-фильтр :80);
 * localOnly — только 127.0.0.1; missing/unreachable — проблемные.
 */
export type SubscriptionState =
  | 'public'
  | 'fallback'
  | 'localOnly'
  | 'missing'
  | 'unreachable'
  | 'unknown'

export interface PrivateKeyReference {
  credentialId: string
  name: string
  persisted?: boolean
}

export interface ServerDiagnostics {
  manager: DiagnosticState
  xray: XrayState
  profiles: ProfilesState
  subscription: SubscriptionState
  inspectedAt: string
}

export interface InspectionSnapshot {
  ok: boolean
  recognized: boolean
  os: string | null
  manager: DiagnosticState
  xray: XrayState
  profiles: ProfilesState
  profile_count: number
  route_count: number
  subscription_installed: boolean
  subscription_mode: string | null
  subscription_domain: string | null
  subscription_port: number | null
  subscription_service?: string | null
  subscription_url: string | null
  country: string | null
  city: string | null
  flag: string | null
  error?: string
}

export interface ImportServerPayload {
  host: string
  port: number
  access: SshAccessInput
}

export interface ImportResult {
  serverId: string
  diagnostics: ServerDiagnostics
  keys: VlessLink[]
}

export interface SshAccessInput {
  username: string
  authMethod: SshAuthMethod
  password?: string
  passwordCredentialId?: string
  passwordPersisted?: boolean
  privateKeyPath?: string
  privateKeyCredentialId?: string
  privateKeyName?: string
  /** true — ключ в системном keychain; false — только выбранный файл в текущей сессии. */
  privateKeyPersisted?: boolean
  passphrase?: string
  privilegeMode: SshPrivilegeMode
  sudoPassword?: string
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
  /**
   * Мультипротокольный этап: hysteria2-ссылки из тела подписки — персистятся
   * вместе с vless-ключами, чтобы страница «Ключи» открывалась мгновенно.
   */
  hysteria2Keys?: string[]
  /** Кэш клиентских .conf AWG per-profile (имя профиля → конфиг). */
  awgConfs?: Record<string, string>
  authMethod?: SshAuthMethod
  privilegeMode?: SshPrivilegeMode
  privateKeyPath?: string | null
  privateKeyName?: string | null
  privateKeyCredentialId?: string | null
  privateKeyPersisted?: boolean | null
  passwordCredentialId?: string | null
  passwordPersisted?: boolean | null
  setupStatus?: ServerSetupStatus
  diagnostics?: ServerDiagnostics | null
  hostKeyFingerprint?: string | null
  /**
   * http_tls-fallback (quickstart при hoster-блокировке http-01): подписка
   * работает с server'а, но публичного HTTPS нет. Карточка помечается
   * «Настроен частично», Keys грузит ключи по SSH.
   */
  degraded?: boolean
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
  /** Строки hysteria2:// из тела подписки (UDP-бэкенд). */
  hysteria2Links?: string[]
}

/** Грант Hysteria 2 в профиле (username = имя профиля, password = 32 hex). */
export interface ProfileHysteria2Grant {
  username: string
  password: string
  created?: string
}

/** Грант AmneziaWG peer-а в профиле (адрес 10.8.1.x, full-tunnel клиент). */
export interface ProfileAwgGrant {
  client_private_key: string
  client_public_key: string
  preshared_key: string
  address: string
  created?: string
}

/**
 * Аддитивный объект бэкенд-грантов в профиле. Профиль — единственный источник
 * правды: revoke/expire на сервере синхронно меняют эти креденшелы.
 * Пометка для UI: AWG-грант работает через клиент AmneziaVPN, НЕ через V2Ray/HAPP.
 */
export interface ProfileBackends {
  hysteria2?: ProfileHysteria2Grant
  awg?: ProfileAwgGrant
}

/** Запись одного бэкенда в реестре сервера (backend-status). */
export interface BackendEntry {
  installed: boolean
  /** active | inactive | unknown (unknown — юнит не задан). */
  state: string
  version?: string
  port?: number
  unit?: string
  /** Hysteria 2: le | selfsigned. */
  tls_mode?: string
  sni?: string
  masquerade?: string
  /** Hysteria 2: строки hysteria2:// в телах подписки (kill-switch). */
  sub_body?: boolean
  /** AWG 3.1: HeaderProtectionKey + RandomTrailers. */
  three_enabled?: boolean
  /** AWG 3.1: локальный флаг отключения cookie-механизма. */
  disable_cookies?: boolean
  subnet?: string
}

export interface BackendStatusResult {
  ok: boolean
  backends: Record<string, BackendEntry>
  error?: string
}

export interface BackendGrantResult {
  ok: boolean
  name?: string
  error?: string
}

/** Результат install/uninstall бэкенда (rc=2 воркера → already). */
export interface BackendSimpleResult {
  ok: boolean
  already?: boolean
  error?: string
}

export interface Hysteria2SubbodyResult {
  ok: boolean
  sub_body?: boolean
  error?: string
}

export interface Hysteria2LinkResult {
  ok: boolean
  name?: string
  /** hysteria2://user:pass@host:port/?sni=…&insecure=…#🇩🇪 Country · name */
  link?: string
  error?: string
}

export interface AwgConfResult {
  ok: boolean
  name?: string
  /** Полный текст клиентского .conf (секреты уровня оператора). */
  conf?: string
  error?: string
}

export interface BackendToggleResult {
  ok: boolean
  three_enabled?: boolean
  disable_cookies?: boolean
  error?: string
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
  /** epoch-секунды истечения; 0 = бессрочный. Принуждается серверным таймером. */
  expire: number
  /** Календарная дата истечения в локальной временной зоне сервера (YYYY-MM-DD). */
  expire_date?: string
  /** true — профиль сейчас отключён по сроку (клиент снят с inbound'ов). */
  expire_disabled: boolean
  /**
   * false — сервер старой версии и вообще не отдаёт expire (поля нет в JSON).
   * Отличает «профиль бессрочный» от «сервер не умеет сроки»: иначе GUI
   * показывал бы бессрочность там, где управление сроком недоступно.
   */
  expire_supported?: boolean
  /**
   * Мультипротокольный этап: гранты опциональных бэкендов. Пустой объект или
   * отсутствие поля — профиль не имеет доступа к hysteria2/awg.
   */
  backends?: ProfileBackends
}

export interface ProfileCreateInput {
  name: string
  transport: string
  port?: number
  count?: number
  /** ISO-дата 'ГГГГ-ММ-ДД' или epoch-секунды; undefined = бессрочный. */
  expire?: string
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

export interface ProfileRevokeInput {
  name: string
  /** true — новый uuid тоже (старые клиенты отваливаются немедленно). */
  full: boolean
}

export interface ProfileRevokeResult {
  ok: boolean
  name?: string
  full?: boolean
  sub_token?: string
  uuid?: string
  subscription_url?: string
  error?: string
}

export interface ProfileExpireInput {
  name: string
  /** ISO 'ГГГГ-ММ-ДД' или epoch-секунды; null/undefined → 'none' (снять срок). */
  expire: string | number | null
}

export interface ProfileExpireResult {
  ok: boolean
  name?: string
  expire?: number
  expired?: boolean
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

/** Фазы read-only импорта: main process шлёт шаг только при реальном входе в фазу. */
export type ImportStep = 'ssh' | 'inspect' | 'subscription' | 'save'

/** Событие импорта: переход фазы либо строка консоли (секреты уже замаскированы в main). */
export type ImportProgressEvent = { step: ImportStep } | { log: string }

export interface DeployStartPayload {
  host: string
  port: number
  emailMode: EmailMode
  email?: string
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
    selectPrivateKey: () => Promise<PrivateKeyReference | null>
  }
  servers: {
    list: () => Promise<Server[]>
    import: (payload: ImportServerPayload) => Promise<ImportResult>
    onImportEvent: (callback: (event: ImportProgressEvent) => void) => () => void
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
    revoke: (
      serverId: string,
      access: SshAccessInput,
      input: ProfileRevokeInput
    ) => Promise<ProfileRevokeResult>
    setExpire: (
      serverId: string,
      access: SshAccessInput,
      input: ProfileExpireInput
    ) => Promise<ProfileExpireResult>
  }
  server: {
    /**
     * Обновить менеджер на сервере. Без branch — закреплённая на сервере ветка
     * (.current_branch) или main. Явная ветка (main | dev | experimental) —
     * управляемая бета: обновиться с dev, не дожидаясь вливания в main.
     */
    update: (
      serverId: string,
      access: SshAccessInput,
      branch?: 'main' | 'dev' | 'experimental'
    ) => Promise<ServerMaintenanceResult>
    uninstall: (
      serverId: string,
      access: SshAccessInput
    ) => Promise<ServerMaintenanceResult>
  }
  backends: {
    /** Статус всех бэкендов из реестра сервера (backend-status). */
    status: (
      serverId: string,
      access: SshAccessInput
    ) => Promise<BackendStatusResult>
    hysteria2Grant: (
      serverId: string,
      access: SshAccessInput,
      name: string
    ) => Promise<BackendGrantResult>
    /** Установка Hysteria 2 (длинная операция). */
    hysteria2Install: (
      serverId: string,
      access: SshAccessInput,
      grantAll: boolean
    ) => Promise<BackendSimpleResult>
    hysteria2Uninstall: (
      serverId: string,
      access: SshAccessInput
    ) => Promise<BackendSimpleResult>
    /** Kill-switch hysteria2-строк в подписке. */
    hysteria2Subbody: (
      serverId: string,
      access: SshAccessInput,
      on: boolean
    ) => Promise<Hysteria2SubbodyResult>
    /** hysteria2:// ссылка профиля (требует грант и установленный бэкенд). */
    hysteria2Link: (
      serverId: string,
      access: SshAccessInput,
      name: string
    ) => Promise<Hysteria2LinkResult>
    awgGrant: (
      serverId: string,
      access: SshAccessInput,
      name: string
    ) => Promise<BackendGrantResult>
    /** Установка AmneziaWG (может собирать kernel-модуль — минуты). */
    awgInstall: (
      serverId: string,
      access: SshAccessInput,
      grantAll: boolean
    ) => Promise<BackendSimpleResult>
    awgUninstall: (
      serverId: string,
      access: SshAccessInput
    ) => Promise<BackendSimpleResult>
    /** Клиентский .conf AWG peer-а для профиля ( AmneziaVPN, не V2Ray/HAPP ). */
    awgConf: (
      serverId: string,
      access: SshAccessInput,
      name: string
    ) => Promise<AwgConfResult>
    /** Тумблер AWG 3.1: включение/выключение требует перекачки .conf клиентов. */
    awg31: (
      serverId: string,
      access: SshAccessInput,
      on: boolean
    ) => Promise<BackendToggleResult>
  }
}
