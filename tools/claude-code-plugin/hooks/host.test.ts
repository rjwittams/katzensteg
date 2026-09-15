import { test } from 'node:test'
import assert from 'node:assert/strict'
import { newInputEvents, parseCellAspect, parseClient, parseEvents, parseHostFile, parseSessions, stripNumbers } from './host.ts'

test('parseHostFile accepts the wm host file and rejects junk', () => {
  assert.deepEqual(parseHostFile('{"pid":12,"port":4567,"token":"abc","tty":"ttys007","socket":"/tmp/k.sock"}'),
    { pid: 12, port: 4567, token: 'abc', tty: 'ttys007', socket: '/tmp/k.sock' })
  assert.equal(parseHostFile('{"pid":12,"port":4567}'), null)
  assert.equal(parseHostFile('{"pid":"12","port":4567,"token":"x"}'), null)
  assert.equal(parseHostFile('not json'), null)
  assert.equal(parseHostFile('[]'), null)
})

test('parseClient accepts the client record and normalises the target', () => {
  assert.deepEqual(parseClient('{"id":7,"target":"/tmp/k.sock","lease_ms":120000}'), { id: '7', target: 'jsonl:/tmp/k.sock', lease_ms: 120000 })
  assert.deepEqual(parseClient('{"id":"c1","target":"jsonl:/tmp/k.sock"}'), { id: 'c1', target: 'jsonl:/tmp/k.sock', lease_ms: 120000 })
  assert.equal(parseClient('{"id":7}'), null)
  assert.equal(parseClient('nope'), null)
})

test('parseCellAspect reads the cell size from health', () => {
  assert.equal(parseCellAspect('{"pid":1,"cell_px":{"w":8,"h":16}}'), 0.5)
  assert.equal(parseCellAspect('{"pid":1,"cell_px":null}'), undefined)
  assert.equal(parseCellAspect('{"pid":1}'), undefined)
  assert.equal(parseCellAspect('x'), undefined)
})

test('parseSessions keeps well-formed sessions only', () => {
  const text = JSON.stringify([
    { id: 1, title: 'mi2', image_id: 100000, state: 'ready', source_px: { w: 640, h: 480 }, grid: { cols: 40, rows: 15 } },
    { id: 2, image_id: 100001, state: 'closing', source_px: null, grid: null },
    { id: 3, image_id: 1, state: 'weird' },
    { id: true, image_id: 1, state: 'ready' },
    'nope',
  ])
  const s = parseSessions(text)
  assert.equal(s.length, 2)
  assert.equal(s[0]!.id, '1')
  assert.equal(s[0]!.title, 'mi2')
  assert.deepEqual(s[0]!.grid, { cols: 40, rows: 15 })
  assert.equal(s[1]!.title, '2')
  assert.equal(s[1]!.state, 'closing')
  assert.equal(s[1]!.source_px, null)
  assert.deepEqual(parseSessions('garbage'), [])
})

test('parseEvents returns events in order and the highest seq', () => {
  const r = parseEvents('{"events":[{"seq":3,"type":"ready","session":"s1"},{"seq":4,"type":"exited","session":"s1"},{"bad":true}]}', 2)
  assert.equal(r.seq, 4)
  assert.deepEqual(r.events.map(e => e.type), ['ready', 'exited'])
  assert.deepEqual(parseEvents('{"events":[]}', 7), { events: [], seq: 7 })
  assert.deepEqual(parseEvents('x', 7), { events: [], seq: 7 })
})

test('newInputEvents forwards only events after the last number, in order', () => {
  const posted = [
    { n: 3, type: 'pointer', kind: 'down', x: 1, y: 2, button: 'left' },
    { n: 1, type: 'key', key: 'a' },
    { n: 2, type: 'key', key: 'b' },
    { n: 4, type: 'bogus' },
  ]
  const first = newInputEvents(posted, 0)
  assert.deepEqual(first.events.map(e => e.n), [1, 2, 3])
  assert.equal(first.lastN, 3)
  const again = newInputEvents(posted, 3)
  assert.deepEqual(again.events, [])
  assert.equal(again.lastN, 3)
  assert.deepEqual(stripNumbers(first.events)[0], { type: 'key', key: 'a' })
  assert.deepEqual(newInputEvents('nope', 5), { events: [], lastN: 5 })
})
