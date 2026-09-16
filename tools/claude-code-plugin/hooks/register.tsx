/* @jsx h */
import type { Elements, EngineInterface, Register, RenderChildren, RenderElement } from 'claude-code'
import { fitGrid, type Grid } from './placeholders.ts'
import {
  isPanelEvent, newInputEvents, parseCellAspect, parseClient, parseHostFile, parseSessions, stripNumbers,
  type HostClient, type HostFile, type Session,
} from './host.ts'
import { ordered, swapOnDrag } from './layout.ts'

// Katzensteg for Claude Code. A headless katzensteg-wm owns the producers,
// image ids and the graphics writes to this terminal; this module starts or
// finds it, registers as one of its clients, draws one panel per session in
// the band above the prompt, sizes each panel's placeholder grid, and relays
// the panels' input. The terminal composes each producer's image into its
// panel's cells. Contract: docs/launcher.md (Headless placeholder host).
//
// KATZENSTEG_HOST_BIN overrides the host binary; KATZENSTEG_REPO locates
// zig-out when the checkout is not ~/dev/katzensteg.

type $ = EngineInterface

let host: HostFile | undefined
let client: HostClient | undefined
let hostBin = ''
let parentPid = ''
let hostError: string | undefined
let cellAspect = 0.5
let cellPx: { w: number; h: number } | undefined
// The band as last rendered, for sizing a page viewer before it opens.
let band = { columns: 100, rows: 16 }
let siteMeasured = false
let sessions: Session[] = []
let listing = ''
let polling = false
let hidden = new Set<string>()
// Which Claude Code site holds the panels: the band above the prompt, or a
// pane (docked beside the transcript in fullscreen from 110 columns, else
// seated inline). One pane, id PANE_ID, carries every panel; groups as
// separate panes (the engine draws them as tabs) can follow.
const PANE_ID = 'katzensteg'
type Place = 'band' | 'pane'
let place: Place = 'pane'
let paneOpen = false
let lastPlacement: string | undefined
let drawnCount = -1
// Panel height presets in rows; the band's own limit still applies.
const SIZES = { small: 10, medium: 16, large: 40 } as const
type SizeName = keyof typeof SIZES
let size: SizeName = 'medium'
const sentGrid = new Map<string, Grid>()
// Grids the host has acknowledged: input before that is refused (GridRequired),
// so it is dropped rather than sent.
const gridReady = new Set<string>()
// Diagnostics for /katzensteg host: the last event types each panel posted.
const lastTypes = new Map<string, string[]>()
// Band layout the person shaped by dragging: order, and a size per panel that
// replaces the preset. A resize in progress holds the grid post until release.
let order: string[] = []
const sizeOverride = new Map<string, { cols: number; rows: number }>()
const resizing = new Set<string>()
const lastWidths = new Map<string, number>()
const lastHeights = new Map<string, number>()
// Stacked (docked pane), panels reorder by vertical drag against heights.
let lastStacked = false
// Where each panel sits in the band body, as the last render laid it out:
// the wheel over a panel is forwarded to its game instead of scrolling the band.
const placed = new Map<string, { col: number; row: number; cols: number; rows: number }>()
const lastN = new Map<string, number>()
let forwarded = 0
let shown = 0

const log = ($: $, text: string) => $.ui.log(`katzensteg: ${text}`)

type Reply = { ok: boolean; status: number; text: string }

async function api($: $, path: string, body?: unknown): Promise<Reply> {
  if (!host) throw new Error('no host')
  const r = await $.http.fetch(`http://127.0.0.1:${host.port}/v1${path}`, {
    method: body === undefined ? 'GET' : 'POST',
    headers: {
      authorization: `Bearer ${host.token}`,
      'content-type': 'application/json',
      ...(client && { 'x-katzensteg-client': client.id }),
    },
    ...(body !== undefined && { body: JSON.stringify(body) }),
  })
  return { ok: r.ok, status: r.status, text: r.text }
}

const failure = (r: Reply | undefined, what: string) => (r ? `${what} ${r.status}: ${r.text.slice(0, 120)}` : `${what} failed`)

// `--background` starts a host for this terminal or answers for the running
// one, printing its discovery record once HTTP is up. The child inherits the
// terminal, so the host opens it itself before detaching.
async function discover($: $): Promise<HostFile | undefined> {
  // Name the terminal explicitly. A `$.process.run` child has a controlling
  // terminal, which `ps` reports as its real device (ttys007, pts/3); the
  // host must open that path, since /dev/tty stops resolving once it detaches.
  const tty = await $.process.run(['sh', '-c', 'ps -o tty= -p $$'], { timeoutMs: 3000 }).catch(() => undefined)
  const name = tty?.exitCode === 0 ? tty.stdout.trim() : ''
  const device = /^(ttys\d+|pts\/\d+|tty[A-Za-z0-9]+)$/.test(name) && name !== '??' ? [`--tty`, `/dev/${name}`] : []
  // Claude Code's own pid: the host watches it and closes this client's
  // producers when it exits, since a plugin gets no hook on the way out.
  parentPid = (await $.env.get('CLAUDE_PID')) ?? ''
  const parent = /^\d+$/.test(parentPid) ? ['--parent-pid', parentPid] : []
  const r = await $.process.run([hostBin, '--headless', '--background', ...device, ...parent], { timeoutMs: 8000 }).catch(err => ({ exitCode: -1, stdout: '', stderr: String(err) }))
  if (r.exitCode !== 0) {
    hostError = `${hostBin} --background exited ${r.exitCode}: ${(r.stderr || r.stdout).trim().slice(0, 200)}`
    return undefined
  }
  const parsed = parseHostFile(r.stdout.trim())
  if (!parsed) {
    hostError = `host answered no discovery record: ${r.stdout.trim().slice(0, 120)}`
    return undefined
  }
  return parsed
}

