// Masonry: panels in lanes. A lane is a column with a width of its own; each
// panel in it takes that width and the height its source's aspect gives.
// One lane is a plain stack, so this is a superset of the stacked pane. Pure.
//
// Lanes are remembered, not recomputed: a panel stays in the lane it was put
// in. The shortest lane only chooses a home for a new panel, and panels move
// between lanes by being dragged.

import type { Place } from './layout.ts'

export type Lane = {
  id: number
  /** Cells wide, the panels' borders included. */
  width: number
  /** The width follows the size preset until the person drags it. */
  auto: boolean
  items: string[]
}

/** A panel's outer size in a lane of the given width. */
export type Sizer = (id: string, laneWidth: number) => { cols: number; rows: number }

/** Cells between two lanes. */
export const LANE_GAP = 1
/** The narrowest a lane is made, by a drag or by a squeeze. */
export const MIN_LANE = 12

const clone = (lanes: readonly Lane[]): Lane[] => lanes.map(lane => ({ ...lane, items: [...lane.items] }))

/** The columns the lanes take, gaps included. */
export const lanesWidth = (lanes: readonly Lane[]): number =>
  lanes.reduce((sum, lane) => sum + lane.width, 0) + LANE_GAP * Math.max(0, lanes.length - 1)

/** The column a lane starts at. */
export const laneStart = (lanes: readonly Lane[], index: number): number =>
  lanes.slice(0, index).reduce((sum, lane) => sum + lane.width + LANE_GAP, 0)

const laneHeight = (lane: Lane, size: Sizer): number => lane.items.reduce((sum, id) => sum + size(id, lane.width).rows, 0)

/**
 * The lanes for the panels now shown. A panel that is gone leaves its lane,
 * and a lane left empty goes too, unless `keepEmpty`: during a move the lane
 * the panel came from stays as a slot until the release. A new panel joins
 * the shortest lane; with no lane yet, one is made, `auto` and as wide as
 * `autoWidth` says for that panel. Nothing already placed moves.
 */
export function syncLanes(
  lanes: readonly Lane[],
  ids: readonly string[],
  size: Sizer,
  autoWidth: (id: string) => number,
  nextId: () => number,
  keepEmpty = false,
): Lane[] {
  const shown = new Set(ids)
  let out = clone(lanes).map(lane => ({ ...lane, items: lane.items.filter(id => shown.has(id)) }))
  if (!keepEmpty) out = out.filter(lane => lane.items.length > 0)
  const placed = new Set(out.flatMap(lane => lane.items))
  for (const id of ids) {
    if (placed.has(id)) continue
    if (out.length === 0) out.push({ id: nextId(), width: autoWidth(id), auto: true, items: [] })
    let shortest = out[0]!
    for (const lane of out) if (laneHeight(lane, size) < laneHeight(shortest, size)) shortest = lane
    shortest.items.push(id)
    placed.add(id)
  }
  return out
}

/** Lanes still `auto` take the width `autoWidth` gives for their first panel. */
export function resolveAuto(lanes: readonly Lane[], autoWidth: (id: string) => number): Lane[] {
  return clone(lanes).map(lane => (lane.auto && lane.items[0] !== undefined ? { ...lane, width: autoWidth(lane.items[0]) } : lane))
}

/**
 * Lanes that fit `columns`. The pane scrolls up and down only, so the widths
 * and gaps must fit across. When they do not, the last lane alone is
 * squeezed, down to the minimum; if it still does not fit, its panels are
 * pushed onto the end of the lane before it and it is gone. A single lane is
 * simply made no wider than the pane.
 */
export function fitLanes(lanes: readonly Lane[], columns: number): Lane[] {
  const out = clone(lanes)
  for (;;) {
    const over = lanesWidth(out) - columns
    if (over <= 0) break
    const last = out[out.length - 1]
    if (!last) break
    if (out.length === 1) {
      last.width = Math.max(1, columns)
      break
    }
    const squeezed = Math.max(MIN_LANE, last.width - over)
    if (last.width - squeezed >= over) {
      last.width = squeezed
      break
    }
    out[out.length - 2]!.items.push(...last.items)
    out.pop()
  }
  return out
}

