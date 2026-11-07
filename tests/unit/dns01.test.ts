import { describe, expect, it } from 'vitest'
import {
  DNS01_PROVIDERS,
  dns01CliArgs,
  dns01SecretFlag,
  dns01SecretPayload,
  isDns01Ready,
  isValidAwsKeyId,
  isValidAwsSecret,
  isValidCloudflareToken,
  isValidDns01Domain,
  maskSecret
} from '../../src/shared/dns01'

describe('DNS-01 validation (mirrors the server)', () => {
  it('accepts a domain and rejects an IP, a bare label or a domain with a path', () => {
    expect(isValidDns01Domain('sub.example.com')).toBe(true)
    expect(isValidDns01Domain('a-b.c-d.example.org')).toBe(true)
    // IP не может получить LE-серт по DNS-01 — сервер отвергает его так же.
    expect(isValidDns01Domain('203.0.113.10')).toBe(false)
    expect(isValidDns01Domain('localhost')).toBe(false)
    expect(isValidDns01Domain('sub.example.com/path')).toBe(false)
    expect(isValidDns01Domain('sub.example.com:8443')).toBe(false)
    expect(isValidDns01Domain('')).toBe(false)
  })

  it('requires a Cloudflare token of at least 20 url-safe chars', () => {
    expect(isValidCloudflareToken('abcdefghijklmnopqrst')).toBe(true)
    expect(isValidCloudflareToken('short')).toBe(false)
    expect(isValidCloudflareToken('has space inside token')).toBe(false)
  })

  it('checks AWS key id and secret shapes', () => {
    expect(isValidAwsKeyId('AKIAIOSFODNN7EXAMPLE')).toBe(true)
    expect(isValidAwsKeyId('akia-lowercase-key')).toBe(false)
    expect(isValidAwsSecret('wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY')).toBe(true)
    expect(isValidAwsSecret('too short')).toBe(false)
  })

  it('is ready only with the credentials of the chosen provider', () => {
    expect(isDns01Ready({ domain: 'sub.example.com', provider: 'cloudflare' })).toBe(false)
    expect(
      isDns01Ready({
        domain: 'sub.example.com',
        provider: 'cloudflare',
        token: 'abcdefghijklmnopqrst'
      })
    ).toBe(true)
    // Токен Cloudflare не заменяет AWS-ключи и наоборот.
    expect(
      isDns01Ready({
        domain: 'sub.example.com',
        provider: 'route53',
        token: 'abcdefghijklmnopqrst'
      })
    ).toBe(false)
    expect(
      isDns01Ready({
        domain: 'sub.example.com',
        provider: 'route53',
        awsKeyId: 'AKIAIOSFODNN7EXAMPLE',
        awsSecret: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'
      })
    ).toBe(true)
  })

  it('lists exactly the providers the server supports', () => {
    expect([...DNS01_PROVIDERS]).toEqual(['cloudflare', 'route53'])
  })
})

describe('DNS-01 CLI arguments', () => {
  it('never puts the cloudflare token into argv', () => {
    // Токен в аргументах виден в /proc/<pid>/cmdline всем локальным пользователям,
    // а серверный выпуск сертификата идёт десятки секунд — поэтому креды уходят
    // отдельным файлом 0600 (dns01SecretPayload + dns01SecretFlag).
    const args = dns01CliArgs({
      domain: ' sub.example.com ',
      provider: 'cloudflare',
      token: 'abcdefghijklmnopqrst'
    })
    expect(args).toEqual(['--domain', 'sub.example.com', '--provider', 'cloudflare'])
    expect(args.join(' ')).not.toContain('abcdefghijklmnopqrst')
  })

  it('passes no AWS credentials in argv either', () => {
    const args = dns01CliArgs({
      domain: 'sub.example.com',
      provider: 'route53',
      token: 'unused-token-value-1234',
      awsKeyId: 'AKIAIOSFODNN7EXAMPLE',
      awsSecret: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'
    })
    expect(args).toEqual(['--domain', 'sub.example.com', '--provider', 'route53'])
    expect(args.join(' ')).not.toContain('AKIA')
    expect(args.join(' ')).not.toContain('wJalrXUtnFEMI')
  })

  it('builds the secret payload the server parses (key=value)', () => {
    expect(
      dns01SecretPayload({ domain: 'sub.example.com', provider: 'cloudflare', token: ' tok-123 ' })
    ).toBe('token=tok-123\n')
    expect(
      dns01SecretPayload({
        domain: 'sub.example.com',
        provider: 'route53',
        awsKeyId: 'AKIAIOSFODNN7EXAMPLE',
        awsSecret: 'wJalrXUtnFEMI/K7MDENG'
      })
    ).toBe('aws_access_key_id=AKIAIOSFODNN7EXAMPLE\naws_secret_access_key=wJalrXUtnFEMI/K7MDENG\n')
  })

  it('names the server flag, including the quickstart prefix', () => {
    expect(dns01SecretFlag()).toBe('--secret-file')
    expect(dns01SecretFlag('--dns01-')).toBe('--dns01-secret-file')
  })

  it('uses the quickstart prefix for deploy-time DNS-01', () => {
    const args = dns01CliArgs(
      { domain: 'sub.example.com', provider: 'cloudflare', token: 'abcdefghijklmnopqrst' },
      '--dns01-'
    )
    expect(args).toEqual(['--dns01-domain', 'sub.example.com', '--dns01-provider', 'cloudflare'])
    expect(args.join(' ')).not.toContain('abcdefghijklmnopqrst')
  })
})

describe('maskSecret', () => {
  it('never returns the full secret', () => {
    const token = 'abcdefghijklmnopqrst'
    const masked = maskSecret(token)
    expect(masked).not.toBe(token)
    expect(masked).toContain('abcd')
    expect(masked).toContain('(20)')
    expect(maskSecret('')).toBe('—')
  })
})
