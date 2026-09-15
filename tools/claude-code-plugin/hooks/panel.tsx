/* @jsx h */
import type { ClientPointerEvent, ClientSurface } from 'claude-code'
import { fgHex, rowText } from './placeholders.ts'

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
}

type Ev = Record<string, unknown> & { n: number }
type State = { count: number; latest: { props: PanelProps } }
type Drag = { kind: 'move' | 'resize-x' | 'resize-y' | 'resize-xy'; x0: number; y0: number; cols0: number; rows0: number }

const KEEP = 64

export default function Panel(props: PanelProps, surface: ClientSurface<State>) {
  const { Box, Text } = surface.elements
  if (surface.state === undefined) {
    // Handlers are registered once; `latest` lets them see the grid size of
    // the current render, not the first one.
    const latest = { props }
    surface.setState({ count: 0, latest })
    let n = 0
    const recent: Ev[] = []
    const push = (ev: Record<string, unknown>) => {
      n += 1
      recent.push({ ...ev, n })
      if (recent.length > KEEP) recent.splice(0, recent.length - KEEP)
      surface.post({ id: props.id, events: recent as never })
      surface.setState({ count: n, latest })
    }
    surface.onKey(({ key, ctrl, shift, meta }) => {
      push({ type: 'key', key, ...(ctrl && { ctrl }), ...(shift && { shift }), ...(meta && { meta }) })
    })
    let drag: Drag | undefined
    surface.onPointer((ev: ClientPointerEvent) => {
      if (ev.type === 'enter' || ev.type === 'leave') return
      const { cols, rows } = latest.props
      // A drag in progress: pointer capture delivers every move and the
      // release, past the edges too.
      if (drag) {
        if (ev.type === 'move') {
          if (drag.kind === 'move') push({ type: 'drag', dx: ev.x - drag.x0 })
          else {
            const c = drag.kind === 'resize-y' ? drag.cols0 : Math.max(4, drag.cols0 + ev.x - drag.x0)
            const r = drag.kind === 'resize-x' ? drag.rows0 : Math.max(2, drag.rows0 + ev.y - drag.y0)
            push({ type: 'resize', cols: c, rows: r, axis: drag.kind })
          }
        } else if (ev.type === 'up') {
          push({ type: drag.kind === 'move' ? 'dragend' : 'resizeend' })
          drag = undefined
        }
        return
      }
      if (ev.type === 'down') {
        if (ev.y === 0 && ev.x === cols) {
          push({ type: 'close' })
          return
        }
        const onRight = ev.x === cols + 1
        const onBottom = ev.y === rows + 1
        if (onRight || onBottom) {
          drag = { kind: onRight && onBottom ? 'resize-xy' : onRight ? 'resize-x' : 'resize-y', x0: ev.x, y0: ev.y, cols0: cols, rows0: rows }
          return
        }
        if (ev.y === 0) {
          drag = { kind: 'move', x0: ev.x, y0: 0, cols0: cols, rows0: rows }
          return
        }
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

  const { cols, rows, imageId, title, state } = props
  const color = fgHex(imageId)
  const border = state === 'ready' ? 'green' : state === 'starting' ? 'yellow' : 'red'
  // Title, then the count of input events this panel has captured (a quick
  // check that clicks and keys reach it), then the close mark in the corner.
  const seen = surface.state?.count ?? 0
  const label = ` ${title} · ${state} · in:${seen} `.slice(0, Math.max(0, cols - 1))
  const top = `┌${label}${'─'.repeat(Math.max(0, cols - 1 - label.length))}×┐`
  // The corner and edges are the resize handles; the title row is the move
  // handle. Plain box drawing: the handles need no marker.
  const bottom = `└${'─'.repeat(cols)}┘`
  const lines = []
  for (let r = 0; r < rows; r++) lines.push(rowText(r, cols))
  return (
    <Box flexDirection="column">
      <Text color={border}>{top}</Text>
      {lines.map(line => (
        <Text>
          <Text color={border}>│</Text>
          <Text color={color}>{line}</Text>
          <Text color={border}>│</Text>
        </Text>
      ))}
      <Text color={border}>{bottom}</Text>
    </Box>
  )
}