let connecting: Promise<void> | undefined

// Single-flight: a command arriving while the session-start connect is still
// in progress must join it, not register a second client.
function connect($: $): Promise<void> {
  if (!connecting) connecting = connectOnce($).finally(() => { connecting = undefined })
  return connecting
}

async function connectOnce($: $): Promise<void> {
  hostError = undefined
  client = undefined
  host = await discover($)
  if (!host) return
  const health = await api($, '/health').catch(() => undefined)
  if (!health?.ok) {
    hostError = failure(health, 'health')
    host = undefined
    return
  }
  cellAspect = parseCellAspect(health.text) ?? 0.5
  try {
    const px = (JSON.parse(health.text) as { cell_px?: { w?: number; h?: number } | null }).cell_px
    cellPx = px && px.w && px.h ? { w: px.w, h: px.h } : undefined
  } catch {
    cellPx = undefined
  }
  // A plugin reload runs this again on the same host. Registering afresh
  // would strand the previous client's producers until its lease lapses, so
  // adopt the remembered client while the host still honours it.
  const saved = await $.store.get('client').catch(() => undefined) as { hostPid?: unknown; port?: unknown; id?: unknown; target?: unknown } | undefined
  if (saved && saved.hostPid === host.pid && saved.port === host.port && typeof saved.id === 'string' && typeof saved.target === 'string') {
    client = { id: saved.id, target: saved.target, lease_ms: 120000 }
    const probe = await api($, '/sessions').catch(() => undefined)
    if (!probe?.ok) client = undefined
  }
  if (!client) {
    const reply = await api($, '/clients', /^\d+$/.test(parentPid) ? { parent_pid: Number(parentPid) } : {}).catch(() => undefined)
    const registered = reply?.ok ? parseClient(reply.text) : null
    if (!registered) {
      hostError = failure(reply, 'client registration')
      host = undefined
      return
    }
    client = registered
    await $.store.set('client', { hostPid: host.pid, port: host.port, id: client.id, target: client.target }).catch(err => log($, `store write failed: ${err}`))
  }
  $.ui.invalidate('prompt.section')
  // The model's Bash tool inherits these: a plain `katzensteg <profile>` in a
  // shell registers with this client and opens a panel.
  await $.env.set('KATZENSTEG_TARGET', client.target)
  await $.env.set('KATZENSTEG_OBSERVE', '1')
  await refresh($)
  if (!polling) {
    polling = true
    poll($)
  }
}

async function refresh($: $): Promise<boolean> {
  const r = await api($, '/sessions').catch(() => undefined)
  if (!r?.ok) return false
  if (r.text === listing) return false
  listing = r.text
  sessions = parseSessions(r.text)
  for (const id of [...sentGrid.keys()]) if (!sessions.some(s => s.id === id)) { sentGrid.delete(id); gridReady.delete(id); lastN.delete(id); hidden.delete(id); sizeOverride.delete(id); resizing.delete(id); lastWidths.delete(id); lastHeights.delete(id); placed.delete(id) }
  $.ui.invalidate('ui.render')
  void ensureContainer($)
  return true
}

// The session list is the authoritative snapshot; polling it also renews the
// client's lease. Events and observation come in a later host slice.
function poll($: $): void {
  const step = async () => {
    let delay = 400
    if (host) {
      try {
        const r = await api($, '/sessions')
        if (!r.ok) throw new Error(`sessions ${r.status}`)
        if (r.text !== listing) {
          listing = r.text
          sessions = parseSessions(r.text)
          for (const id of [...sentGrid.keys()]) if (!sessions.some(s => s.id === id)) { sentGrid.delete(id); gridReady.delete(id); lastN.delete(id); hidden.delete(id); sizeOverride.delete(id); resizing.delete(id); lastWidths.delete(id); lastHeights.delete(id); placed.delete(id) }
          $.ui.invalidate('ui.render')
          void ensureContainer($)
        }
      } catch (err) {
        log($, `host lost: ${err}`)
        hostError = `host lost: ${err}`
        host = undefined
        client = undefined
        $.ui.invalidate('prompt.section')
        if (sessions.length > 0) { sessions = []; listing = ''; $.ui.invalidate('ui.render') }
      }
    } else {
      delay = 2000
      await connect($).catch(() => undefined)
    }
    $.clock.after(delay, step)
  }
  void step()
}

