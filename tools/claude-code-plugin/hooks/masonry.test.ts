import { test } from 'node:test'
import assert from 'node:assert/strict'
import { dropEmptyLanes, fitLanes, flowOrder, laneStart, lanesWidth, moveInLanes, placeLanes, resizeLane, resolveAuto, syncLanes, type Lane, type Sizer } from './masonry.ts'

// Every panel is as wide as its lane and half as tall, unless named tall.
const size: Sizer = (id, width) => ({ cols: width, rows: id.startsWith('tall') ? width : Math.round(width / 2) })
const ids = () => { let n = 10; return () => n++ }
const lane = (id: number, width: number, items: string[], auto = false): Lane => ({ id, width, auto, items })
const brief = (lanes: Lane[]) => lanes.map(l => `${l.width}:${l.items.join(',')}`).join(' | ')

test('a new panel joins the shortest lane and nothing placed moves', () => {
  const next = ids()
  let lanes = syncLanes([], ['a'], size, () => 30, next)
  assert.equal(brief(lanes), '30:a')
  assert.equal(lanes[0]?.auto, true)
  lanes = syncLanes(lanes, ['a', 'b'], size, () => 30, next)
  assert.equal(brief(lanes), '30:a,b')
  // Two lanes: the new panel goes to the shorter, the rest stay.
  const two = [lane(1, 30, ['a', 'b']), lane(2, 30, ['c'])]
  assert.equal(brief(syncLanes(two, ['a', 'b', 'c', 'd'], size, () => 30, next)), '30:a,b | 30:c,d')
  // A panel that is gone leaves; a lane left empty goes with it.
  assert.equal(brief(syncLanes(two, ['a', 'b'], size, () => 30, next)), '30:a,b')
  // Unless a move is on: the lane stays as a slot.
  assert.equal(brief(syncLanes(two, ['a', 'b'], size, () => 30, next, true)), '30:a,b | 30:')
  assert.deepEqual(syncLanes(two, [], size, () => 30, next), [])
})

test('auto lanes follow the preset width until dragged', () => {
  const lanes = [lane(1, 30, ['a'], true), lane(2, 30, ['b'], false)]
  assert.equal(brief(resolveAuto(lanes, () => 44)), '44:a | 30:b')
})

test('lanes that do not fit: the last is squeezed, then pushed into the one before', () => {
  const lanes = [lane(1, 30, ['a']), lane(2, 30, ['b']), lane(3, 30, ['c'])]
  assert.equal(lanesWidth(lanes), 92)
  assert.equal(laneStart(lanes, 2), 62)
  // Fits: untouched.
  assert.equal(brief(fitLanes(lanes, 92)), '30:a | 30:b | 30:c')
  // Ten too many: only the last lane gives.
  assert.equal(brief(fitLanes(lanes, 82)), '30:a | 30:b | 20:c')
  // At its minimum it would still not fit: its panels join the lane before.
  assert.equal(brief(fitLanes(lanes, 70)), '30:a | 30:b,c')
  // And again if that is still too wide.
  assert.equal(brief(fitLanes(lanes, 50)), '30:a | 19:b,c')
  assert.equal(brief(fitLanes(lanes, 40)), '30:a,b,c')
  // One lane is only made no wider than the pane.
  assert.equal(brief(fitLanes(lanes, 25)), '25:a,b,c')
})

test('panels are placed lane by lane from the top', () => {
  const places = placeLanes([lane(1, 30, ['a', 'b']), lane(2, 20, ['c'])], size)
  assert.deepEqual(places.get('a'), { col: 0, row: 1, cols: 30, rows: 15 })
  assert.deepEqual(places.get('b'), { col: 0, row: 16, cols: 30, rows: 15 })
  assert.deepEqual(places.get('c'), { col: 31, row: 1, cols: 20, rows: 10 })
})

