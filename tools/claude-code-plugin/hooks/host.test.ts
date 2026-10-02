import { test } from 'node:test'
import assert from 'node:assert/strict'
import { chooseRoute, frameSource, inputSince, newInputEvents, parseFrame, uploadLabel, parseCellAspect, parseClient, parseEvents, parseHostFile, parseSessions, parseStandin, stripNumbers } from './host.ts'

test('parseHostFile accepts the wm host file and rejects junk', () => {
  assert.deepEqual(parseHostFile('{"pid":12,"port":4567,"token":"abc","tty":"ttys007","socket":"/tmp/k.sock"}'),
    { pid: 12, port: 4567, token: 'abc', tty: 'ttys007', socket: '/tmp/k.sock' })
  assert.equal(parseHostFile('{"pid":12,"port":4567}'), null)
  assert.equal(parseHostFile('{"pid":"12","port":4567,"token":"x"}'), null)
  assert.equal(parseHostFile('not json'), null)
  assert.equal(parseHostFile('[]'), null)
})

test('a wrapping host names the stand-in placeholder', () => {
  const wrapped = parseHostFile('{"pid":12,"port":4567,"token":"abc","placeholder_standin":"10EEED"}')
  assert.equal(wrapped?.placeholder, '\u{10EEED}')
  // No field, the real placeholder, or a codepoint outside private use: none.
  assert.equal(parseHostFile('{"pid":12,"port":4567,"token":"abc"}')?.placeholder, undefined)
  assert.equal(parseStandin('10EEEE'), undefined)
  assert.equal(parseStandin('41'), undefined)
  assert.equal(parseStandin('0041'), undefined)
  assert.equal(parseStandin('1b'), undefined)
  assert.equal(parseStandin(0x10eeed), undefined)
  assert.equal(parseStandin('E000'), '\u{E000}')
})

test('a new panel instance has its input counted from the start', () => {
  // Same instance: only events after the last one sent.
  assert.equal(inputSince(41, 41, 120), 120)
  // A remounted panel numbers from one again; nothing of it was sent yet.
  assert.equal(inputSince(41, 77, 120), 0)
  assert.equal(inputSince(undefined, 77, 0), 0)
  // A panel that names no instance keeps the old behaviour.
  assert.equal(inputSince(41, undefined, 120), 120)
  const fresh = newInputEvents([{ n: 1, type: 'key', key: 'a' }], inputSince(41, 77, 120))
  assert.deepEqual(fresh.events.map(ev => ev.n), [1])
})

test('the route follows the wish only where the host can serve it', () => {
  const wrapping = parseHostFile('{"pid":1,"port":2,"token":"t","placeholder_standin":"10EEED","image_claim":true}') ?? undefined
  const background = parseHostFile('{"pid":1,"port":2,"token":"t"}') ?? undefined
  assert.equal(wrapping?.imageClaim, true)
  assert.equal(background?.imageClaim, undefined)
  assert.equal(chooseRoute(wrapping, 'auto', true), 'claim')
  assert.equal(chooseRoute(wrapping, 'claim', true), 'claim')
  // A host that only rewrites: the stand-in is the best it offers.
  const rewriting = parseHostFile('{"pid":1,"port":2,"token":"t","placeholder_standin":"10EEED"}') ?? undefined
  assert.equal(chooseRoute(rewriting, 'auto', true), 'standin')
  assert.equal(chooseRoute(rewriting, 'claim', true), 'standin')
  assert.equal(chooseRoute(wrapping, 'standin', true), 'standin')
  assert.equal(chooseRoute(wrapping, 'direct', true), 'direct')
  assert.equal(chooseRoute(background, 'auto', true), 'direct')
  assert.equal(chooseRoute(background, 'claim', true), 'direct')
  assert.equal(chooseRoute(background, 'standin', true), 'direct')
  assert.equal(chooseRoute(undefined, 'claim', true), 'direct')
  // An application with no image element cannot take a claim.
  assert.equal(chooseRoute(wrapping, 'auto', false), 'standin')
  assert.equal(chooseRoute(wrapping, 'claim', false), 'standin')
})