function visible(): Session[] {
  return sessions.filter(s => (s.state === 'starting' || s.state === 'ready') && !hidden.has(s.id))
}

// Open the pane while panels exist and the place is the pane; close it when
// the last panel goes or the place moves to the band.
async function ensureContainer($: $): Promise<void> {
  const any = visible().length > 0
  if (place === 'pane' && any && !paneOpen) {
    paneOpen = true
    await $.ui.open({ id: PANE_ID, title: 'katzensteg', rows: SIZES[size] + 3 }).catch(err => { paneOpen = false; log($, `pane did not open: ${err}`) })
  } else if (paneOpen && (place !== 'pane' || !any)) {
    paneOpen = false
    await $.ui.close({ id: PANE_ID }).catch(() => undefined)
  }
  $.ui.invalidate('ui.render')
}

async function closeSession($: $, id: string): Promise<string> {
  hidden.add(id)
  $.ui.invalidate('ui.render')
  const r = await api($, `/sessions/${encodeURIComponent(id)}/close`, {}).catch(err => ({ ok: false, status: 0, text: String(err) }))
  return r.ok ? `closed ${id}` : `close ${id} failed: ${r.text}`
}

// Agent tools, mirroring the pi extension's contract so prompts transfer.
// Names reach the model as mcp__katzensteg__<name>.
const TOOL_PREFIX = 'mcp__katzensteg__'

// A plugin-served tool answers with a string (or content blocks); a refusal
// goes through `deny`, which the model reads as an error result.
type ToolText = { result: string } | { deny: string }
const toolText = (text: string, isError = false): ToolText => (isError ? { deny: text } : { result: text })

const KEY_NAMES = new Set(['enter', 'return', 'escape', 'space', 'tab', 'backspace', 'delete', 'insert', 'up', 'down', 'left', 'right', 'home', 'end', 'pageup', 'pagedown'])
const keyName = (key: unknown): string | undefined => {
  if (typeof key !== 'string' || key === '') return undefined
  const k = key.toLowerCase()
  if (KEY_NAMES.has(k) || /^f([1-9]|1[0-2])$/.test(k)) return k
  return [...key].length === 1 ? key : undefined
}

async function registerTools($: $): Promise<void> {
  const specs = [
    {
      name: 'open',
      description: 'Open a Katzensteg game or app panel above the prompt (run, play, launch, emulator, retroarch, scummvm), as /katzensteg open does. Give a profile such as mi2 or sonic and optional program args. Returns the panel id; the game may still be starting, so check panels before acting. Ordinary `katzensteg <profile>` launches from the Bash tool also open panels because KATZENSTEG_TARGET is set.',
      inputSchema: { type: 'object', properties: { profile: { type: 'string', minLength: 1 }, args: { type: 'array', items: { type: 'string' } } }, required: ['profile'] },
    },
    {
      name: 'show',
      description: 'Show a visualization (chart, plot, graph, diagram, table, drawing, HTML page) in a Katzensteg panel above the prompt, rendered by a WebKit page viewer (macOS). Give html (a complete self-contained document), path (an existing .html file) or url (an http(s) page, e.g. a published Claude artifact; the viewer keeps cookies between runs so a login persists). Returns the panel id and the file path: rewrite that file with the Write tool to update the picture, and use observe to see the result. Interactive pages get mouse, wheel and key events from the panel. The katzensteg-visualize skill has layout rules for the small panel.',
      inputSchema: { type: 'object', properties: { html: { type: 'string' }, path: { type: 'string' }, url: { type: 'string' }, title: { type: 'string' } } },
    },
    {
      name: 'panels',
      description: 'List the open Katzensteg panels: id, title, state (starting, ready, closing, exited), source size in pixels and the placeholder grid in cells.',
      inputSchema: { type: 'object', properties: {} },
    },
    {
      name: 'act',
      description: 'Send input to a Katzensteg panel: an ordered list of up to 16 actions of type move, click, key or wait. move and click take x and y in source pixels (see panels for the size), click holds the left button 60 ms unless button is middle or right, key taps a key by name (enter, escape, space, tab, backspace, delete, arrows, home, end, pageup, pagedown, f1-f12, or one character; ctrl/shift/alt/meta flags optional), wait takes ms (at most 5000 in total). Omit panel when exactly one panel is open. Keys are taps, not holds.',
      inputSchema: {
        type: 'object',
        properties: {
          panel: { type: 'string' },
          actions: { type: 'array', maxItems: 16, items: { type: 'object', properties: { type: { type: 'string', enum: ['move', 'click', 'key', 'wait'] }, x: { type: 'number' }, y: { type: 'number' }, button: { type: 'string', enum: ['left', 'middle', 'right'] }, key: { type: 'string' }, ctrl: { type: 'boolean' }, shift: { type: 'boolean' }, alt: { type: 'boolean' }, meta: { type: 'boolean' }, ms: { type: 'number' } }, required: ['type'] } },
        },
        required: ['actions'],
      },
    },
    {
      name: 'observe',
      description: 'Screenshot a Katzensteg panel: the latest image as a PNG file path the Read tool can render, with its size and capture id. Use it to look at a visualization or game before describing it. Omit panel when exactly one panel is open.',
      inputSchema: { type: 'object', properties: { panel: { type: 'string' }, afterFrame: { type: 'number' } } },
    },
  ]
  for (const spec of specs) {
    await $.tool.register(spec).catch(err => log($, `tool ${spec.name} not registered: ${err}`))
  }
}

