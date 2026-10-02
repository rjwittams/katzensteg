// A panel's border as text: which part of it a cell is, and what it shows
// while idle, hovered, resized or picked up. Pure.
//
// The border is one cell on every side of a `cols` x `rows` grid. The title
// row is the move handle, the right and bottom edges and their corner are the
// resize handles, and the cell before the top-right corner closes the panel.

export type Zone = 'close' | 'title' | 'right' | 'bottom' | 'corner' | 'grid' | 'frame'
export type DragKind = 'move' | 'resize-x' | 'resize-y' | 'resize-xy'

/** The part of the panel at region cell (x, y). */
export function zoneAt(x: number, y: number, cols: number, rows: number): Zone {
  const onRight = x === cols + 1
  const onBottom = y === rows + 1
  if (y === 0 && x === cols) return 'close'
  if (onRight && onBottom) return 'corner'
  if (onRight) return 'right'
  if (onBottom) return 'bottom'
  if (y === 0) return 'title'
  if (x >= 1 && x <= cols && y >= 1 && y <= rows) return 'grid'
  return 'frame'
}

/** What a press on a zone starts, if anything. */
export const dragFor = (zone: Zone): DragKind | undefined =>
  zone === 'title' ? 'move' : zone === 'corner' ? 'resize-xy' : zone === 'right' ? 'resize-x' : zone === 'bottom' ? 'resize-y' : undefined

/**
 * What a pointer event means to a drag in progress. The release ends it and a
 * move with the button held continues it. Anything else, a new press or a move
 * with no button, shows the release never arrived: the surface does not
 * deliver it after a redraw that reorders panels, and a window can lose focus
 * mid-drag. Then the drag is over and the event is handled as an ordinary one.
 */
export function dragStep(type: 'down' | 'move' | 'up', held: boolean): 'continue' | 'release' | 'lost' {
  if (type === 'up') return 'release'
  return type === 'move' && held ? 'continue' : 'lost'
}

/** `base` is the panel's state colour, `accent` a handle in use, `danger` the close mark under the pointer. */
export type Tone = 'base' | 'accent' | 'danger'
export type Seg = { text: string; tone: Tone; bold?: true; inverse?: true }
export type Frame = { top: Seg[]; left: Seg[]; right: Seg[]; bottom: Seg[] }

export type FrameInput = {
  cols: number
  rows: number
  title: string
  /** What follows the title while idle: the session state and such. */
  status: string
  drag?: DragKind
  /** The zone under the pointer; ignored while dragging. */
  hover?: Zone
  /** Advances while a panel is held, to move the dashes round its border. */
  phase: number
}

const GRIP = '≡'

/** What marks the cell the pointer is on while a panel is being moved. */
export const POINTER_MARK: Seg = { text: '+', tone: 'accent', bold: true, inverse: true }

/**
 * A row of segments with the cell at `x` replaced by the pointer mark. A row
 * is read cell by cell: every frame glyph is one cell wide. Outside the row
 * nothing changes.
 */
export function markAt(segs: readonly Seg[], x: number): Seg[] {
  const out: Seg[] = []
  let at = 0
  for (const seg of segs) {
    const cells = [...seg.text]
    if (x < at || x >= at + cells.length) {
      out.push(seg)
    } else {
      const i = x - at
      if (i > 0) out.push({ ...seg, text: cells.slice(0, i).join('') })
      out.push(POINTER_MARK)
      if (i + 1 < cells.length) out.push({ ...seg, text: cells.slice(i + 1).join('') })
    }
    at += cells.length
  }
  return out
}

// Two cells on, two off, travelling clockwise as the phase advances.
const lit = (i: number, phase: number): boolean => (((i - phase) % 4) + 4) % 4 < 2

/**
 * The border for one render. Every row is `cols + 2` cells: `top` and
 * `bottom` are whole rows, `left[r]` and `right[r]` the edge cells of grid
 * row `r`.
 */
export function panelFrame(f: FrameInput): Frame {
  const { cols, rows, phase } = f
  const room = Math.max(0, cols - 1)

  if (f.drag === 'move') {
    // Picked up: heavy accent lines with dashes marching round the border.
    const width = cols + 2
    const horizontal = (i: number) => (lit(i, phase) ? '━' : '╌')
    const vertical = (i: number) => (lit(i, phase) ? '┃' : '╎')
    const label = ` ${GRIP} moving ${f.title} `.slice(0, room)
    let top = '┏' + label
    for (let x = 1 + label.length; x < cols; x++) top += horizontal(x)
    top += '×┓'
    let bottom = '┗'
    for (let x = 1; x <= cols; x++) bottom += horizontal(width + rows + (width - 1 - x))
    bottom += '┛'
    const seg = (text: string): Seg => ({ text, tone: 'accent', bold: true })
    return {
      top: [seg(top)],
      left: Array.from({ length: rows }, (_, r) => seg(vertical(2 * width + rows + (rows - 1 - r)))),
      right: Array.from({ length: rows }, (_, r) => seg(vertical(width + r))),
      bottom: [seg(bottom)],
    }
  }

  const resizing = f.drag !== undefined
  const hot = (zone: Zone) => !resizing && f.hover === zone
  const rightOn = f.drag === 'resize-x' || f.drag === 'resize-xy' || hot('right') || hot('corner')
  const bottomOn = f.drag === 'resize-y' || f.drag === 'resize-xy' || hot('bottom') || hot('corner')
  const titleOn = hot('title')
  const closeOn = hot('close')

  const text = resizing ? ` ${cols}×${rows} ` : titleOn ? ` ${GRIP} ${f.title} · ${f.status} ` : ` ${f.title} · ${f.status} `
  const label = text.slice(0, room)
  const edge = (on: boolean, textOn: string, textOff: string): Seg => (on ? { text: textOn, tone: 'accent', bold: true } : { text: textOff, tone: 'base' })
  return {
    top: [
      { text: '┌' + label + '─'.repeat(room - label.length), tone: titleOn || resizing ? 'accent' : 'base', ...((titleOn || resizing) && { bold: true as const }) },
      closeOn ? { text: '×', tone: 'danger', inverse: true } : { text: '×', tone: 'base' },
      // Down heavy where the right edge is the handle in use.
      edge(rightOn, '┒', '┐'),
    ],
    left: Array.from({ length: rows }, (): Seg => ({ text: '│', tone: 'base' })),
    right: Array.from({ length: rows }, () => edge(rightOn, '┃', '│')),
    bottom: [
      edge(bottomOn, '┕' + '━'.repeat(cols), '└' + '─'.repeat(cols)),
      edge(rightOn || bottomOn, rightOn && bottomOn ? '┛' : rightOn ? '┚' : '┙', '┘'),
    ],
  }
}
