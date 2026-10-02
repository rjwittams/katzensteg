// Host discovery and the plain-data side of the wm's HTTP API. No I/O here:
// the hooks module reads files and fetches; these functions shape the data.

/** What `katzensteg-wm --headless --background` prints once its HTTP is up. */
export type HostFile = {
  pid: number
  port: number
  token: string
  tty?: string
  socket?: string
  /**
   * The character to draw placeholder cells with, when the host rewrites it
   * into the kitty placeholder on the way to the terminal (a wrapping host).
   * Absent, the host leaves this client's output alone.
   */
  placeholder?: string
  /**
   * The host watches this application's own graphics commands, so a panel may
   * be an image the application draws over the session's claim file.
   */
  imageClaim?: true
}

/**
 * How a panel's cells reach the terminal.
 * - `direct`: the plugin writes the kitty placeholder itself.
 * - `standin`: the plugin writes the host's stand-in and the host rewrites it.
 * - `claim`: the application draws an image over the session's claim file and
 *   the host uploads frames to the id the application chose.
 */
export type Route = 'direct' | 'standin' | 'claim'
export type RouteWish = Route | 'auto'
export const isRouteWish = (v: unknown): v is RouteWish => v === 'auto' || v === 'direct' || v === 'standin' || v === 'claim'

/**
 * The route to draw with: the wish when this host can serve it, else the best
 * the host offers. A host that takes image claims is preferred, since the
 * application then owns the image id and ours cannot clash with its own;
 * next the stand-in, when the host rewrites one; else the placeholder itself.
 */
export function chooseRoute(host: Pick<HostFile, 'placeholder' | 'imageClaim'> | undefined, wish: RouteWish): Route {
  if (wish === 'direct') return 'direct'
  if (wish === 'standin' && host?.placeholder) return 'standin'
  if (host?.imageClaim) return 'claim'
  return host?.placeholder ? 'standin' : 'direct'
}

/**
 * The discovery record names the stand-in as a hex codepoint. Only a
 * private-use codepoint is taken: anything else is not a stand-in.
 */
export function parseStandin(value: unknown): string | undefined {
  if (typeof value !== 'string' || !/^[0-9A-Fa-f]{4,6}$/.test(value)) return undefined
  const cp = Number.parseInt(value, 16)
  const isPrivate = (cp >= 0xe000 && cp <= 0xf8ff) || (cp >= 0xf0000 && cp <= 0xffffd) || (cp >= 0x100000 && cp <= 0x10fffd)
  return isPrivate && cp !== 0x10eeee ? String.fromCodePoint(cp) : undefined
}

export function parseHostFile(text: string): HostFile | null {
  let value: unknown
  try {
    value = JSON.parse(text)
  } catch {
    return null
  }
  if (typeof value !== 'object' || value === null) return null
  const v = value as Record<string, unknown>
  if (!Number.isInteger(v.pid) || !Number.isInteger(v.port) || typeof v.token !== 'string' || v.token === '') return null
  const placeholder = parseStandin(v.placeholder_standin)
  return {
    pid: v.pid as number,
    port: v.port as number,
    token: v.token,
    ...(typeof v.tty === 'string' ? { tty: v.tty } : {}),
    ...(typeof v.socket === 'string' ? { socket: v.socket } : {}),
    ...(placeholder !== undefined ? { placeholder } : {}),
    ...(v.image_claim === true ? { imageClaim: true as const } : {}),
  }
}

export type SessionState = 'starting' | 'ready' | 'closing' | 'exited'
export type Session = {
  id: string
  title: string
  image_id: number
  input_supported: boolean
  state: SessionState
  source_px: { w: number; h: number } | null
  grid: { cols: number; rows: number } | null
  /** A raw RGBA file an application-drawn image points at to claim this session. */
  claim?: { path: string; w: number; h: number }
}

const parseClaim = (value: unknown): Session['claim'] => {
  const c = value as Record<string, unknown> | null | undefined
  if (!c || typeof c.path !== 'string' || !c.path.startsWith('/') || c.path.length > 3072) return undefined
  if (!Number.isInteger(c.w) || !Number.isInteger(c.h) || (c.w as number) < 1 || (c.h as number) < 1 || (c.w as number) > 4096 || (c.h as number) > 4096) return undefined
  return { path: c.path, w: c.w as number, h: c.h as number }
}

const isState = (s: unknown): s is SessionState => s === 'starting' || s === 'ready' || s === 'closing' || s === 'exited'

