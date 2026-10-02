// Panel order in the band and the reorder-by-drag rule. Pure.

/**
 * A title drag: `at` is where the pointer is along the axis panels are laid
 * out on, in cells from the dragged panel's own start (its left edge in a
 * row, its top edge in a stack); `sizes` are the panels' extents on that axis
 * and `gap` the cells between two panels.
 *
 * The panel trades places with a neighbour when the pointer is over that
 * neighbour and inside the place the dragged panel would take. Between
 * panels of one size that is as soon as the pointer enters the neighbour.
 * Past a larger neighbour the dragged panel lands on its far side, so the
 * pointer has to reach that far: were it to swap sooner, the pointer would be
 * over the neighbour again afterwards and the two would swap straight back.
 *
 * After a swap the panel's region moves, so later reports arrive already
 * relative to the new place; within one call `at` is carried across the swaps
 * made so far, and a pointer that crossed several panels crosses them all.
 */
export function swapOnPointer(order: readonly string[], id: string, at: number, sizes: ReadonlyMap<string, number>, gap = 1): string[] {
  return dragSwap(order, id, at, sizes, gap).order
}

/**
 * `swapOnPointer`, also returning where the pointer is from the dragged
 * panel's start once the swaps are made: what its next report will say, and
 * where to draw the pointer before that report arrives.
 */
export function dragSwap(order: readonly string[], id: string, at: number, sizes: ReadonlyMap<string, number>, gap = 1): { order: string[]; at: number } {
  const next = [...order]
  const self = sizes.get(id) ?? 0
  let rel = at
  for (;;) {
    const i = next.indexOf(id)
    if (i < 0) break
    const after = next[i + 1]
    const before = next[i - 1]
    if (after !== undefined) {
      const size = sizes.get(after) ?? 0
      // The neighbour starts at self + gap; swapped, this panel starts at size + gap.
      if (rel >= Math.max(self, size) + gap) {
        next[i] = after
        next[i + 1] = id
        rel -= size + gap
        continue
      }
    }
    if (before !== undefined) {
      const size = sizes.get(before) ?? 0
      // The neighbour ends before -gap; swapped, this panel spans from
      // -(size + gap) for its own extent.
      if (rel < Math.min(0, self - size) - gap) {
        next[i] = before
        next[i - 1] = id
        rel += size + gap
        continue
      }
    }
    break
  }
  return { order: next, at: rel }
}

/** A panel's place in its site, in cells: the border included. */
export type Place = { col: number; row: number; cols: number; rows: number }

/**
 * Where panels of these sizes sit, in order: a header on row 0, then stacked
 * one per block, or left to right with a one-cell gap, wrapping when the site
 * is too narrow. This mirrors what the tree draws, so a pointer can be placed
 * without waiting for a redraw.
 */
export function placePanels(items: readonly { id: string; cols: number; rows: number }[], stacked: boolean, columns: number): Map<string, Place> {
  const placed = new Map<string, Place>()
  let col = 0
  let row = 1
  let tallest = 0
  for (const { id, cols, rows } of items) {
    if (stacked) {
      placed.set(id, { col: 0, row, cols, rows })
      row += rows
      continue
    }
    if (col > 0 && col + cols > columns) {
      col = 0
      row += tallest
      tallest = 0
    }
    placed.set(id, { col, row, cols, rows })
    col += cols + 1
    tallest = Math.max(tallest, rows)
  }
  return placed
}

export function samePlaces(a: ReadonlyMap<string, Place>, b: ReadonlyMap<string, Place>): boolean {
  if (a.size !== b.size) return false
  for (const [id, p] of a) {
    const q = b.get(id)
    if (!q || q.col !== p.col || q.row !== p.row || q.cols !== p.cols || q.rows !== p.rows) return false
  }
  return true
}

/**
 * One report from a panel being dragged. The pointer is given relative to
 * `origin`, the dragged panel's place in the layout the report was measured
 * in. That may no longer be the current layout: after a swap the plugin
 * knows the new places at once, while reports already on their way are still
 * measured from the old one. So the pointer is first fixed in the site's own
 * cells, and only then compared with where the panels are now. Read against
 * the wrong layout, a report puts the pointer a whole panel away and swaps
 * panels that the next report swaps back.
 *
 * Returns the order after any swap and the pointer in the site's cells.
 */
export function dragReport(
  order: readonly string[],
  id: string,
  origin: Place,
  x: number,
  y: number,
  places: ReadonlyMap<string, Place>,
  stacked: boolean,
): { order: string[]; col: number; row: number } {
  const col = origin.col + x
  const row = origin.row + y
  const now = places.get(id)
  if (!now) return { order: [...order], col, row }
  const sizes = new Map([...places].map(([key, p]) => [key, stacked ? p.rows : p.cols]))
  const at = stacked ? row - now.row : col - now.col
  return { order: dragSwap(order, id, at, sizes, stacked ? 0 : 1).order, col, row }
}

/** The panel at a cell of the site, and the cell within that panel. */
export function panelAt(col: number, row: number, places: ReadonlyMap<string, Place>): { id: string; x: number; y: number } | undefined {
  for (const [id, p] of places) {
    if (col >= p.col && col < p.col + p.cols && row >= p.row && row < p.row + p.rows) return { id, x: col - p.col, y: row - p.row }
  }
  return undefined
}

/** Sessions in band order: known ids first in their order, new ones after. */
export function ordered<T extends { id: string }>(order: readonly string[], sessions: readonly T[]): T[] {
  const rank = new Map(order.map((id, i) => [id, i]))
  return [...sessions].sort((a, b) => (rank.get(a.id) ?? Infinity) - (rank.get(b.id) ?? Infinity))
}
