import type {
  DeployStartPayload,
  ElectronAPI,
  ImportResult,
  ImportServerPayload,
  PrivateKeyReference,
  Server,
  ServerDiagnostics
} from '../../src/shared/types'

type Assert<T extends true> = T
type IsRequired<T, K extends keyof T> = {} extends Pick<T, K> ? false : true
type Equal<A, B> = (<T>() => T extends A ? 1 : 2) extends <T>() => T extends B ? 1 : 2
  ? true
  : false

// These aliases fail compilation if onboarding APIs become optional or leak paths.
type EmailModeIsRequired = Assert<IsRequired<DeployStartPayload, 'emailMode'>>
type KeyPickerReturnsReference = Assert<
  Equal<Awaited<ReturnType<ElectronAPI['ssh']['selectPrivateKey']>>, PrivateKeyReference | null>
>
type ImportApiIsExposed = Assert<
  Equal<ElectronAPI['servers']['import'], (payload: ImportServerPayload) => Promise<ImportResult>>
>
type ServerStoresCredentialState = Assert<
  'privateKeyPersisted' extends keyof Server ? true : false
>
type ServerStoresPasswordCredential = Assert<'passwordCredentialId' extends keyof Server ? true : false>

const diagnostics: ServerDiagnostics = {
  manager: 'detected',
  xray: 'running',
  profiles: 'available',
  subscription: 'unreachable',
  inspectedAt: '2026-09-23T00:00:00.000Z'
}

const importPayload: ImportServerPayload = {
  host: '203.0.113.10',
  port: 22,
  access: {
    username: 'root',
    authMethod: 'privateKey',
    privateKeyCredentialId: 'cred-1',
    privilegeMode: 'root'
  }
}

const fixtures: [ServerDiagnostics, ImportServerPayload] = [diagnostics, importPayload]
void fixtures

type OnboardingContractAssertions = [
  EmailModeIsRequired,
  KeyPickerReturnsReference,
  ImportApiIsExposed,
  ServerStoresCredentialState,
  ServerStoresPasswordCredential
]
void (undefined as unknown as OnboardingContractAssertions)