/** The `/sessions` body as sessions; entries that do not fit are dropped. */
export function parseSessions(text: string): Session[] {
  let value: unknown
  try {
    value = JSON.parse(text)
  } catch {
    return []
  }
  if (!Array.isArray(value)) return []
  const out: Session[] = []
  for (const item of value) {
    if (typeof item !== 'object' || item === null) continue
    const v = item as Record<string, unknown>
    // The wm allocates numeric ids; they are strings here and in URLs.
    const id = typeof v.id === 'string' ? v.id : Number.isInteger(v.id) ? String(v.id) : undefined
    if (id === undefined || !Number.isInteger(v.image_id) || !isState(v.state)) continue
    const px = v.source_px as Record<string, unknown> | null | undefined
    const grid = v.grid as Record<string, unknown> | null | undefined
    const claim = parseClaim(v.claim)
    out.push({
      id,
      title: typeof v.title === 'string' ? v.title : id,
      image_id: v.image_id as number,
      state: v.state,
      input_supported: v.input_supported !== false,
      source_px: px && Number.isFinite(px.w) && Number.isFinite(px.h) ? { w: px.w as number, h: px.h as number } : null,
      grid: grid && Number.isInteger(grid.cols) && Number.isInteger(grid.rows) ? { cols: grid.cols as number, rows: grid.rows as number } : null,
      ...(claim ? { claim } : {}),
    })
  }
  return out
}

/** What `POST /v1/clients` answers: this plugin's client on the host. */
export type HostClient = { id: string; target: string; lease_ms: number }

export function parseClient(text: string): HostClient | null {
  let value: unknown
  try {
    value = JSON.parse(text)
  } catch {
    return null
  }
  const v = value as Record<string, unknown> | null
  const id = typeof v?.id === 'string' ? v.id : Number.isInteger(v?.id) ? String(v?.id) : undefined
  if (id === undefined || typeof v?.target !== 'string' || v.target === '') return null
  const target = v.target.startsWith('jsonl:') ? v.target : `jsonl:${v.target}`
  return { id, target, lease_ms: Number.isInteger(v.lease_ms) ? (v.lease_ms as number) : 120000 }
}

/** `GET /v1/health`: the terminal's cell size in pixels when the host knows it. */
export function parseCellAspect(text: string): number | undefined {
  try {
    const px = (JSON.parse(text) as { cell_px?: { w?: unknown; h?: unknown } | null })?.cell_px
    if (px && typeof px.w === 'number' && typeof px.h === 'number' && px.w > 0 && px.h > 0) return px.w / px.h
  } catch {
    /* no cell size */
  }
  return undefined
}

export type HostEvent = { seq: number; type: string; session?: string }

/** The `/events` body: its events in order, and the highest seq seen. */
export function parseEvents(text: string, since: number): { events: HostEvent[]; seq: number } {
  let value: unknown
  try {
    value = JSON.parse(text)
  } catch {
    return { events: [], seq: since }
  }
  const list = (value as { events?: unknown })?.events
  if (!Array.isArray(list)) return { events: [], seq: since }
  const events: HostEvent[] = []
  let seq = since
  for (const item of list) {
    const v = item as Record<string, unknown>
    if (!Number.isInteger(v?.seq) || typeof v.type !== 'string') continue
    events.push({ seq: v.seq as number, type: v.type, ...(typeof v.session === 'string' ? { session: v.session } : {}) })
    if ((v.seq as number) > seq) seq = v.seq as number
  }
  return { events, seq }
}

export type InputEvent =
  | { n: number; type: 'key'; key: string; ctrl?: true; shift?: true; meta?: true }
  | { n: number; type: 'pointer'; kind: 'down' | 'move' | 'up'; x: number; y: number; button?: 'left' | 'middle' | 'right' }
  | { n: number; type: 'close' }
  | { n: number; type: 'resize'; cols: number; rows: number; axis: 'resize-x' | 'resize-y' | 'resize-xy' }
  | { n: number; type: 'resizeend' }
  | { n: number; type: 'drag'; dx: number; dy: number }
  | { n: number; type: 'dragend' }

/** Events the plugin acts on itself; everything else goes to the host. */
export const isPanelEvent = (ev: InputEvent): boolean => ev.type !== 'key' && ev.type !== 'pointer'

/**
 * A panel posts its recent events every frame, numbered; the hooks module
 * forwards only the ones after the last number it sent.
 */
export function newInputEvents(posted: unknown, lastN: number): { events: InputEvent[]; lastN: number } {
  if (!Array.isArray(posted)) return { events: [], lastN }
  const events: InputEvent[] = []
  let max = lastN
  for (const item of posted) {
    const v = item as InputEvent
    if (!Number.isInteger(v?.n) || v.n <= lastN) continue
    if (!['key', 'pointer', 'close', 'resize', 'resizeend', 'drag', 'dragend'].includes(v.type)) continue
    events.push(v)
    if (v.n > max) max = v.n
  }
  events.sort((a, b) => a.n - b.n)
  return { events, lastN: max }
}

/**
 * The number to forward after, for a batch from panel instance `inst`: the
 * last one sent while it is the same instance, zero for a new one, whose
 * numbering started over.
 */
export const inputSince = (previousInst: unknown, inst: unknown, lastN: number): number =>
  inst !== undefined && inst !== previousInst ? 0 : lastN

/** The wire form of input events: the numbering is the panel's, not the wm's. */
export const stripNumbers = (events: InputEvent[]): Omit<InputEvent, 'n'>[] =>
  events.map(({ n: _n, ...rest }) => rest)
