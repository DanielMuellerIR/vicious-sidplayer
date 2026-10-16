import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const listening = await readFile(new URL('../src/listening.js', import.meta.url), 'utf8');
const history = await readFile(new URL('../src/history.js', import.meta.url), 'utf8');
const { WebHistoryRecorder: Recorder, WebHistoryStore: Store, pruneHistory: prune } = new Function(listening + '\n' + history + ';return {WebHistoryRecorder,WebHistoryStore,pruneHistory};')();
const reference = { trackID: 'A/Tune.sid:123456789abcdef0', fingerprint: '123456789abcdef0', subtune: 0 };
const start = Date.UTC(2026, 9, 16);
const observation = (uptime, position, playing, extra = {}) => ({ reference, title: 'Tune', uptime, position, playing, now: start + uptime * 1000, ...extra });

test('prepared files and seeks count no listening time; stop keeps the old position', () => {
  const r = new Recorder();
  for (const time of [0, 10, 300]) assert.equal(r.observe(observation(time, time, false)), null);
  assert.equal(r.observe(observation(301, 500, true)), null);
  const heard = r.observe(observation(311, 510, true));
  assert.equal(heard.heardSeconds, 10);
  const stopped = r.observe(observation(312, 0, false));
  assert.equal(stopped.lastPosition, 510); assert.equal(stopped.heardSeconds, 11);
  assert.equal(r.observe(observation(400, 1000, false)).heardSeconds, 11);
  r.observe(observation(401, 1000, true));
  const resumed = r.observe(observation(402, 1001, true));
  assert.equal(resumed.id, heard.id); assert.equal(resumed.heardSeconds, 12);
});
test('short known subtunes qualify proportionally; repeat keeps the episode and changed subtunes do not', () => {
  const r = new Recorder();
  r.observe(observation(0, 0, true, { knownDuration: 2 }));
  const first = r.observe(observation(1, 1, true, { knownDuration: 2 }));
  assert.equal(first.heardSeconds, 1);
  assert.equal(r.observe(observation(2, 0, true, { knownDuration: 2 })).id, first.id);
  r.observe(observation(3, 0, true, { reference: { ...reference, subtune: 1 }, knownDuration: 2 }));
  assert.notEqual(r.observe(observation(4, 1, true, { reference: { ...reference, subtune: 1 }, knownDuration: 2 })).id, first.id);
});
test('long unobserved intervals never claim listening; long pauses and reset clocks begin a new episode', () => {
  const r = new Recorder();
  r.observe(observation(0, 0, true));
  assert.equal(r.observe(observation(100, 100, true)), null);
  const first = r.observe(observation(110, 110, false));
  assert.equal(first.heardSeconds, 10);
  r.observe(observation(1200, 110, true));
  const resumed = r.observe(observation(1210, 120, true));
  assert.notEqual(resumed.id, first.id); assert.equal(resumed.heardSeconds, 10);
  assert.equal(r.observe(observation(0, 0, false)), null);
});
test('visible retention leaves the heard index and personal data intact across restart', () => {
  let raw = null;
  const storage = { getItem: () => raw, setItem: (_, value) => { raw = value; } };
  const store = new Store(storage), r = new Recorder();
  r.observe(observation(0, 0, true));
  const event = r.observe(observation(10, 10, false));
  store.document.events.push(event); store.document.heard.push(reference.fingerprint);
  store.document.bookmarks.push({ id: 'bookmark', reference, name: 'Bridge', position: 1234.5, updatedAt: start });
  store.document.notes.push({ id: 'note', reference: { ...reference, subtune: null }, text: 'Whole file note', updatedAt: start });
  prune(store.document, start + 181 * 86400000);
  assert.equal(store.document.events.length, 0); assert.deepEqual(store.document.heard, [reference.fingerprint]);
  assert.equal(store.save(), true);
  const restored = new Store(storage);
  assert.equal(restored.document.bookmarks[0].position, 1234.5);
  assert.equal(restored.document.notes[0].reference.subtune, null);
  assert.deepEqual(restored.document.heard, [reference.fingerprint]);
  assert.equal(raw.includes('buffer'), false);
});
test('damaged, unsupported and externally changed personal documents stay untouched', () => {
  for (const original of ['{', '{"version":99}', '{"version":1,"events":[]}']) {
    let raw = original;
    const store = new Store({ getItem: () => raw, setItem: (_, value) => { raw = value; } });
    assert.equal(store.readOnly, true); assert.equal(store.save(), false); assert.equal(raw, original);
  }
  let raw = null;
  const store = new Store({ getItem: () => raw, setItem: (_, value) => { raw = value; } });
  raw = 'external';
  assert.equal(store.save(), false); assert.equal(store.readOnly, true); assert.equal(raw, 'external');
});

test('numeric fingerprints cannot masquerade as validated content identities', () => {
  const raw = JSON.stringify({ version: 1, events: [], heard: [1234567890123456], bookmarks: [], notes: [] });
  const store = new Store({ getItem: () => raw, setItem: () => assert.fail('Must preserve the original') });
  assert.equal(store.readOnly, true); assert.equal(store.save(), false);
});