test('a move goes to the lane under the pointer, after the panels whose middle is above it', () => {
  const next = ids()
  const lanes = [lane(1, 30, ['a', 'b']), lane(2, 30, ['c', 'd'])]
  // Over the second lane, above c's middle (c spans rows 1..15, middle 8.5).
  assert.equal(brief(moveInLanes(lanes, 'a', 40, 5, size, 100, next).lanes), '30:b | 30:a,c,d')
  // Below c's middle and above d's (d: rows 16..30, middle 23.5).
  assert.equal(brief(moveInLanes(lanes, 'a', 40, 12, size, 100, next).lanes), '30:b | 30:c,a,d')
  assert.equal(brief(moveInLanes(lanes, 'a', 40, 40, size, 100, next).lanes), '30:b | 30:c,d,a')
  // Within its own lane, measured without the moving panel: no flip.
  assert.equal(moveInLanes(lanes, 'a', 5, 5, size, 100, next).changed, false)
  assert.equal(brief(moveInLanes(lanes, 'a', 5, 12, size, 100, next).lanes), '30:b,a | 30:c,d')
  const moved = moveInLanes(lanes, 'a', 5, 12, size, 100, next).lanes
  assert.equal(moveInLanes(moved, 'a', 5, 12, size, 100, next).changed, false)
  // The gap between lanes belongs to neither.
  assert.equal(moveInLanes(lanes, 'a', 30, 5, size, 100, next).changed, false)
})

test('dragging right of the last lane makes a lane when there is room', () => {
  const next = ids()
  const lanes = [lane(1, 30, ['a', 'b']), lane(2, 20, ['c'])]
  // 51 used of 100: room for a lane, as wide as the one the panel left.
  const made = moveInLanes(lanes, 'a', 60, 4, size, 100, next)
  assert.equal(brief(made.lanes), '30:b | 20:c | 30:a')
  assert.equal(made.lanes[2]?.auto, false)
  // Less room than that: the lane takes what is left.
  assert.equal(brief(moveInLanes(lanes, 'a', 60, 4, size, 70, next).lanes), '30:b | 20:c | 18:a')
  // Not enough for the minimum: nothing happens.
  assert.equal(moveInLanes(lanes, 'a', 60, 4, size, 60, next).changed, false)
  // The lane it left is kept as a slot until the release.
  const only = moveInLanes([lane(1, 30, ['a']), lane(2, 20, ['c'])], 'a', 60, 4, size, 100, next).lanes
  assert.equal(brief(only), '30: | 20:c | 30:a')
  assert.equal(brief(dropEmptyLanes(only)), '20:c | 30:a')
  assert.equal(brief(dropEmptyLanes([lane(1, 30, [])])), '30:')
})

test('a side edge sizes the whole lane, within the minimum and the free columns', () => {
  const lanes = [lane(1, 30, ['a', 'b'], true), lane(2, 20, ['c'])]
  const wider = resizeLane(lanes, 'b', 40, 100)
  assert.equal(brief(wider), '40:a,b | 20:c')
  assert.equal(wider[0]?.auto, false)
  // 49 columns free: it cannot take more.
  assert.equal(brief(resizeLane(lanes, 'b', 200, 100)), '79:a,b | 20:c')
  assert.equal(brief(resizeLane(lanes, 'b', 3, 100)), '12:a,b | 20:c')
  assert.equal(brief(resizeLane(lanes, 'zz', 40, 100)), '30:a,b | 20:c')
})

test('the places are drawn as one column of children put in position by margins', () => {
  const places = placeLanes([lane(1, 30, ['a', 'b']), lane(2, 20, ['c', 'tall'])], size)
  const drawn = flowOrder([...places].map(([key, place]) => ({ key, place })))
  // In order of bottom edge: c (ends 11), a (16), b and tall (31).
  assert.deepEqual(drawn.map(d => d.key), ['c', 'a', 'b', 'tall'])
  // Following the margins from the top reproduces every place.
  let below = 1
  for (const d of drawn) {
    assert.equal(below + d.marginTop, d.place.row, d.key)
    assert.equal(d.marginLeft, d.place.col, d.key)
    below = d.place.row + d.place.rows
  }
  // The last child ends where the content does.
  assert.equal(below, Math.max(...[...places.values()].map(p => p.row + p.rows)))
})