/** Where each panel sits: lanes left to right, each a stack from row `top`. */
export function placeLanes(lanes: readonly Lane[], size: Sizer, top = 1): Map<string, Place> {
  const places = new Map<string, Place>()
  lanes.forEach((lane, index) => {
    let row = top
    for (const id of lane.items) {
      const { cols, rows } = size(id, lane.width)
      places.set(id, { col: laneStart(lanes, index), row, cols, rows })
      row += rows
    }
  })
  return places
}

/**
 * A move: panel `id` goes to where the pointer is, at cell (`col`, `row`) of
 * the site. The lane is the one under the pointer's column. Right of the last
 * lane, with room for at least the minimum, a new lane is made, as wide as
 * the lane the panel came from or the room left, whichever is less. In the
 * lane, the panel goes after every other panel whose middle is above the
 * pointer; the others are measured as if the moving panel were not there, so
 * the answer does not depend on where it is at the moment and cannot flip.
 * The lane it left is kept even if empty: `dropEmptyLanes` at the release.
 */
export function moveInLanes(
  lanes: readonly Lane[],
  id: string,
  col: number,
  row: number,
  size: Sizer,
  columns: number,
  nextId: () => number,
  top = 1,
): { lanes: Lane[]; changed: boolean } {
  const out = clone(lanes)
  const from = out.findIndex(lane => lane.items.includes(id))
  if (from < 0) return { lanes: out, changed: false }
  let target = out.findIndex((lane, index) => col >= laneStart(out, index) && col < laneStart(out, index) + lane.width)
  let made = false
  if (target < 0) {
    const room = columns - lanesWidth(out) - LANE_GAP
    if (col < lanesWidth(out) + LANE_GAP || room < MIN_LANE) return { lanes: out, changed: false }
    out.push({ id: nextId(), width: Math.min(room, out[from]!.width), auto: false, items: [] })
    target = out.length - 1
    made = true
  }
  const lane = out[target]!
  let at = top
  let index = 0
  for (const other of lane.items) {
    if (other === id) continue
    const { rows } = size(other, lane.width)
    if (at + rows / 2 < row) index += 1
    at += rows
  }
  const was = out[from]!.items.indexOf(id)
  if (!made && from === target && was === index) return { lanes: out, changed: false }
  out[from]!.items.splice(was, 1)
  lane.items.splice(index, 0, id)
  return { lanes: out, changed: true }
}

/** The lanes without the empty ones; the last lane is kept even if empty. */
export function dropEmptyLanes(lanes: readonly Lane[]): Lane[] {
  const out = clone(lanes).filter(lane => lane.items.length > 0)
  return out.length > 0 ? out : clone(lanes).slice(0, 1)
}

/**
 * The lane holding panel `id` made `width` wide, by the person: no narrower
 * than the minimum and no wider than the free columns allow.
 */
export function resizeLane(lanes: readonly Lane[], id: string, width: number, columns: number): Lane[] {
  const out = clone(lanes)
  const lane = out.find(candidate => candidate.items.includes(id))
  if (!lane) return out
  const free = Math.max(0, columns - lanesWidth(out))
  lane.width = Math.max(Math.min(MIN_LANE, lane.width + free), Math.min(width, lane.width + free))
  lane.auto = false
  return out
}

/**
 * How to draw the places as children of ONE column, each put where it belongs
 * by margins. Lanes cannot be containers: a panel that changes parent while
 * it is being dragged stops receiving the pointer. In a column a child sits
 * below the one before it, so its top margin is the distance from there,
 * often negative. Children are in order of their bottom edge, so the last one
 * ends the content and the pane scrolls over all of it.
 */
export function flowOrder<T extends { key: string; place: Place }>(items: readonly T[], top = 1): (T & { marginTop: number; marginLeft: number })[] {
  const sorted = [...items].sort((a, b) => a.place.row + a.place.rows - (b.place.row + b.place.rows) || a.key.localeCompare(b.key))
  let below = top
  return sorted.map(item => {
    const marginTop = item.place.row - below
    below = item.place.row + item.place.rows
    return { ...item, marginTop, marginLeft: item.place.col }
  })
}
