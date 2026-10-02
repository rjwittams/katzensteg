/* @jsx h */
import type { ClientPointerEvent, ClientSurface } from 'claude-code'
import { fgHex, rowSpan, rowText } from './placeholders.ts'
import { dragFor, dragStep, markAt, panelFrame, POINTER_MARK, zoneAt, type DragKind, type Seg, type Zone } from './frame.ts'

// One game panel: a border, a title row and the placeholder grid the terminal
// composes the producer's image into. Runs on the drawing thread. Keys arrive
// after a click gives it focus (Escape returns focus); pointer events are cell
// coordinates relative to the region, so the border is subtracted.
//
// The border is the panel's own UI: × at the top-right closes, the title row
// drags to reorder, the right edge, bottom edge and corner drag to resize.
// Input is numbered and the recent tail is posted every frame; the hooks
// module forwards what it has not sent yet (see newInputEvents).

export type PanelProps = {
  id: string
  imageId: number
  cols: number
  rows: number
  title: string
  state: 'starting' | 'ready' | 'closing' | 'exited'
  /** The cell character when the host rewrites a stand-in; absent, the kitty placeholder. */
  placeholder?: string
  /**
   * Draw the border and take input, but leave the grid empty: the picture is
   * an image the application draws beneath this panel.
   */
  hollow?: boolean
  /** Another panel is being moved: draw this one's frame dim. */
  dimmed?: boolean
  /**
   * While a panel is being moved, the cell of this panel's region the pointer
   * is on: it is drawn marked, so the pointer can be seen to be followed.
   */
  pointer?: { x: number; y: number }
  /** The number of the layout this panel is drawn in; drag reports name it. */
  gen?: number
}

type Ev = Record<string, unknown> & { n: number }
// What the frame is drawn from: a drag in progress, the handle under the
// pointer, and the phase of the marching dashes while a panel is held.
type State = { count: number; latest: { props: PanelProps }; drag?: DragKind; hover?: Zone; phase: number }
type Drag = { kind: DragKind; x0: number; y0: number; cols0: number; rows0: number }

const KEEP = 64
// How often the dashes on a held panel move one cell.
const MARCH_MS = 120
const ACCENT = 'cyan'
const HANDLES: readonly Zone[] = ['close', 'title', 'right', 'bottom', 'corner']