async function pickPanel($: $, wanted: unknown): Promise<Session | string> {
  await refresh($)
  const live = sessions.filter(s => s.state === 'starting' || s.state === 'ready')
  if (typeof wanted === 'string' && wanted !== '') {
    return sessions.find(s => s.id === wanted) ?? `no panel ${wanted}; open ones: ${live.map(s => s.id).join(', ') || 'none'}`
  }
  if (typeof wanted === 'number') return sessions.find(s => s.id === String(wanted)) ?? `no panel ${wanted}`
  if (live.length === 1) return live[0]!
  return live.length === 0 ? 'no panel is open; use open first' : `several panels are open (${live.map(s => s.id).join(', ')}); pass panel`
}

const describe = (s: Session) =>
  `${s.id}: ${s.title}${s.input_supported ? '' : ' · observation only'} · ${s.state}${s.source_px ? ` · ${s.source_px.w}x${s.source_px.h} px` : ''}${s.grid ? ` · grid ${s.grid.cols}x${s.grid.rows}` : ''}`

// One tree for both sites. `columns` is the site's body width, `rowsBudget`
// the rows a panel may take, `stacked` lays panels in a column (the dock)
// rather than a wrapping row (the band, or a pane seated inline).
async function panelsTree($: $, els: Elements['terminal'], columns: number, rowsBudget: number, stacked: boolean, tail: RenderChildren): Promise<RenderElement> {
  const { Box, Client, Text } = els
  const shown = ordered(order, visible())
  order = shown.map(s => s.id)
  if (drawnCount !== shown.length) { drawnCount = shown.length; log($, `drawing ${shown.length} panel(s) in ${stacked ? 'a docked pane' : 'a row'} at ${columns} columns, ${rowsBudget} rows`) }
  // Side by side, panels share the width; stacked, each has the full width.
  const share = stacked ? columns - 2 : Math.floor((columns - shown.length) / shown.length) - 2
  const rowsMax = Math.min(SIZES[size], rowsBudget)
  band = { columns, rows: rowsBudget }
  siteMeasured = true
  lastStacked = stacked
  const panels = shown.map(s => {
    const own = sizeOverride.get(s.id)
    const grid = own
      ? fitGrid(s.source_px, Math.min(own.cols, columns - 2), Math.min(own.rows, rowsBudget), cellAspect)
      : fitGrid(s.source_px, share, rowsMax, cellAspect)
    lastWidths.set(s.id, grid.cols + 2)
    lastHeights.set(s.id, grid.rows + 2)
    const sent = sentGrid.get(s.id)
    // The host withholds graphics until it has a grid, so wait for the
    // source size rather than commit a full-width grid it would refit.
    if (s.source_px && !resizing.has(s.id) && (!sent || sent.cols !== grid.cols || sent.rows !== grid.rows)) {
      sentGrid.set(s.id, grid)
      $.clock.after(0, () => {
        api($, `/sessions/${encodeURIComponent(s.id)}/grid`, grid)
          .then(r => { if (r.ok) { gridReady.add(s.id); log($, `grid for ${s.id}: ${grid.cols}x${grid.rows} accepted`) } else log($, `grid for ${s.id} refused ${r.status}: ${r.text.slice(0, 120)}`) })
          .catch(err => log($, `grid for ${s.id} failed: ${err}`))
      })
    }
    // Repainting placeholder cells does not need another image upload.
    // Live producers restore themselves on their next frame; the WM's idle
    // refresh covers stationary producers after a terminal clear.
    return { s, grid }
  })
  // Replicate the layout below so scroll events can be mapped to a panel:
  // header on row 0, then panels left to right with a one-cell gap, wrapping
  // when the site is too narrow; stacked, one per row block.
  placed.clear()
  {
    let col = 0
    let row = 1
    let tallest = 0
    for (const { s, grid } of panels) {
      const w = grid.cols + 2
      const h = grid.rows + 2
      if (stacked) { placed.set(s.id, { col: 0, row, cols: w, rows: h }); row += h; continue }
      if (col > 0 && col + w > columns) { col = 0; row += tallest; tallest = 0 }
      placed.set(s.id, { col, row, cols: w, rows: h })
      col += w + 1
      tallest = Math.max(tallest, h)
    }
  }
  return (
    <Box flexDirection="column">
      <Text dimColor wrap="truncate-end">{`katzensteg · ${shown.length} panel${shown.length === 1 ? '' : 's'} · click to play, Esc for the prompt · drag title to reorder, corner to resize, × closes`}</Text>
      <Box flexDirection={stacked ? 'column' : 'row'} flexWrap={stacked ? 'nowrap' : 'wrap'} columnGap={1}>
        {panels.map(({ s, grid }) => (
          <Client
            key={`panel:${s.id}`}
            module="./panel.tsx"
            width={grid.cols + 2}
            height={grid.rows + 2}
            props={{ id: s.id, imageId: s.image_id, cols: grid.cols, rows: grid.rows, title: s.title, state: s.state }}
          />
        ))}
      </Box>
      {tail}
    </Box>
  )
}


