export function vlessPort(rawUrl: string): number {
  try {
    const url = new URL(rawUrl)
    if (url.protocol !== 'vless:') return 443
    const port = Number(url.port || 443)
    return Number.isInteger(port) && port >= 1 && port <= 65535 ? port : 443
  } catch {
    return 443
  }
}