test('frames are swapped in by name where there is no wrapper to claim through', () => {
  const delivering = parseHostFile('{"pid":1,"port":2,"token":"t","frame_delivery":true}') ?? undefined
  const wrapping = parseHostFile('{"pid":1,"port":2,"token":"t","placeholder_standin":"10EEED","image_claim":true,"frame_delivery":true}') ?? undefined
  assert.equal(delivering?.frameDelivery, true)
  // No wrapper: the only route an application that refuses the placeholder accepts.
  assert.equal(chooseRoute(delivering, 'auto', true), 'blit')
  assert.equal(chooseRoute(delivering, 'claim', true), 'blit')
  // An application without images keeps the placeholder, as before.
  assert.equal(chooseRoute(delivering, 'auto', false), 'direct')
  assert.equal(chooseRoute(delivering, 'blit', false), 'direct')
  assert.equal(chooseRoute(delivering, 'direct', true), 'direct')
  // Under the wrapper a claim wins unless blit is asked for by name.
  assert.equal(chooseRoute(wrapping, 'auto', true), 'claim')
  assert.equal(chooseRoute(wrapping, 'blit', true), 'blit')
  assert.equal(chooseRoute(wrapping, 'standin', true), 'standin')
})

test('a frame reply becomes an image source, or nothing', () => {
  const file = parseFrame('{"seq":107,"medium":"file","name":"/tmp/k/s2/frame.rgba.3","format":"rgba","width":640,"height":480}')
  assert.deepEqual(file, { seq: 107, medium: 'file', name: '/tmp/k/s2/frame.rgba.3', width: 640, height: 480 })
  assert.deepEqual(frameSource(file!), { file: '/tmp/k/s2/frame.rgba.3', format: 'rgba', width: 640, height: 480, generation: 107 })
  const shm = parseFrame('{"seq":8,"medium":"shm","name":"/ks1f2a-9","format":"rgba","width":64,"height":32}')
  assert.deepEqual(frameSource(shm!), { shm: '/ks1f2a-9', format: 'rgba', width: 64, height: 32 })
  // No newer frame yet, and replies that would make a bad source.
  assert.equal(parseFrame('{"seq":null}'), null)
  assert.equal(parseFrame('nope'), null)
  assert.equal(parseFrame('{"seq":1,"medium":"file","name":"relative","width":1,"height":1}'), null)
  assert.equal(parseFrame('{"seq":1,"medium":"shm","name":"/bad name","width":1,"height":1}'), null)
  assert.equal(parseFrame('{"seq":1,"medium":"file","name":"/x","width":5000,"height":1}'), null)
  assert.equal(parseFrame('{"seq":1,"medium":"pipe","name":"/x","width":1,"height":1}'), null)
  // The host never hands over a name longer than its own bound.
  assert.equal(parseFrame(JSON.stringify({ seq: 1, medium: 'file', name: '/' + 'a'.repeat(256), width: 1, height: 1 })), null)
  assert.notEqual(parseFrame(JSON.stringify({ seq: 1, medium: 'file', name: '/' + 'a'.repeat(255), width: 1, height: 1 })), null)
})

test('a session names its transport as shared memory or files', () => {
  const one = (upload: unknown) => parseSessions(JSON.stringify([{ id: 1, image_id: 100001, state: 'ready', upload }]))[0]
  assert.equal(uploadLabel(one('shm')?.upload), 'shared memory')
  assert.equal(uploadLabel(one('file_whole')?.upload), 'files')
  assert.equal(uploadLabel(one('file_offset_ring')?.upload), 'files')
  // An older host says nothing.
  assert.equal(uploadLabel(one(undefined)?.upload), 'transport unknown')
  assert.equal(uploadLabel(one('direct_apc')?.upload), 'transport unknown')
})

test('a session carries its claim file only when well formed', () => {
  const one = (claim: unknown) => parseSessions(JSON.stringify([{ id: 1, image_id: 100001, state: 'ready', claim }]))[0]
  assert.deepEqual(one({ path: '/tmp/h/s1/claim.rgba', w: 1, h: 1 })?.claim, { path: '/tmp/h/s1/claim.rgba', w: 1, h: 1 })
  assert.equal(one(undefined)?.claim, undefined)
  assert.equal(one(null)?.claim, undefined)
  assert.equal(one({ path: 'relative.rgba', w: 1, h: 1 })?.claim, undefined)
  assert.equal(one({ path: '/tmp/x', w: 0, h: 1 })?.claim, undefined)
  assert.equal(one({ path: '/tmp/x', w: 1, h: 5000 })?.claim, undefined)
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
    { id: 2, input_supported: false, image_id: 100001, state: 'closing', source_px: null, grid: null },
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
  assert.equal(s[0]!.input_supported, true)
  assert.equal(s[1]!.input_supported, false)
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
