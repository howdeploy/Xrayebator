import { spawnSync } from 'node:child_process'
import { describe, expect, it } from 'vitest'
import { shellCommand, shellQuote } from '../../src/main/core/shell-command'
import { buildSudoCommand } from '../../src/main/core/ssh-client'

describe('shell command escaping', () => {
  it('передаёт shell metacharacters как один argv без выполнения второй команды', () => {
    const value = `name'; printf 'SECOND_COMMAND'; # $(uname) \`id\``
    const command = shellCommand('printf', ['%s', value])
    const result = spawnSync('/bin/sh', ['-c', command], { encoding: 'utf8' })

    expect(result.status).toBe(0)
    expect(result.stdout).toBe(value)
    expect(result.stderr).toBe('')
  })

  it('экранирует одинарную кавычку POSIX-последовательностью', () => {
    expect(shellQuote("a'b")).toBe("'a'\"'\"'b'")
  })

  it('не помещает sudo-пароль в командную строку', () => {
    const command = buildSudoCommand(shellCommand('printf', ['%s', "a'; id; #"]), true)
    expect(command).toContain('read -r XRAYEBATOR_SUDO_PASSWORD')
    expect(command).toContain("sudo -S -p '' -- sh -c")
    expect(command).toContain('exec </dev/null')
    expect(command).not.toContain('sudo-secret')
    expect(command).toContain("'\"'\"'")
  })
})
