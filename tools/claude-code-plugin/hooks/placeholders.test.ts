import { test } from 'node:test'
import assert from 'node:assert/strict'
import { fgHex, fitGrid, MAX_GRID, rowText } from './placeholders.ts'
import { DIACRITICS, PLACEHOLDER } from './diacritics.ts'

test('fgHex encodes the id as a 24-bit colour', () => {
  assert.equal(fgHex(777), '#000309')
  assert.equal(fgHex(0xffffff), '#ffffff')
  assert.equal(fgHex(0x1000001), '#000001')
})

test('rowText carries row and column diacritics on every cell', () => {
  const row = rowText(2, 3)
  const cells = [...row.matchAll(new RegExp(`${PLACEHOLDER}(.)(.)`, 'gu'))]
  assert.equal(cells.length, 3)
  for (const [i, m] of cells.entries()) {
    assert.equal(m[1], DIACRITICS[2])
    assert.equal(m[2], DIACRITICS[i])
  }
  assert.equal(rowText(0, 0), '')
})

test('fitGrid keeps the source aspect inside the box', () => {
  // 640x480 at cell aspect 0.5: width in cells is 2 * 4/3 * rows
  assert.deepEqual(fitGrid({ w: 640, h: 480 }, 200, 15), { cols: 40, rows: 15 })
  // width-bound: 200 cols -> rows = 200 * 0.5 / (4/3) = 75
  assert.deepEqual(fitGrid({ w: 640, h: 480 }, 60, 100), { cols: 60, rows: 23 })
  assert.deepEqual(fitGrid(null, 80, 20), { cols: 80, rows: 20 })
  assert.deepEqual(fitGrid({ w: 0, h: 0 }, 80, 20), { cols: 80, rows: 20 })
})

test('fitGrid never exceeds the diacritic table or drops below one cell', () => {
  assert.deepEqual(fitGrid(null, 1000, 1000), { cols: MAX_GRID, rows: MAX_GRID })
  assert.deepEqual(fitGrid({ w: 1, h: 1000 }, 0, 0), { cols: 1, rows: 1 })
  const g = fitGrid({ w: 16, h: 9 }, 5, 400)
  assert.ok(g.cols >= 1 && g.cols <= 5 && g.rows >= 1)
})
