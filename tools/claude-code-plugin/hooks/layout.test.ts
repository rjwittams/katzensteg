import { test } from 'node:test'
import assert from 'node:assert/strict'
import { dragSwap, ordered, swapOnPointer } from './layout.ts'

const sizes = new Map([['a', 20], ['b', 20], ['big', 30], ['small', 10]])

test('between panels of one size, the swap comes as the pointer enters the neighbour', () => {
  // a spans 0..19, the gap is cell 20, b starts at 21.
  assert.deepEqual(swapOnPointer(['a', 'b'], 'a', 19, sizes), ['a', 'b'])
  assert.deepEqual(swapOnPointer(['a', 'b'], 'a', 20, sizes), ['a', 'b'])
  assert.deepEqual(swapOnPointer(['a', 'b'], 'a', 21, sizes), ['b', 'a'])
  // The region moved 21 cells, so that pointer now reports 0: over the panel itself, stable.
  assert.deepEqual(swapOnPointer(['b', 'a'], 'a', 0, sizes), ['b', 'a'])
  // Going back: the gap is cell -1, b's last cell is -2.
  assert.deepEqual(swapOnPointer(['b', 'a'], 'a', -1, sizes), ['b', 'a'])
  assert.deepEqual(swapOnPointer(['b', 'a'], 'a', -2, sizes), ['a', 'b'])
  // And that pointer is then at 19, on the panel's own last cell.
  assert.deepEqual(swapOnPointer(['a', 'b'], 'a', -2 + 21, sizes), ['a', 'b'])
})

test('a stack has no gap: the row after the panel is the neighbour', () => {
  assert.deepEqual(swapOnPointer(['a', 'b'], 'a', 19, sizes, 0), ['a', 'b'])
  assert.deepEqual(swapOnPointer(['a', 'b'], 'a', 20, sizes, 0), ['b', 'a'])
  assert.deepEqual(swapOnPointer(['b', 'a'], 'a', -1, sizes, 0), ['a', 'b'])
})

test('past a larger neighbour the pointer must reach where the panel will land', () => {
  // a (20) before big (30), stacked: big would move up and a start at 30.
  assert.deepEqual(swapOnPointer(['a', 'big'], 'a', 20, sizes, 0), ['a', 'big'])
  assert.deepEqual(swapOnPointer(['a', 'big'], 'a', 29, sizes, 0), ['a', 'big'])
  assert.deepEqual(swapOnPointer(['a', 'big'], 'a', 30, sizes, 0), ['big', 'a'])
  // Then the pointer reports 0: on the panel, so it does not swap back.
  assert.deepEqual(swapOnPointer(['big', 'a'], 'a', 0, sizes, 0), ['big', 'a'])
  // Upward into big: a would take big's first 20 rows, so the pointer must be in those.
  assert.deepEqual(swapOnPointer(['big', 'a'], 'a', -1, sizes, 0), ['big', 'a'])
  assert.deepEqual(swapOnPointer(['big', 'a'], 'a', -10, sizes, 0), ['big', 'a'])
  assert.deepEqual(swapOnPointer(['big', 'a'], 'a', -11, sizes, 0), ['a', 'big'])
  // That pointer is then at 19, still on the panel.
  assert.deepEqual(swapOnPointer(['a', 'big'], 'a', -11 + 30, sizes, 0), ['a', 'big'])
})

test('past a smaller neighbour the swap comes on entering it, either way', () => {
  assert.deepEqual(swapOnPointer(['a', 'small'], 'a', 20, sizes, 0), ['small', 'a'])
  assert.deepEqual(swapOnPointer(['small', 'a'], 'a', -1, sizes, 0), ['a', 'small'])
  // No swap straight back in either case.
  assert.deepEqual(swapOnPointer(['small', 'a'], 'a', 20 - 10, sizes, 0), ['small', 'a'])
  assert.deepEqual(swapOnPointer(['a', 'small'], 'a', -1 + 10, sizes, 0), ['a', 'small'])
})

test('a pointer that crossed several panels crosses them all, and unknown ids change nothing', () => {
  // a, b, small stacked: b starts at 20, small at 40.
  assert.deepEqual(swapOnPointer(['a', 'b', 'small'], 'a', 39, sizes, 0), ['b', 'a', 'small'])
  assert.deepEqual(swapOnPointer(['a', 'b', 'small'], 'a', 40, sizes, 0), ['b', 'small', 'a'])
  assert.deepEqual(swapOnPointer(['small', 'b', 'a'], 'a', -21, sizes, 0), ['a', 'small', 'b'])
  assert.deepEqual(swapOnPointer(['a', 'b'], 'zz', 40, sizes), ['a', 'b'])
  // At either end there is nothing further to trade with.
  assert.deepEqual(swapOnPointer(['b', 'a'], 'a', 500, sizes), ['b', 'a'])
  assert.deepEqual(swapOnPointer(['a', 'b'], 'a', -500, sizes), ['a', 'b'])
})

test('after a swap the pointer is reported from the panel\'s new place', () => {
  // b (20) below a (20), stacked. One row above b is a's last row; swapped,
  // b starts where a did, 20 rows up, so the pointer is on b's own row 19.
  assert.deepEqual(dragSwap(['a', 'b'], 'b', -1, sizes, 0), { order: ['b', 'a'], at: 19 })
  assert.deepEqual(dragSwap(['a', 'b'], 'a', 20, sizes, 0), { order: ['b', 'a'], at: 0 })
  // No swap: the position is unchanged.
  assert.deepEqual(dragSwap(['a', 'b'], 'a', 7, sizes, 0), { order: ['a', 'b'], at: 7 })
  // Two panels crossed in one motion.
  assert.deepEqual(dragSwap(['a', 'b', 'small'], 'a', 40, sizes, 0), { order: ['b', 'small', 'a'], at: 10 })
})

test('ordered keeps known order and appends newcomers', () => {
  const s = [{ id: 'c' }, { id: 'a' }, { id: 'n' }, { id: 'b' }]
  assert.deepEqual(ordered(['a', 'b', 'c'], s).map(x => x.id), ['a', 'b', 'c', 'n'])
})
