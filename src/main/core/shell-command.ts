/** POSIX-safe quoting for one shell argument. */
export function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'"'"'`)}'`
}

/** Builds a command where every argument, including argv[0], is quoted. */
export function shellCommand(executable: string, args: readonly string[] = []): string {
  return [executable, ...args].map(shellQuote).join(' ')
}
