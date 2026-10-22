/**
 * Утилиты разбора клиентского конфига AmneziaWG для GUI.
 * GUI показывает конфиг как структурированный «ключ» (Endpoint/Адрес),
 * а не простыню текста; полный текст нужен для QR и копирования.
 */

/** Убирает комментарии-шапку и нормализует CRLF — часть приложений спотыкается о строки до [Interface]. */
export function stripAwgComments(conf: string): string {
  return conf
    .replace(/\r\n/g, '\n')
    .split('\n')
    .filter((line) => !line.trim().startsWith('#'))
    .join('\n')
    .trim()
}

export interface AwgClientKeyFields {
  /** Endpoint = host:port из секции [Peer]. */
  endpoint: string
  /** Address = 10.8.1.x/32 клиента. */
  address: string
}

export function parseAwgClientConf(conf: string): AwgClientKeyFields {
  const endpoint = conf.match(/^Endpoint\s*=\s*(.+)$/m)?.[1]?.trim() ?? ''
  const address = conf.match(/^Address\s*=\s*(.+)$/m)?.[1]?.trim() ?? ''
  return { endpoint, address }
}

/**
 * Карта key=value из клиентского .conf (заголовки секций пропускаются,
 * значения тримятся) — зеркало парсера importController в AmneziaVPN.
 */
export function parseAwgConfMap(conf: string): Record<string, string> {
  const map: Record<string, string> = {}
  for (const raw of conf.split('\n')) {
    const line = raw.trim()
    if (line.startsWith('[') && line.endsWith(']')) continue
    const idx = line.indexOf('=')
    if (idx > 0) map[line.slice(0, idx).trim()] = line.slice(idx + 1).trim()
  }
  return map
}

/** AWG-ключи, которые импортёр AmneziaVPN переносит в last_config (awgProtocolKeys). */
const AWG_PROTOCOL_KEYS = [
  'Jc',
  'Jmin',
  'Jmax',
  'S1',
  'S2',
  'S3',
  'S4',
  'H1',
  'H2',
  'H3',
  'H4',
  'I1',
  'I2',
  'I3',
  'I4',
  'I5',
  'HeaderProtectionKey',
  'ContentPaddingAddition',
  'RandomTrailers',
  'DisableCookies',
] as const

/**
 * Версия протокола в vpn:// — всегда 3.1: Xrayebator ставит 3.1 по умолчанию
 * и выдаёт ключи только в этом режиме (значение из protocolConstants Amnezia).
 */
const AWG_PROTOCOL_VERSION = '3.1'

/**
 * Строит JSON-объект в родном для AmneziaVPN формате — 1-в-1 с их экспортом
 * docker-сервера (AwgProtocolConfig::toJson): серверные junk-поля на уровне
 * объекта "awg", range-таймеры и ContentPaddingAddition (это параметры их
 * go-туннеля, не kernel), last_config с полным клиентским набором включая
 * client_pub_key/clientId. Контейнер — "amnezia-awg2".
 */
