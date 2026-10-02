import { test } from 'node:test'
import assert from 'node:assert/strict'
import { dragFor, dragStep, panelFrame, zoneAt, type Seg } from './frame.ts'

const text = (segs: Seg[]) => segs.map(s => s.text).join('')
const base = { cols: 20, rows: 4, title: 'mi2', status: 'ready · in:0', phase: 0 }

test('zoneAt names every part of the border and the grid inside it', () => {
  // A 20x4 grid: region cells 0..21 by 0..5.
  assert.equal(zoneAt(5, 0, 20, 4), 'title')
  assert.equal(zoneAt(0, 0, 20, 4), 'title')
  assert.equal(zoneAt(20, 0, 20, 4), 'close')
  assert.equal(zoneAt(21, 0, 20, 4), 'right')
  assert.equal(zoneAt(21, 2, 20, 4), 'right')
  assert.equal(zoneAt(21, 5, 20, 4), 'corner')
  assert.equal(zoneAt(7, 5, 20, 4), 'bottom')
  assert.equal(zoneAt(0, 5, 20, 4), 'bottom')
  assert.equal(zoneAt(1, 1, 20, 4), 'grid')
  assert.equal(zoneAt(20, 4, 20, 4), 'grid')
  // The left edge is border but no handle.
  assert.equal(zoneAt(0, 2, 20, 4), 'frame')
})

test('a press starts a drag only on a handle', () => {
  assert.equal(dragFor('title'), 'move')
  assert.equal(dragFor('right'), 'resize-x')
  assert.equal(dragFor('bottom'), 'resize-y')
  assert.equal(dragFor('corner'), 'resize-xy')
  assert.equal(dragFor('close'), undefined)
  assert.equal(dragFor('grid'), undefined)
  assert.equal(dragFor('frame'), undefined)
})

test('a drag ends on its release, and also when the release was plainly missed', () => {
  assert.equal(dragStep('move', true), 'continue')
  assert.equal(dragStep('up', false), 'release')
  assert.equal(dragStep('up', true), 'release')
  // No button held: the release came and went without reaching the panel.
  assert.equal(dragStep('move', false), 'lost')
  // A new press cannot happen while the old one is still down.
  assert.equal(dragStep('down', true), 'lost')
  // Whatever it reports as held, a press during a drag means the release was missed.
  assert.equal(dragStep('down', false), 'lost')
})

test('every row of the frame is as wide as the panel, in every state', () => {
  const states = [{}, { hover: 'title' }, { hover: 'right' }, { hover: 'corner' }, { hover: 'close' }, { drag: 'move' }, { drag: 'resize-x' }, { drag: 'resize-xy' }] as const
  for (const cols of [4, 9, 20, 43]) {
    for (const state of states) {
      const f = panelFrame({ ...base, cols, ...state })
      assert.equal([...text(f.top)].length, cols + 2, `top ${cols} ${JSON.stringify(state)}`)
      assert.equal([...text(f.bottom)].length, cols + 2, `bottom ${cols} ${JSON.stringify(state)}`)
      assert.equal(f.left.length, 4)
      assert.equal(f.right.length, 4)
      for (const seg of [...f.left, ...f.right]) assert.equal([...seg.text].length, 1)
    }
  }
})

test('an idle frame is plain lines in the base tone', () => {
  const f = panelFrame({ ...base, cols: 24 })
  assert.equal(text(f.top), '┌ mi2 · ready · in:0 ───×┐')
  assert.equal(text(f.bottom), '└' + '─'.repeat(24) + '┘')
  assert.ok([...f.top, ...f.left, ...f.right, ...f.bottom].every(s => s.tone === 'base' && !s.bold && !s.inverse))
})

test('the handle under the pointer lights up, and only that one', () => {
  const title = panelFrame({ ...base, hover: 'title' })
  assert.ok(text(title.top).startsWith('┌ ≡ mi2'))
  assert.equal(title.top[0]?.tone, 'accent')
  assert.equal(title.right[0]?.tone, 'base')

  const right = panelFrame({ ...base, hover: 'right' })
  assert.ok(right.right.every(s => s.text === '┃' && s.tone === 'accent'))
  assert.equal(right.top[0]?.tone, 'base')
  assert.ok(text(right.top).endsWith('×┒'))
  assert.ok(text(right.bottom).endsWith('─┚'))

  const bottom = panelFrame({ ...base, hover: 'bottom' })
  assert.equal(text(bottom.bottom), '┕' + '━'.repeat(20) + '┙')
  assert.ok(bottom.right.every(s => s.text === '│'))

  const corner = panelFrame({ ...base, hover: 'corner' })
  assert.equal(text(corner.bottom), '┕' + '━'.repeat(20) + '┛')
  assert.ok(corner.right.every(s => s.text === '┃'))

  const close = panelFrame({ ...base, hover: 'close' })
  assert.deepEqual(close.top[1], { text: '×', tone: 'danger', inverse: true })
  assert.equal(close.top[0]?.tone, 'base')

  // Over the picture or the inert left edge nothing lights.
  for (const hover of ['grid', 'frame'] as const) {
    assert.ok([...panelFrame({ ...base, hover }).top].every(s => s.tone === 'base'))
  }
})

test('a resize shows the size and lights the edges being dragged, whatever is hovered', () => {
  const x = panelFrame({ ...base, drag: 'resize-x', hover: 'title' })
  assert.ok(text(x.top).startsWith('┌ 20×4 '))
  assert.ok(x.right.every(s => s.text === '┃'))
  assert.ok(text(x.bottom).startsWith('└─'))
  const y = panelFrame({ ...base, drag: 'resize-y' })
  assert.ok(text(y.bottom).startsWith('┕━'))
  assert.ok(y.right.every(s => s.text === '│'))
  const both = panelFrame({ ...base, drag: 'resize-xy' })
  assert.ok(text(both.bottom).endsWith('━┛'))
})

test('a picked-up panel has a heavy accent border whose dashes travel with the phase', () => {
  const at = (phase: number) => panelFrame({ ...base, drag: 'move', phase })
  const f = at(0)
  assert.ok(text(f.top).startsWith('┏ ≡ moving mi2 '))
  assert.ok(text(f.top).endsWith('×┓'))
  assert.ok(text(f.bottom).startsWith('┗') && text(f.bottom).endsWith('┛'))
  assert.ok([...f.top, ...f.left, ...f.right, ...f.bottom].every(s => s.tone === 'accent' && s.bold))
  // Solid and dashed cells both appear, and the pattern repeats every four phases.
  const border = (frame: ReturnType<typeof at>) => text(frame.bottom) + text(frame.left) + text(frame.right)
  assert.match(border(f), /━/)
  assert.match(border(f), /╌/)
  assert.match(border(f), /┃/)
  assert.match(border(f), /╎/)
  assert.notEqual(border(at(1)), border(f))
  assert.equal(border(at(4)), border(f))
  // Clockwise: one phase on, the bottom row's pattern has moved one cell left.
  const dashes = (frame: ReturnType<typeof at>) => text(frame.bottom).slice(1, -1)
  assert.equal(dashes(at(1)).slice(0, -1), dashes(f).slice(1))
})

test('a long title is cut to the room between the corner and the close mark', () => {
  const f = panelFrame({ ...base, cols: 6, title: 'a-very-long-title' })
  assert.equal([...text(f.top)].length, 8)
  assert.ok(text(f.top).endsWith('×┐'))
})
