import { test } from 'node:test'
import assert from 'node:assert/strict'
import { ordered, swapOnDrag } from './layout.ts'

const widths = new Map([['a', 20], ['b', 30], ['c', 10]])

test('swapOnDrag swaps once the virtual centre passes the neighbour centre', () => {
  // a (20) over b (30), gap 1: threshold is (20 + 30) / 2 + 1 = 26
  assert.deepEqual(swapOnDrag(['a', 'b', 'c'], 'a', 26, widths), ['a', 'b', 'c'])
  assert.deepEqual(swapOnDrag(['a', 'b', 'c'], 'a', 27, widths), ['b', 'a', 'c'])
  // The region moved right by 31, so the same pointer now reports 27 - 31 = -4: stable.
  assert.deepEqual(swapOnDrag(['b', 'a', 'c'], 'a', -4, widths), ['b', 'a', 'c'])
  // Swapping back needs the centre to pass b's centre the other way: below -26.
  assert.deepEqual(swapOnDrag(['b', 'a', 'c'], 'a', -26, widths), ['b', 'a', 'c'])
  assert.deepEqual(swapOnDrag(['b', 'a', 'c'], 'a', -27, widths), ['a', 'b', 'c'])
})

test('swapOnDrag can cross two neighbours in one motion and ignores unknown ids', () => {
  // past b at 27 (moved 31), then past c needs a further (20 + 10) / 2 + 1 = 16: 47 stays, 48 crosses
  assert.deepEqual(swapOnDrag(['a', 'b', 'c'], 'a', 47, widths), ['b', 'a', 'c'])
  assert.deepEqual(swapOnDrag(['a', 'b', 'c'], 'a', 48, widths), ['b', 'c', 'a'])
  assert.deepEqual(swapOnDrag(['a', 'b'], 'zz', 40, widths), ['a', 'b'])
})

test('ordered keeps known order and appends newcomers', () => {
  const s = [{ id: 'c' }, { id: 'a' }, { id: 'n' }, { id: 'b' }]
  assert.deepEqual(ordered(['a', 'b', 'c'], s).map(x => x.id), ['a', 'b', 'c', 'n'])
})