export function buildAwgVpnConfig(
  conf: string,
  description?: string,
  opts?: { clientPubKey?: string; mtu?: string }
): Record<string, unknown> {
  const map = parseAwgConfMap(stripAwgComments(conf))
  const endpoint = map['Endpoint'] ?? ''
  const [host = '', port = ''] = endpoint.split(':')
  const version = AWG_PROTOCOL_VERSION
  const clientIp = (map['Address'] ?? '').split('/')[0]

  const clientPub = opts?.clientPubKey ?? ''
  const lastConfig: Record<string, unknown> = {
    config: stripAwgComments(conf),
    hostName: host,
    port: Number(port) || 51820,
    client_ip: clientIp,
  }
  if (map['PrivateKey']) lastConfig['client_priv_key'] = map['PrivateKey']
  if (clientPub) {
    lastConfig['client_pub_key'] = clientPub
    lastConfig['clientId'] = clientPub
  }
  const psk = map['PresharedKey'] ?? map['PreSharedKey']
  if (psk) lastConfig['psk_key'] = psk
  if (map['PublicKey']) lastConfig['server_pub_key'] = map['PublicKey']
  if (map['AllowedIPs']) {
    lastConfig['allowed_ips'] = map['AllowedIPs']
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean)
  }
  // junk + 3.x параметры — зеркально в last_config (как в их экспорте)
  for (const key of AWG_PROTOCOL_KEYS) {
    if (key === 'RandomTrailers') lastConfig[key] = map[key] ?? 'on'
    else if (map[key]) lastConfig[key] = map[key]
  }
  // range-таймеры go-туннеля — дефолты Amnezia (параметры их туннеля, не wire-формат)
  lastConfig['persistent_keep_alive'] = map['PersistentKeepalive'] ?? '25'
  lastConfig['RekeyAfterTime'] = '100-120'
  lastConfig['RekeyTimeout'] = '3-7'
  lastConfig['RejectAfterTime'] = '150-180'
  lastConfig['KeepaliveTimeout'] = '5-15'
  lastConfig['MaxHandshakeAttempts'] = '15-20'
  lastConfig['ContentPaddingAddition'] = '10-100'
  lastConfig['mtu'] = opts?.mtu ?? map['MTU'] ?? '1280'
  lastConfig['protocol_version'] = version

  // серверный уровень "awg" — тот же набор junk + subnet_address (как в экспорте)
  const serverLevel: Record<string, unknown> = {
    port,
    transport_proto: 'udp',
    protocol_version: version,
    Jc: map['Jc'] ?? '',
    Jmin: map['Jmin'] ?? '',
    Jmax: map['Jmax'] ?? '',
    S1: map['S1'] ?? '',
    S2: map['S2'] ?? '',
  }
  for (const key of ['S3', 'S4', 'H1', 'H2', 'H3', 'H4'] as const) {
    if (map[key]) serverLevel[key] = map[key]
  }
  for (const key of ['I1', 'I2', 'I3', 'I4', 'I5'] as const) {
    serverLevel[key] = map[key] ?? ''
  }
  if (map['HeaderProtectionKey']) serverLevel['HeaderProtectionKey'] = map['HeaderProtectionKey']
  if (map['RandomTrailers']) serverLevel['RandomTrailers'] = map['RandomTrailers']
  if (map['DisableCookies']) serverLevel['DisableCookies'] = map['DisableCookies']
  serverLevel['RekeyAfterTime'] = '100-120'
  serverLevel['RekeyTimeout'] = '3-7'
  serverLevel['RejectAfterTime'] = '150-180'
  serverLevel['KeepaliveTimeout'] = '5-15'
  serverLevel['MaxHandshakeAttempts'] = '15-20'
  serverLevel['ContentPaddingAddition'] = '10-100'
  serverLevel['subnet_address'] = '10.8.1.0'
  serverLevel['isThirdPartyConfig'] = true
  serverLevel['last_config'] = JSON.stringify(lastConfig)

  const container: Record<string, unknown> = {
    container: 'amnezia-awg2',
    awg: serverLevel,
  }

  const root: Record<string, unknown> = {
    containers: [container],
    defaultContainer: 'amnezia-awg2',
    description: description ?? 'AmneziaWG',
    hostName: host,
  }
  const dns = (map['DNS'] ?? '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean)
  if (dns[0]) root['dns1'] = dns[0]
  if (dns[1]) root['dns2'] = dns[1]
  return root
}

/**
 * qCompress в форме AmneziaVPN: 4 байта BE-размера + zlib-поток.
 * CompressionStream('deflate') — тот же zlib-контейнер (RFC 1950), что
 * создаёт их Qt-экспорт; доступен в Electron-renderer и Node 18+.
 */
async function qCompressBase64Url(json: string): Promise<string> {
  const bytes = new TextEncoder().encode(json)
  const head = new Uint8Array(4)
  new DataView(head.buffer).setUint32(0, bytes.length)
  const body = new Uint8Array(
    await new Response(
      new Blob([bytes]).stream().pipeThrough(new CompressionStream('deflate'))
    ).arrayBuffer()
  )
  const payload = new Uint8Array(4 + body.length)
  payload.set(head, 0)
  payload.set(body, 4)
  let bin = ''
  for (const b of payload) bin += String.fromCharCode(b)
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

/**
 * Родная ссылка-импорт для AmneziaVPN: vpn:// + base64url(qCompress(JSON)) —
 * ровно та же форма, что их собственный «Поделиться».
 */
export async function buildAwgVpnUrl(
  conf: string,
  description?: string,
  opts?: { clientPubKey?: string; mtu?: string }
): Promise<string> {
  const json = JSON.stringify(buildAwgVpnConfig(conf, description, opts))
  return 'vpn://' + (await qCompressBase64Url(json))
}
