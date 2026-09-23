import type { DeployStartPayload, EmailMode, SshAccessInput } from '@shared/types'
import { isSshAccessReady } from '../components/SshAccessForm'

export interface DeployFormState {
  host: string
  port: string
  emailMode: EmailMode
  email: string
}

export function isValidEmailFormat(email: string): boolean {
  return /^[^@\s]+@[^@\s]+\.[^@\s]{2,}$/.test(email.trim()) && !/[\r\n]/.test(email)
}

export function isDeployReady(form: DeployFormState, access: SshAccessInput): boolean {
  if (!form.host.trim()) return false
  if (!isSshAccessReady(access)) return false
  if (form.emailMode === 'provided') return isValidEmailFormat(form.email)
  return true
}

export function buildDeployPayload(
  form: DeployFormState,
  access: SshAccessInput
): Omit<DeployStartPayload, never> {
  const trimmedEmail = form.email.trim()
  return {
    host: form.host.trim(),
    port: Number(form.port) || 22,
    emailMode: form.emailMode,
    ...(form.emailMode === 'provided' ? { email: trimmedEmail } : {}),
    access
  }
}
