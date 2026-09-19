import { describe, expect, it } from 'vitest'
import { isSafeUpdateBranch } from '../../src/main/core/server-manager'

describe('server update branch validation', () => {
  it('принимает закреплённые release/dev ветки', () => {
    expect(isSafeUpdateBranch('dev')).toBe(true)
    expect(isSafeUpdateBranch('release/0.2.0')).toBe(true)
  })

  it('отклоняет shell payload и path traversal', () => {
    expect(isSafeUpdateBranch("dev'; id; #")).toBe(false)
    expect(isSafeUpdateBranch('../main')).toBe(false)
    expect(isSafeUpdateBranch('feature//bad')).toBe(false)
  })
})
