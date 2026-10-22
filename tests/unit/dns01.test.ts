import { describe, expect, it } from 'vitest'
import {
  DNS01_PROVIDERS,
  dns01CliArgs,
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
  it('passes --domain/--provider/--token for cloudflare', () => {
    expect(
      dns01CliArgs({
        domain: ' sub.example.com ',
        provider: 'cloudflare',
        token: 'abcdefghijklmnopqrst'
      })
    ).toEqual([
      '--domain',
      'sub.example.com',
      '--provider',
      'cloudflare',
      '--token',
      'abcdefghijklmnopqrst'
    ])
  })

  it('passes AWS credentials for route53 and never a cloudflare token', () => {
    const args = dns01CliArgs({
      domain: 'sub.example.com',
      provider: 'route53',
      token: 'unused-token-value-1234',
      awsKeyId: 'AKIAIOSFODNN7EXAMPLE',
      awsSecret: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'
    })
    expect(args).toEqual([
      '--domain',
      'sub.example.com',
      '--provider',
      'route53',
      '--aws-access-key-id',
      'AKIAIOSFODNN7EXAMPLE',
      '--aws-secret-access-key',
      'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'
    ])
    expect(args.join(' ')).not.toContain('unused-token-value')
  })

  it('uses the quickstart prefix for deploy-time DNS-01', () => {
    expect(
      dns01CliArgs(
        { domain: 'sub.example.com', provider: 'cloudflare', token: 'abcdefghijklmnopqrst' },
        '--dns01-'
      )
    ).toEqual([
      '--dns01-domain',
      'sub.example.com',
      '--dns01-provider',
      'cloudflare',
      '--dns01-token',
      'abcdefghijklmnopqrst'
    ])
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