function panelsEmpty(els: Elements['terminal']): RenderElement {
  const { Text } = els
  return <Text dimColor>{'katzensteg · no panels · /katzensteg open <profile>'}</Text>
}


export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const r = await next(e)
    await $.command.register({
      name: 'katzensteg',
      description: 'Game panels above the prompt via a headless katzensteg-wm: open, close, list, host',
      argumentHint: 'open <profile> [args...] | close [id] | size small|medium|large | place band|pane | pane | list | host | stop',
      immediate: true,
    }).catch(err => log($, `/katzensteg not registered: ${err}`))
    await registerTools($)
    const repo = (await $.env.get('KATZENSTEG_REPO')) ?? `${(await $.env.get('HOME')) ?? ''}/dev/katzensteg`
    hostBin = (await $.env.get('KATZENSTEG_HOST_BIN')) ?? `${repo}/zig-out/bin/katzensteg-wm`
    const saved = await $.store.get('size').catch(() => undefined)
    if (saved === 'small' || saved === 'medium' || saved === 'large') size = saved
    const savedPlace = await $.store.get('place').catch(() => undefined)
    if (savedPlace === 'band' || savedPlace === 'pane') place = savedPlace
    // Connect off the session.start path so a slow host start never holds it;
    // the poll loop keeps retrying while no host answers.
    $.clock.after(0, () => { connect($).catch(err => log($, `connect failed: ${err}`)).finally(() => { if (!polling) { polling = true; poll($) } }) })
    return r
  })

  on('command.run', { command: 'katzensteg' }, async ($, e) => {
    const words = e.args.trim().split(/\s+/).filter(Boolean)
    const [verb = 'host', ...rest] = words
    if (verb === 'host') {
      if (!host) await connect($)
      const detail = sessions.map(s => {
        const sent = sentGrid.get(s.id)
        const own = sizeOverride.get(s.id)
        return `  ${s.id}: ${s.state} · host grid ${s.grid ? `${s.grid.cols}x${s.grid.rows}` : 'none'} · sent ${sent ? `${sent.cols}x${sent.rows}` : 'none'}${gridReady.has(s.id) ? ' (acked)' : ''} · override ${own ? `${own.cols}x${own.rows}` : 'none'}${resizing.has(s.id) ? ' · resizing' : ''} · last events: ${(lastTypes.get(s.id) ?? []).join(',') || 'none'}`
      })
      return {
        text: host && client
          ? [`katzensteg host: pid ${host.pid} on 127.0.0.1:${host.port} · client ${client.id} · ${visible().length} panel(s) · ${forwarded} input events forwarded`, ...detail].join('\n')
          : `katzensteg: no host (${hostError ?? 'not connected'}) · binary ${hostBin}`,
      }
    }
    if (!host) return { text: `katzensteg: no host (${hostError ?? 'not connected'}); /katzensteg host retries` }
    if (verb === 'open') {
      const [profile, ...args] = rest
      if (!profile) return { text: 'katzensteg open <profile> [args...]' }
      // A pane the person closed comes back with the next panel; the refresh
      // below reopens it, so the reset belongs on the path that reaches it.
      if (place === 'pane') { paneOpen = false }
      const r = await api($, '/sessions', { profile, args }).catch(err => ({ ok: false, status: 0, text: String(err) }))
      if (!r.ok) return { text: `katzensteg open failed: ${r.text}` }
      const id = String((JSON.parse(r.text) as { id?: unknown }).id ?? '?')
      hidden.delete(id)
      await refresh($)
      return { text: `katzensteg: opened ${profile} as ${id} · click the panel to play, Esc returns to the prompt` }
    }
    if (verb === 'close') {
      const id = rest[0] ?? visible().at(-1)?.id
      if (!id) return { text: 'katzensteg: nothing to close' }
      return { text: `katzensteg: ${await closeSession($, id)}` }
    }
    if (verb === 'stop') {
      const results = await Promise.all(visible().map(s => closeSession($, s.id)))
      return { text: `katzensteg: ${results.join(', ') || 'nothing open'}` }
    }
    if (verb === 'size') {
      const pick = rest[0]
      if (pick !== 'small' && pick !== 'medium' && pick !== 'large') return { text: `katzensteg size small|medium|large (now ${size})` }
      size = pick
      sizeOverride.clear()
      await $.store.set('size', size).catch(err => log($, `store write failed: ${err}`))
      $.ui.invalidate('ui.render')
      return { text: `katzensteg: panels ${size} (${SIZES[size]} rows at most)` }
    }
    if (verb === 'place') {
      const pick = rest[0]
      if (pick !== 'band' && pick !== 'pane') return { text: `katzensteg place band|pane (now ${place})` }
      place = pick
      await $.store.set('place', place).catch(err => log($, `store write failed: ${err}`))
      await ensureContainer($)
      return { text: `katzensteg: panels in the ${place}${place === 'pane' ? ' (docked beside the transcript in fullscreen from 110 columns, else above the prompt; ctrl+x tab focuses it, ctrl+x x closes it)' : ''}` }
    }
    if (verb === 'pane') {
      // Reopen the pane the person closed, keeping the panels that were in it.
      paneOpen = false
      place = 'pane'
      await ensureContainer($)
      return { text: visible().length > 0 ? 'katzensteg: pane reopened' : 'katzensteg: no panels to show; open one first' }
    }
    if (verb === 'list') {
      await refresh($)
      const rows = sessions.map(s => `${s.id.padEnd(4)} ${s.state.padEnd(8)} image ${s.image_id} ${s.source_px ? `${s.source_px.w}x${s.source_px.h}` : ''} ${s.grid ? `${s.grid.cols}x${s.grid.rows}` : 'no grid'} ${hidden.has(s.id) ? '(hidden)' : ''} ${s.title}${s.input_supported ? '' : ' (observation only)'}`)
      return { text: rows.join('\n') || 'katzensteg: no sessions' }
    }
    return { text: 'katzensteg: open <profile> [args...] | close [id] | size small|medium|large | place band|pane | pane | list | host | stop' }
  })

  // A standing note in the system prompt while a host is connected, so the
  // model reaches for the panel tools without being told; they are deferred
  // and otherwise unseen. Dropped when the host goes away.
  on('prompt.section', { name: 'env_info_simple' }, async ($, e, next) => {
    const r = await next(e)
    if (!host || !client) return r
    const note = 'Katzensteg panels are available above the prompt. To show a chart, diagram or other visualization, write a self-contained HTML page and call mcp__katzensteg__show (load the katzensteg-visualize skill for layout rules); mcp__katzensteg__observe screenshots a panel; mcp__katzensteg__act sends keys and clicks; mcp__katzensteg__panels lists open panels; mcp__katzensteg__open runs a game or app profile.'
    return { text: r.text ? `${r.text}\n\n${note}` : note }
  })

  on('tool.call', { tool: `${TOOL_PREFIX}open` }, async ($, e) => {
    if (!host) return toolText(`katzensteg: no host (${hostError ?? 'not connected'})`, true)
    const profile = typeof e.profile === 'string' ? e.profile : ''
    const args = Array.isArray(e.args) ? e.args.filter((a): a is string => typeof a === 'string') : []
    if (!profile) return toolText('open needs a profile', true)
    const r = await api($, '/sessions', { profile, args }).catch(err => ({ ok: false, status: 0, text: String(err) }))
    if (!r.ok) return toolText(`open failed: ${r.text}`, true)
    const id = String((JSON.parse(r.text) as { id?: unknown }).id ?? '?')
    hidden.delete(id)
    await refresh($)
    return toolText(`Opened ${profile} as panel ${id}. The game may still be starting; panels reports its state.`)
  })

  on('tool.call', { tool: `${TOOL_PREFIX}show` }, async ($, e) => {
    if (!host) return toolText(`katzensteg: no host (${hostError ?? 'not connected'})`, true)
    let path = typeof e.path === 'string' ? e.path : ''
    const url = typeof e.url === 'string' ? e.url : ''
    if (url) {
      if (!/^https?:\/\/[^\s/]+/.test(url)) return toolText(`show needs an http(s) url, not ${url}`, true)
      path = url
    } else if (!path) {
      if (typeof e.html !== 'string' || e.html === '') return toolText('show needs html, path or url', true)
      const dir = (await $.env.get('TMPDIR')) ?? '/tmp'
      shown += 1
      path = `${dir.replace(/\/+$/, '')}/katzensteg-show-${Date.now()}-${shown}.html`
      try {
        await $.fs.write(path, e.html)
      } catch (err) {
        return toolText(`could not write ${path}: ${err}`, true)
      }
    } else if (!(await $.fs.exists(path))) return toolText(`no such file: ${path}`, true)
    // Render at the size the panel's cells cover, doubled for crisp text on
    // high-density displays, so labels stay legible after the terminal
    // scales the image into the grid. The page is the preset's rows tall and
    // as wide as a 16:10 page needs at that height, capped by the site's
    // width once a render has measured it. Before the first panel the site is
    // unmeasured (`band` still holds its defaults), and the page viewer cannot
    // resize after start, so the aspect rule alone decides then.
    const rows = Math.max(6, siteMeasured ? Math.min(SIZES[size], band.rows) : SIZES[size])
    const pageCols = Math.round((rows * 1.6) / cellAspect)
    const cols = Math.max(20, Math.min(pageCols, siteMeasured ? band.columns - 2 : 160, 160))
    const px = cellPx ?? { w: 8, h: 16 }
    // cell_px is a ratio of the tty's pixel and cell counts, so it is usually
    // fractional; luchs takes whole pixels.
    const sizeArg = `--size=${Math.min(4096, Math.round(cols * px.w * 2))}x${Math.min(4096, Math.round(rows * px.h * 2))}`
    const r = await api($, '/sessions', { profile: 'luchs', args: url ? [sizeArg, path] : [sizeArg, '--watch', path] }).catch(err => ({ ok: false, status: 0, text: String(err) }))
    if (!r.ok) return toolText(`show failed: ${r.text}`, true)
    const id = String((JSON.parse(r.text) as { id?: unknown }).id ?? '?')
    hidden.delete(id)
    await refresh($)
    if (url) return toolText(`Showing ${path} as panel ${id}. The viewer keeps its own cookies between runs, so a page that needs a login shows it once; act can type into it. observe shows the rendered result.`)
    return toolText(`Showing ${path} as panel ${id}. Rewrite that file to update it (the viewer reloads on change); observe shows the rendered result.`)
  })

  on('tool.call', { tool: `${TOOL_PREFIX}panels` }, async ($) => {
    if (!host) return toolText(`katzensteg: no host (${hostError ?? 'not connected'})`, true)
    await refresh($)
    const rows = sessions.filter(s => !hidden.has(s.id)).map(describe)
    return toolText(rows.join('\n') || 'No panels are open.')
  })

  on('tool.call', { tool: `${TOOL_PREFIX}act` }, async ($, e) => {
    if (!host) return toolText(`katzensteg: no host (${hostError ?? 'not connected'})`, true)
    const panel = await pickPanel($, e.panel)
    if (typeof panel === 'string') return toolText(panel, true)
    if (panel.state !== 'ready') return toolText(`panel ${panel.id} is ${panel.state}`, true)
    const actions = Array.isArray(e.actions) ? e.actions : []
    if (actions.length === 0 || actions.length > 16) return toolText('actions: 1 to 16 entries', true)
    const px = panel.source_px
    const grid = sentGrid.get(panel.id) ?? panel.grid
    if (!px || !grid) return toolText(`panel ${panel.id} has no size yet`, true)
    // The host takes grid cells; the source pixels go along so the producer
    // gets the exact point rather than the cell's corner, which at panel
    // cell sizes can miss a button or a text field.
    const cell = (x: unknown, y: unknown) => {
      const sx = Math.min(px.w - 1, Math.max(0, Math.round(Number(x) || 0)))
      const sy = Math.min(px.h - 1, Math.max(0, Math.round(Number(y) || 0)))
      return {
        x: Math.min(grid.cols - 1, Math.max(0, Math.floor(sx * grid.cols / px.w))),
        y: Math.min(grid.rows - 1, Math.max(0, Math.floor(sy * grid.rows / px.h))),
        px: sx,
        py: sy,
      }
    }
    let waited = 0
    let pending: Record<string, unknown>[] = []
    const flush = async () => {
      if (pending.length === 0) return
      const batch = pending
      pending = []
      const r = await api($, `/sessions/${encodeURIComponent(panel.id)}/input`, { events: batch })
      if (!r.ok) throw new Error(`input refused ${r.status}: ${r.text.slice(0, 120)}`)
    }
    try {
      for (const raw of actions) {
        const a = (typeof raw === 'object' && raw !== null ? raw : {}) as Record<string, unknown>
        if (a.type === 'move') pending.push({ type: 'pointer', kind: 'move', ...cell(a.x, a.y) })
        else if (a.type === 'click') {
          const button = a.button === 'middle' || a.button === 'right' ? a.button : 'left'
          const at = cell(a.x, a.y)
          pending.push({ type: 'pointer', kind: 'move', ...at }, { type: 'pointer', kind: 'down', ...at, button })
          await flush()
          await $.clock.sleep(60)
          pending.push({ type: 'pointer', kind: 'up', ...at, button })
        } else if (a.type === 'key') {
          const key = keyName(a.key)
          if (!key) return toolText(`unknown key ${JSON.stringify(a.key)}`, true)
          pending.push({ type: 'key', key, ...(a.ctrl === true && { ctrl: true }), ...(a.shift === true && { shift: true }), ...(a.alt === true && { alt: true }), ...(a.meta === true && { meta: true }) })
        } else if (a.type === 'wait') {
          const ms = Math.max(0, Math.min(5000 - waited, Number(a.ms) || 0))
          waited += ms
          await flush()
          if (ms > 0) await $.clock.sleep(ms)
        } else return toolText(`unknown action type ${JSON.stringify(a.type)}`, true)
      }
      await flush()
    } catch (err) {
      return toolText(`act failed: ${err}`, true)
    }
    await refresh($)
    const now = sessions.find(s => s.id === panel.id)
    return toolText(`Sent ${actions.length} action(s) to panel ${panel.id}${now ? ` (${now.state})` : ''}. Input is queued through the game's input model; observe or wait before assuming it reacted.`)
  })

  on('tool.call', { tool: `${TOOL_PREFIX}observe` }, async ($, e) => {
    if (!host) return toolText(`katzensteg: no host (${hostError ?? 'not connected'})`, true)
    const panel = await pickPanel($, e.panel)
    if (typeof panel === 'string') return toolText(panel, true)
    const r = await api($, `/sessions/${encodeURIComponent(panel.id)}/observe`, {}).catch(err => ({ ok: false, status: 0, text: String(err) }))
    if (r.ok) {
      const o = JSON.parse(r.text) as { path?: string; width?: number; height?: number; frame_id?: number; timestamp_ms?: number }
      if (typeof o.path === 'string') return toolText(`Image of panel ${panel.id}: ${o.path} (${o.width}x${o.height}, frame ${o.frame_id}, at ${o.timestamp_ms}). Read that file to see it.`)
    }
    return toolText(`Frame observation is not exposed by the host yet (${r.status}). Panel ${describe(panel)}.`, true)
  })

  // The person closed the pane (ctrl+x x, Esc with closeOnEscape): panels keep
  // running; /katzensteg pane or the next open brings it back.
  on('ui.close', { id: PANE_ID }, async ($, e, next) => {
    const r = await next(e)
    paneOpen = false
    return r
  })

  // The wheel over a panel's picture goes to the game as a wheel event; over
  // anything else the site scrolls as usual.
  on('ui.scroll', async ($, e, next) => {
    const ours = e.component === 'Pane' ? e.requestId === PANE_ID : place === 'band'
    const p = e.pointer
    if (!ours || !p || e.origin.kind !== 'person' || !host) return next(e)
    const row = e.offset + p.row
    for (const [id, box] of placed) {
      const inside = p.column > box.col && p.column < box.col + box.cols - 1 && row > box.row && row < box.row + box.rows - 1
      if (!inside || !gridReady.has(id)) continue
      forwarded += 1
      api($, `/sessions/${encodeURIComponent(id)}/input`, { events: [{ type: 'pointer', kind: 'wheel', x: p.column - box.col - 1, y: row - box.row - 1, delta_y: e.by }] })
        .then(r => { if (!r.ok && r.status !== 400) log($, `wheel to ${id} refused ${r.status}: ${r.text.slice(0, 120)}`) })
        .catch(err => log($, `wheel to ${id} failed: ${err}`))
      return {}
    }
    return next(e)
  })

  // A panel's input: forward what it has not sent before, numbered by the panel.
  on('ui.message', async ($, e, next) => {
    const data = e.data as { id?: unknown; events?: unknown } | null
    if (typeof data?.id !== 'string') return next(e)
    const id = data.id
    const { events, lastN: n } = newInputEvents(data.events, lastN.get(id) ?? 0)
    lastN.set(id, n)
    if (events.length > 0) lastTypes.set(id, [...(lastTypes.get(id) ?? []), ...events.map(ev => ev.type)].slice(-10))
    for (const ev of events) {
      if (ev.type === 'close') void closeSession($, id)
      else if (ev.type === 'resize') {
        const big = 9999
        sizeOverride.set(id, ev.axis === 'resize-y' ? { cols: big, rows: ev.rows } : { cols: ev.cols, rows: ev.axis === 'resize-x' ? big : ev.rows })
        resizing.add(id)
        $.ui.invalidate('ui.render')
      } else if (ev.type === 'resizeend') {
        resizing.delete(id)
        $.ui.invalidate('ui.render')
      } else if (ev.type === 'drag') {
        // Side by side the gap is one column; stacked, the blocks touch.
        const reordered = lastStacked ? swapOnDrag(order, id, ev.dy, lastHeights, 0) : swapOnDrag(order, id, ev.dx, lastWidths)
        if (reordered.some((v, i) => v !== order[i])) { order = reordered; $.ui.invalidate('ui.render') }
      }
    }
    const input = events.filter(ev => !isPanelEvent(ev))
    if (input.length > 0 && host && gridReady.has(id)) {
      forwarded += input.length
      api($, `/sessions/${encodeURIComponent(id)}/input`, { events: stripNumbers(input) })
        .then(r => { if (!r.ok) log($, `input to ${id} refused ${r.status}: ${r.text.slice(0, 120)}`) })
        .catch(err => log($, `input to ${id} failed: ${err}`))
    }
    return {}
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (place !== 'band' || visible().length === 0 || e.surface !== 'terminal' || e.props.hasSurvey) return next(e)
    const els = await $.ui.resolve(e)
    // One header row plus each panel's border: the grid gets the rows less three.
    return panelsTree($, els, e.props.bodyColumns, Math.max(1, e.props.maxRows - 3), false, await next(e))
  })

  on('ui.render', { component: 'Pane', requestId: PANE_ID }, async ($, e, next) => {
    if (e.surface !== 'terminal') return next(e)
    if (visible().length === 0) return panelsEmpty(await $.ui.resolve(e))
    const els = await $.ui.resolve(e)
    // Docked, the pane is a column: stack panels and let its body scroll.
    // Inline, it is a band with a frame: lay panels out as the band does.
    const stacked = e.props.placement === 'dock'
    const key = `${e.props.placement}:${e.props.bodyColumns}x${e.props.scroll.bodyRows}`
    if (lastPlacement !== key) {
      lastPlacement = key
      log($, `pane ${e.props.placement}: ${e.props.bodyColumns} columns, ${e.props.scroll.bodyRows} body rows`)
    }
    const rowsBudget = stacked ? SIZES.large : Math.max(1, e.props.scroll.bodyRows - 1)
    return panelsTree($, els, e.props.bodyColumns, rowsBudget, stacked, null)
  })

}
