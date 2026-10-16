import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const source = await readFile(new URL('../src/listening.js', import.meta.url), 'utf8');
const { ListeningSequence: Sequence, ListeningDataStore: Store, listeningEntry: entry, listeningFileFingerprint: fingerprint, emptyListeningDocument: empty } = new Function(source + ';return {ListeningSequence,ListeningDataStore,listeningEntry,listeningFileFingerprint,emptyListeningDocument};')();
const entries = n => Array.from({ length: n }, (_, i) => entry(`Folder/Tune${i}.sid`, i % 3));

test('fixed subtunes of one file keep distinct identity and explicit sequences end', () => {
  const a = entry('A.sid', 2), b = entry('A.sid', 0), q = new Sequence({ name: 'Subtunes', entries: [a,b] });
  assert.equal(q.current.subtune, 2); assert.deepEqual(q.next(), b); assert.deepEqual(q.previous(), a);
  q.next(); assert.equal(q.next(), null);
});
test('shuffle from a middle entry visits every entry exactly once', () => {
  const items = entries(100), q = new Sequence({ name: 'Shuffle', entries: items, startingAt: 45, shuffled: true });
  assert.equal(q.current.id, items[45].id);
  const heard = [q.current.id]; while (q.next()) heard.push(q.current.id);
  assert.equal(heard.length, 100); assert.deepEqual(new Set(heard), new Set(items.map(e => e.id)));
});
test('library cycles avoid an immediate repetition at their boundary', () => {
  const items = entries(12), q = new Sequence({ name: 'Library', kind: 'library', entries: items, shuffled: true, wraps: true });
  for (let cycle = 0; cycle < 10; cycle++) {
    const heard = [q.current.id]; for (let i = 1; i < items.length; i++) heard.push(q.next().id);
    assert.equal(new Set(heard).size, 12); assert.notEqual(q.next().id, heard.at(-1));
  }
});
test('next requests are FIFO and disappear on the next normal cycle', () => {
  const items = entries(2), q = new Sequence({ name: 'Library', entries: items, wraps: true });
  q.enqueueNext(entry('NextA.sid', 2)); q.enqueueNext(entry('NextB.sid', 0));
  assert.equal(q.next().trackID, 'NextA.sid'); assert.equal(q.next().trackID, 'NextB.sid');
  assert.equal(q.next().id, items[1].id); assert.equal(q.next().id, items[0].id);
  assert.equal(q.items.length, 2); assert.equal(q.oneShotIDs.length, 0);
});
test('shuffle restart keeps pending next requests but abandons old position', () => {
  const q = new Sequence({ name: 'Restart', entries: entries(5), startingAt: 3 });
  q.enqueueNext(entry('Pending.sid', 2)); q.restart(true, true);
  assert.equal(q.currentIndex, 0); assert.equal(q.next().trackID, 'Pending.sid');
});
test('reorder and removal preserve the current entry', () => {
  const items = entries(4), q = new Sequence({ name: 'Order', entries: items, startingAt: 1 });
  q.move(items[3].id, -2); q.remove(items[0].id); q.remove(items[1].id);
  assert.equal(q.current.id, items[1].id); assert.equal(q.next().id, items[2].id);
});
test('editing a list template leaves the running copy untouched', () => {
  const items = entries(3), q = new Sequence({ name: 'Copy', entries: items });
  items[0].subtune = 99; items.reverse();
  assert.equal(q.current.subtune, 0); assert.notDeepEqual(q.items.map(e => e.id), items.map(e => e.id));
});
test('roundtrip preserves queue order and pending requests without file buffers', () => {
  let raw = null; const storage = { getItem: () => raw, setItem: (_, value) => { raw = value; } };
  const store = new Store(storage), q = new Sequence({ name: 'Roundtrip', entries: entries(5), startingAt: 2 });
  q.enqueueNext(entry('Next.sid', 4)); store.document.queue = q; assert.equal(store.save(), true);
  const restored = new Store(storage), queue = Sequence.fromJSON(restored.document.queue);
  assert.equal(queue.current.subtune, 2); assert.equal(queue.next().trackID, 'Next.sid');
  assert.equal(raw.includes('buffer'), false);
});
test('corrupt or future data remains untouched and read only', () => {
  for (const raw of ['{broken', JSON.stringify({ ...empty(), version: 99 })]) {
    let writes = 0; const store = new Store({ getItem: () => raw, setItem: () => writes++ });
    assert.equal(store.readOnly, true); assert.equal(store.save(), false); assert.equal(writes, 0);
  }
});
test('unavailable storage and quota failures are visible without losing session data', () => {
  const blocked = new Store({ getItem() { throw new Error('blocked'); } });
  assert.match(blocked.error, /temporary/); assert.equal(blocked.save(), false);
  const full = new Store({ getItem: () => null, setItem() { throw new Error('quota'); } });
  full.document.queue = new Sequence({ name: 'Unsaved', entries: entries(2) });
  assert.equal(full.save(), false); assert.equal(full.document.queue.items.length, 2); assert.match(full.error, /could not be saved/);
});
test('a stale page cannot overwrite another page or a newer data version', () => {
  let raw = null;
  const storage = { getItem: () => raw, setItem: (_, value) => { raw = value; } };
  const first = new Store(storage), second = new Store(storage);
  first.document.queue = new Sequence({ name: 'First page', entries: entries(2) });
  assert.equal(first.save(), true); const saved = raw;
  assert.equal(second.save(), false); assert.equal(second.readOnly, true); assert.equal(raw, saved);
  raw = JSON.stringify({ version: 99 });
  assert.equal(first.save(), false); assert.equal(raw, JSON.stringify({ version: 99 }));
});
test('file fingerprints are deterministic, byte-sensitive and match FNV-1a reference vectors', () => {
  assert.equal(fingerprint(new Uint8Array()), 'cbf29ce484222325');
  assert.equal(fingerprint(new TextEncoder().encode('hello')), 'a430d84680aabd0b');
  assert.notEqual(fingerprint(new Uint8Array([1,2,3])), fingerprint(new Uint8Array([1,2,4])));
});
test('fifty thousand queue entries survive serialization with identity and position', () => {
  const items = entries(50000), q = new Sequence({ name: 'Large', entries: items, startingAt: 49998 });
  const copy = Sequence.fromJSON(JSON.parse(JSON.stringify(q)));
  assert.equal(copy.current.trackID, 'Folder/Tune49998.sid'); assert.equal(copy.next().trackID, 'Folder/Tune49999.sid'); assert.equal(copy.next(), null);
});
