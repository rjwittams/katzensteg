// Panel order in the band and the reorder-by-drag rule. Pure.

/**
 * A title drag: `dx` is the pointer's horizontal travel in cells since the
 * press, relative to the panel's region. The panel's virtual left edge is at
 * `dx`; it swaps with the right neighbour once its virtual centre passes the
 * neighbour's centre, and with the left one likewise. After a swap the region
 * itself moves, so later reports arrive already relative to the new place;
 * within one call `moved` accounts for swaps made so far. The dead band
 * between swapping over and swapping back is the panel's own width.
 */
export function swapOnDrag(order: readonly string[], id: string, dx: number, widths: ReadonlyMap<string, number>, gap = 1): string[] {
  const next = [...order]
  const self = widths.get(id) ?? 0
  let moved = 0
  for (;;) {
    const i = next.indexOf(id)
    if (i < 0) break
    const rel = dx - moved
    const right = next[i + 1]
    const left = next[i - 1]
    if (right !== undefined && rel > 0) {
      const w = widths.get(right) ?? 0
      if (rel > (self + w) / 2 + gap) {
        next[i] = right
        next[i + 1] = id
        moved += w + gap
        continue
      }
    }
    if (left !== undefined && rel < 0) {
      const w = widths.get(left) ?? 0
      if (-rel > (self + w) / 2 + gap) {
        next[i] = left
        next[i - 1] = id
        moved -= w + gap
        continue
      }
    }
    break
  }
  return next
}

/** Sessions in band order: known ids first in their order, new ones after. */
export function ordered<T extends { id: string }>(order: readonly string[], sessions: readonly T[]): T[] {
  const rank = new Map(order.map((id, i) => [id, i]))
  return [...sessions].sort((a, b) => (rank.get(a.id) ?? Infinity) - (rank.get(b.id) ?? Infinity))
}
