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
  return next
}

/** Sessions in band order: known ids first in their order, new ones after. */
export function ordered<T extends { id: string }>(order: readonly string[], sessions: readonly T[]): T[] {
  const rank = new Map(order.map((id, i) => [id, i]))
  return [...sessions].sort((a, b) => (rank.get(a.id) ?? Infinity) - (rank.get(b.id) ?? Infinity))
}