export default function Panel(props: PanelProps, surface: ClientSurface<State>) {
  const { Box, Text } = surface.elements
  if (surface.state === undefined) {
    // Handlers are registered once; `latest` lets them see the grid size of
    // the current render, not the first one.
    const latest = { props }
    let n = 0
    let drag: Drag | undefined
    let hover: Zone | undefined
    let phase = 0
    let stopMarch: (() => void) | undefined
    const sync = () => surface.setState({ count: n, latest, ...(drag && { drag: drag.kind }), ...(hover && { hover }), phase })
    sync()
    // Numbering restarts with each instance (a route or site change mounts a
    // new one); the token lets the hooks module tell, and start counting anew.
    const inst = Math.floor(Math.random() * 0x7fffffff)
    const recent: Ev[] = []
    const push = (ev: Record<string, unknown>) => {
      n += 1
      recent.push({ ...ev, n })
      if (recent.length > KEEP) recent.splice(0, recent.length - KEEP)
      surface.post({ id: props.id, inst, events: recent as never })
      sync()
    }
    surface.onKey(({ key, ctrl, shift, meta }) => {
      push({ type: 'key', key, ...(ctrl && { ctrl }), ...(shift && { shift }), ...(meta && { meta }) })
    })
    surface.onPointer((ev: ClientPointerEvent) => {
      if (ev.type === 'enter') return
      if (ev.type === 'leave') {
        // A drag holds the pointer past the edge; only a hover ends here.
        if (!drag && hover) { hover = undefined; sync() }
        return
      }
      const { cols, rows } = latest.props
      // A drag in progress: pointer capture delivers every move and the
      // release, past the edges too.
      if (drag) {
        const endDrag = () => {
          const kind = drag!.kind
          drag = undefined
          stopMarch?.()
          stopMarch = undefined
          hover = undefined
          push({ type: kind === 'move' ? 'dragend' : 'resizeend' })
        }
        const step = dragStep(ev.type, ev.button !== undefined)
        if (step === 'release') {
          endDrag()
          return
        }
        if (step === 'continue') {
          // Travel since the press, where the pointer is in the panel's own
          // region, and which layout that region belongs to.
          if (drag.kind === 'move') push({ type: 'drag', dx: ev.x - drag.x0, dy: ev.y - drag.y0, x: ev.x, y: ev.y, ...(latest.props.gen !== undefined && { gen: latest.props.gen }) })
          else {
            const c = drag.kind === 'resize-y' ? drag.cols0 : Math.max(4, drag.cols0 + ev.x - drag.x0)
            const r = drag.kind === 'resize-x' ? drag.rows0 : Math.max(2, drag.rows0 + ev.y - drag.y0)
            push({ type: 'resize', cols: c, rows: r, axis: drag.kind })
          }
          return
        }
        // The release never arrived (see dragStep). End the drag here and
        // handle this event as an ordinary one, or the panel would stay held
        // and every later move would count as dragging it.
        endDrag()
      }
      const zone = zoneAt(ev.x, ev.y, cols, rows)
      if (ev.type === 'down') {
        if (zone === 'close') {
          push({ type: 'close' })
          return
        }
        const kind = dragFor(zone)
        if (kind) {
          drag = { kind, x0: ev.x, y0: kind === 'move' ? 0 : ev.y, cols0: cols, rows0: rows }
          if (kind === 'move') {
            // Held: the dashes march until the release, on the panel's own
            // clock, and the plugin dims the other panels.
            phase = 0
            stopMarch = surface.every(MARCH_MS, () => { phase += 1; sync() })
            push({ type: 'dragstart' })
          } else sync()
          return
        }
      } else if (ev.type === 'move' && !ev.button) {
        // The handle under the pointer lights up before any press.
        const next = HANDLES.includes(zone) ? zone : undefined
        if (next !== hover) { hover = next; sync() }
      }
      // Grid coordinates: the border is one cell. The host refuses anything
      // outside the grid and drops the whole batch with it, so a press on the
      // border is ignored, and a captured drag that leaves the panel is
      // clamped to the edge so the game still sees the move and the release.
      let x = ev.x - 1
      let y = ev.y - 1
      const inside = x >= 0 && y >= 0 && x < cols && y < rows
      if (ev.type === 'down' && !inside) return
      if (!inside) {
        if (ev.type === 'move' && !ev.button) return
        x = Math.min(Math.max(x, 0), cols - 1)
        y = Math.min(Math.max(y, 0), rows - 1)
      }
      push({ type: 'pointer', kind: ev.type, x, y, ...(ev.button && { button: ev.button }) })
    })
  }
  if (surface.state) surface.state.latest.props = props

  const { cols, rows, imageId, title, state, placeholder, hollow, dimmed, pointer } = props
  const color = fgHex(imageId)
  const border = state === 'ready' ? 'green' : state === 'starting' ? 'yellow' : 'red'
  // Title, then the count of input events this panel has captured (a quick
  // check that clicks and keys reach it), then the close mark in the corner.
  // The title row is the move handle, the right and bottom edges and their
  // corner the resize handles; frame.ts decides how each looks just now.
  const seen = surface.state?.count ?? 0
  const frame = panelFrame({
    cols,
    rows,
    title,
    status: `${state} · in:${seen}`,
    phase: surface.state?.phase ?? 0,
    ...(surface.state?.drag && { drag: surface.state.drag }),
    ...(surface.state?.hover && { hover: surface.state.hover }),
  })
  // While another panel is being moved this one steps back.
  const draw = (seg: Seg) => (
    <Text
      color={seg.tone === 'accent' ? ACCENT : seg.tone === 'danger' ? 'red' : border}
      bold={seg.bold === true}
      inverse={seg.inverse === true}
      dimColor={dimmed === true && seg.tone === 'base'}
    >
      {seg.text}
    </Text>
  )
  // The pointer's cell, if it is on this panel: on the top or bottom row, on
  // an edge, or in the grid at column `markCol` of grid row `markRow`.
  const top = pointer?.y === 0 ? markAt(frame.top, pointer.x) : frame.top
  const bottom = pointer?.y === rows + 1 ? markAt(frame.bottom, pointer.x) : frame.bottom
  const markRow = pointer && pointer.y >= 1 && pointer.y <= rows ? pointer.y - 1 : -1
  const left = (r: number) => (r === markRow && pointer?.x === 0 ? POINTER_MARK : frame.left[r]!)
  const right = (r: number) => (r === markRow && pointer?.x === cols + 1 ? POINTER_MARK : frame.right[r]!)
  const markCol = (r: number) => (r === markRow && pointer && pointer.x >= 1 && pointer.x <= cols ? pointer.x - 1 : -1)
  const rowsList = Array.from({ length: rows }, (_, r) => r)
  if (hollow) {
    // Nothing is painted inside the border, so the image beneath shows
    // through; the pointer mark is the one cell drawn over it.
    return (
      <Box flexDirection="column">
        <Text>{top.map(draw)}</Text>
        {rowsList.map(r => {
          const c = markCol(r)
          return (
            <Box>
              {draw(left(r))}
              {c < 0 && <Box width={cols} />}
              {c > 0 && <Box width={c} />}
              {c >= 0 && draw(POINTER_MARK)}
              {c >= 0 && cols - c - 1 > 0 && <Box width={cols - c - 1} />}
              {draw(right(r))}
            </Box>
          )
        })}
        <Text>{bottom.map(draw)}</Text>
      </Box>
    )
  }
  return (
    <Box flexDirection="column">
      <Text>{top.map(draw)}</Text>
      {rowsList.map(r => {
        const c = markCol(r)
        return (
          <Text>
            {draw(left(r))}
            {c < 0 && <Text color={color}>{rowText(r, cols, placeholder)}</Text>}
            {c > 0 && <Text color={color}>{rowSpan(r, 0, c, placeholder)}</Text>}
            {c >= 0 && draw(POINTER_MARK)}
            {c >= 0 && c + 1 < cols && <Text color={color}>{rowSpan(r, c + 1, cols, placeholder)}</Text>}
            {draw(right(r))}
          </Text>
        )
      })}
      <Text>{bottom.map(draw)}</Text>
    </Box>
  )
}
