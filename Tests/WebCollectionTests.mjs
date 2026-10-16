import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash, randomBytes } from 'node:crypto';
const sources = await Promise.all(['listening', 'history', 'collection', 'personal-storage'].map(name => readFile(new URL(`../src/${name}.js`, import.meta.url), 'utf8')));
const api = new Function(sources.join('\n') + ';return {collectionMD5,decodeCollectionDocument,encodeCollectionDocument,CollectionResolver,WebPersonalStorage,personalStorageKeys,personalLegacyKeys,personalJournalKey,emptyListeningDocument,emptyHistoryDocument,collectionUUID,exportWebCollection,mergeWebCollection,bindCollectionHistory,collectionUTF8};')();
const { collectionMD5: md5, decodeCollectionDocument: decode, encodeCollectionDocument: encode, CollectionResolver: Resolver,
  WebPersonalStorage: Context, personalStorageKeys: keys, personalLegacyKeys: legacyKeys, personalJournalKey: journalKey } = api;
const golden = await readFile(new URL('./fixtures/collection-native-history.json', import.meta.url), 'utf8');
const clone = value => JSON.parse(JSON.stringify(value));
function memoryStorage() {
  const values = new Map();
  return { values, getItem: key => values.get(key) ?? null, setItem: (key, value) => values.set(key, value), removeItem: key => values.delete(key) };
}
function locks() {
  let pending = Promise.resolve();
  return { request: (_name, _options, action) => { const next = pending.then(action); pending = next.catch(() => {}); return next; } };
}
async function context(storage = memoryStorage(), lock = locks()) { return new Context(storage, lock).open(); }

test('native golden keeps UUIDs, legitimate duplicate subtunes, exact seconds and independent heard index', () => {
  const doc = decode(golden), roundtrip = decode(encode(doc));
  assert.deepEqual(roundtrip, doc);
  assert.equal(doc.lists[0].entries.length, 2);
  assert.notEqual(doc.lists[0].entries[0].id, doc.lists[0].entries[1].id);
  assert.equal(doc.bookmarks[0].position, 42.125); assert.equal(doc.endTimes[0].seconds, 125.5);
  assert.equal(doc.history.events.length, 4);
});
test('MD5 agrees with an independent implementation at padding and sliced buffer boundaries', () => {
  for (const length of [0, 1, 55, 56, 63, 64, 119, 120, 127, 128, 1024 * 1024]) {
    const backing = randomBytes(length + 11), bytes = backing.subarray(5, length + 5);
    assert.equal(md5(bytes), createHash('md5').update(bytes).digest('hex'));
  }
});
test('portable text limits count graphemes and the file capacity counts UTF-8 bytes', () => {
  const doc = decode(golden); doc.notes[0].text = '🕹️'.repeat(16000);
  assert.equal(decode(encode(doc)).notes[0].text, doc.notes[0].text);
  doc.notes[0].text += 'x'; assert.throws(() => encode(doc));
  assert.throws(() => decode(' '.repeat(32 * 1024 * 1024 - 1) + '€'));
});
test('invalid identities, traversal, unsupported versions, duplicate IDs and pollution keys are rejected', () => {
  for (const path of ['/A.sid', '../A.sid', 'A/./B.sid', 'C:/A.sid', 'A\\B.sid', 'A//B.sid', 'A\0.sid']) {
    const doc = decode(golden); doc.favorites[0].path = path; assert.throws(() => encode(doc));
  }
  for (const mutate of [d => { d.version = 99; }, d => { d.notes[0].reference.md5 = '123456789abcdef0'; },
    d => { d.bookmarks[0].position = NaN; }, d => { d.lists[0].entries[1].id = d.lists[0].entries[0].id.toLowerCase(); }]) {
    const doc = decode(golden); mutate(doc); assert.throws(() => encode(doc));
  }
  assert.throws(() => decode(golden.replace('"format"', '"__proto__":{},"format"')));
});
test('resolver distinguishes exact, moved, wrong, ambiguous, missing, unverified and unavailable subtunes', () => {
  const a = 'a'.repeat(32), b = 'b'.repeat(32), r = new Resolver([
    { path: 'Moved.sid', md5: a, subtunesCount: 3 }, { path: 'Wrong.sid', md5: b, subtunesCount: 1 },
    { path: 'Old.sid', subtunesCount: 1 }, { path: 'Copy.sid', md5: b, subtunesCount: 1 }]);
  for (const [reference, expected] of [[{ path: 'Moved.sid', md5: a }, 'exact'], [{ path: 'Gone.sid', md5: a }, 'moved'],
    [{ path: 'Wrong.sid', md5: 'c'.repeat(32) }, 'changed'], [{ path: 'Gone.sid', md5: b }, 'ambiguous'],
    [{ path: 'Gone.sid' }, 'missing'], [{ path: 'Old.sid', md5: a, subtune: 3 }, 'unavailableSubtune'], [{ path: 'Old.sid' }, 'unverified']]) {
    assert.equal(r.resolve(reference).kind, expected);
  }
});
test('migration retains raw legacy documents and FNV identities without inventing MD5', async () => {
  const storage = memoryStorage(), legacy = api.emptyListeningDocument();
  legacy.catalog.push({ id: 'Tune.sid:123456789abcdef0', path: 'Tune.sid', name: 'Tune', fingerprint: '123456789abcdef0', size: 136, subtunesCount: 3 });
  storage.setItem(legacyKeys[0], JSON.stringify(legacy)); storage.setItem(legacyKeys[1], JSON.stringify(api.emptyHistoryDocument()));
  const before = legacyKeys.map(k => storage.getItem(k)), ctx = await context(storage);
  assert.equal(ctx.readOnly, false); assert.deepEqual(legacyKeys.map(k => storage.getItem(k)), before);
  assert.equal(ctx.stores[0].document.version, 2); assert.equal(ctx.stores[0].document.catalog[0].id, legacy.catalog[0].id);
  assert.equal(ctx.stores[0].document.catalog[0].md5, undefined);
  assert.deepEqual(ctx.stores[1].document.heardMD5s, []);
});
test('failure on the second document restores both original bytes and clears the prepared journal', async () => {
  const storage = memoryStorage(), ctx = await context(storage), before = keys.map(k => storage.getItem(k));
  const set = storage.setItem; let fail = true;
  storage.setItem = (key, value) => { if (key === keys[1] && fail) { fail = false; throw new Error('quota'); } set(key, value); };
  ctx.stores[0].document.favorites.push('new');
  assert.equal(await ctx.save(), false); assert.deepEqual(keys.map(k => storage.getItem(k)), before);
  assert.equal(storage.getItem(journalKey), null); assert.equal(ctx.readOnly, false);
  assert.equal(await ctx.save(), true);
});
test('a failure before the commit marker rolls back; a cleanup failure after it commits and recovers', async () => {
  for (const committed of [false, true]) {
    const storage = memoryStorage(), ctx = await context(storage), before = keys.map(k => storage.getItem(k));
    const set = storage.setItem, remove = storage.removeItem; let fail = true;
    storage.setItem = (key, value) => { if (!committed && key === journalKey && JSON.parse(value).phase === 'committed' && fail) { fail = false; throw new Error('quota'); } set(key, value); };
    storage.removeItem = key => { if (committed && key === journalKey && fail) { fail = false; throw new Error('cleanup'); } remove(key); };
    ctx.stores[0].document.favorites.push('saved');
    assert.equal(await ctx.save(), committed);
    if (!committed) assert.deepEqual(keys.map(k => storage.getItem(k)), before);
    const restarted = await context(storage);
    assert.equal(restarted.readOnly, false); assert.equal(storage.getItem(journalKey), null);
    assert.equal(restarted.stores[0].document.favorites.includes('saved'), committed);
  }
});
test('restart recovers prepared and committed imports, but never overwrites foreign bytes', async () => {
  for (const phase of ['prepared', 'committed', 'foreign']) {
    const storage = memoryStorage(), ctx = await context(storage), before = keys.map(k => storage.getItem(k));
    const after = ctx.stores.map(s => clone(s.document)); after[0].favorites.push('import');
    const records = keys.map((key, i) => ({ key, before: before[i], after: JSON.stringify(after[i]) }));
    storage.setItem(journalKey, JSON.stringify({ version: 1, phase: phase === 'foreign' ? 'prepared' : phase, records }));
    storage.setItem(keys[0], phase === 'foreign' ? 'foreign bytes' : records[0].after);
    const restarted = await context(storage);
    assert.equal(restarted.readOnly, phase === 'foreign');
    if (phase === 'foreign') { assert.equal(storage.getItem(keys[0]), 'foreign bytes'); assert.ok(storage.getItem(journalKey)); }
    else { assert.equal(restarted.stores[0].document.favorites.includes('import'), phase === 'committed'); assert.equal(storage.getItem(journalKey), null); }
  }
});
test('concurrent current writers and later legacy writers cannot overwrite each other silently', async () => {
  const storage = memoryStorage(), lock = locks(), a = await context(storage, lock), b = await context(storage, lock);
  a.stores[0].document.favorites.push('A'); b.stores[0].document.favorites.push('B');
  assert.deepEqual(await Promise.all([a.save(), b.save()]), [true, false]);
  assert.equal(b.readOnly, true); assert.deepEqual(JSON.parse(storage.getItem(keys[0])).favorites, ['A']);
  storage.setItem(legacyKeys[0], JSON.stringify(api.emptyListeningDocument()));
  assert.equal(await a.save(), false); assert.equal(a.readOnly, true);
  const restarted = await context(storage, lock); assert.equal(restarted.readOnly, true);
});
test('future, damaged, incomplete and unavailable storage remain protected', async () => {
  for (const raw of ['{', '{"version":99}']) {
    const storage = memoryStorage(); storage.setItem(keys[0], raw); storage.setItem(keys[1], raw);
    const ctx = await context(storage); assert.equal(ctx.readOnly, true); assert.equal(storage.getItem(keys[0]), raw);
  }
  const storage = memoryStorage(); storage.setItem(legacyKeys[0], '{"version":99}');
  assert.equal((await context(storage)).readOnly, true); assert.equal(storage.getItem(keys[0]), null);
  assert.equal((await new Context(memoryStorage(), null).open()).readOnly, true);
});
test('fallback UUID conversion is stable, namespace-specific and collision-checked', () => {
  const first = api.collectionUUID('legacy'); assert.match(first, /^[A-F0-9-]{36}$/);
  assert.equal(api.collectionUUID('legacy'), first); assert.notEqual(api.collectionUUID('legacy', 'note'), first);
  assert.notEqual(api.collectionUUID('legacy', '', new Set([first])), first);
});

const portable = decode(golden), mainMD5 = portable.bookmarks[0].reference.md5;
const tracks = [{ id: 'current-main', path: 'Web/PAL.sid', md5: mainMD5, fingerprint: '123456789abcdef0', size: 136, subtunesCount: 3 },
  { id: 'current-trust', path: 'Trust.sid', md5: portable.favorites[1].md5, fingerprint: 'abcdef0123456789', size: 136, subtunesCount: 1 }];
async function emptySnapshot() {
  const ctx = await context();
  ctx.stores[0].document.catalog = tracks.map(t => ({ ...t, name: t.path }));
  ctx.stores[0].document.libraryIDs = tracks.map(t => t.id);
  return ctx.stores.map(s => clone(s.document));
}
test('native import preserves repeated entries and missing personal notes, with history off by default', async () => {
  const source = await emptySnapshot(), result = api.mergeWebCollection(portable, source, tracks);
  assert.equal(result.additions, 6); assert.equal(result.skippedPathEntries, 0); assert.equal(result.unsupportedEndTimes, 1);
  assert.deepEqual(result.documents[0].favorites, ['current-main', 'current-trust']);
  assert.deepEqual(result.documents[0].lists[0].entries.map(e => e.subtune), [2, 2]);
  assert.deepEqual(result.documents[1].events, []); assert.deepEqual(result.documents[1].heardMD5s, []);
  assert.equal(result.documents[1].notes.find(n => n.reference.path === 'Missing.sid').text, 'Fehlende Datei behalten');
  assert.equal(result.documents[1].bookmarks[0].position, 42.125);
  assert.deepEqual(source[0].favorites, []);
  const second = api.mergeWebCollection(portable, result.documents, tracks);
  assert.equal(second.additions, 0); assert.equal(second.updates, 0); assert.equal(second.duplicates, 6); assert.equal(second.hasChanges, false);
});
test('conflicts keep concrete existing text by default; imported choice is explicit and revocable', async () => {
  const source = await emptySnapshot(), first = api.mergeWebCollection(portable, source, tracks).documents;
  first[1].notes[0].text = 'Existing long note\nEXISTING_TAIL';
  const result = api.mergeWebCollection(portable, first, tracks), conflict = result.conflicts.find(c => c.id.startsWith('note:'));
  assert.equal(conflict.existingValue, 'Existing long note\nEXISTING_TAIL');
  assert.equal(conflict.importedValue, 'Importierte Dateinotiz'); assert.equal(result.documents[1].notes[0].text, conflict.existingValue);
  const choices = new Map([[conflict.id, 'useImported']]);
  assert.equal(api.mergeWebCollection(portable, first, tracks, { choices }).documents[1].notes[0].text, conflict.importedValue);
  choices.delete(conflict.id);
  assert.equal(api.mergeWebCollection(portable, first, tracks, { choices }).documents[1].notes[0].text, conflict.existingValue);
});
test('unverified path acceptance can be withdrawn; wrong, duplicate and missing music stays skipped', async () => {
  const source = await emptySnapshot(), doc = decode(golden); delete doc.favorites[1].md5;
  const key = JSON.stringify(['Trust.sid', null, null]), acceptedPaths = new Set([key]);
  const plain = api.mergeWebCollection(doc, source, tracks), trusted = api.mergeWebCollection(doc, source, tracks, { acceptedPaths });
  assert.equal(plain.skippedPathEntries, 1); assert.equal(trusted.skippedPathEntries, 0);
  acceptedPaths.clear(); assert.equal(api.mergeWebCollection(doc, source, tracks, { acceptedPaths }).skippedPathEntries, 1);
  const missing = api.mergeWebCollection(portable, source, []);
  assert.equal(missing.skippedPathEntries, 4); assert.equal(missing.documents[1].notes.length, 2);
  const ambiguous = [...tracks, { ...tracks[0], id: 'copy', path: 'Copy.sid' }];
  assert.equal(api.mergeWebCollection(portable, source, ambiguous).skippedPathEntries, 3);
});
test('history unions UUID episodes and heard status, keeps the larger episode and never sums imports', async () => {
  const source = await emptySnapshot(), areas = new Set(['history']), now = Date.parse('2026-10-16T18:00:00Z');
  const first = api.mergeWebCollection(portable, source, tracks, { areas, now });
  assert.equal(first.documents[1].events.length, 4);
  const second = api.mergeWebCollection(portable, first.documents, tracks, { areas, now });
  assert.equal(second.hasChanges, false); assert.equal(second.updates, 0);
  const item = portable.history.events[0], doc = clone(portable); doc.history.events[0].heardSeconds += 5;
  doc.history.events[0].lastHeardAt = new Date(Date.parse(item.lastHeardAt) + 5000).toISOString();
  const updated = api.mergeWebCollection(doc, first.documents, tracks, { areas, now });
  assert.equal(updated.documents[1].events.find(e => e.id === item.id).heardSeconds, item.heardSeconds + 5);
  assert.deepEqual([...updated.documents[1].heardMD5s].sort(), [...portable.history.heardMD5s].sort());
});
test('browser export keeps native identities and values and explicitly reports legacy omissions', async () => {
  const source = await emptySnapshot(), areas = new Set(['favorites', 'lists', 'bookmarks', 'notes', 'history']);
  const imported = api.mergeWebCollection(portable, source, tracks, { areas, now: Date.parse('2026-10-16T18:00:00Z') });
  const out = api.exportWebCollection(...imported.documents, tracks, true);
  assert.equal(out.omittedLegacy, 0); assert.equal(out.unverified, 0);
  assert.deepEqual(out.document.notes.map(n => n.id).sort(), portable.notes.map(n => n.id).sort());
  assert.equal(out.document.bookmarks[0].position, 42.125); assert.deepEqual(out.document.endTimes, []);
  assert.equal(out.document.lists[0].entries[0].id, portable.lists[0].entries[0].id);
  assert.deepEqual(out.document.history.events.map(e => e.id).sort(), portable.history.events.map(e => e.id).sort());
  const legacy = imported.documents[1]; legacy.notes.push({ id: 'old', reference: { trackID: 'old', fingerprint: 'cccccccccccccccc', subtune: null }, text: 'Keep this', updatedAt: 0 });
  legacy.heard.push('dddddddddddddddd');
  const partial = api.exportWebCollection(...imported.documents, tracks, true);
  assert.equal(partial.omittedLegacy, 2); assert.equal(legacy.notes.at(-1).text, 'Keep this');
  assert.equal(api.exportWebCollection(...imported.documents, tracks).document.history, undefined);
});
test('freshly selected bytes bind legacy references without deleting unresolved FNV heard state', async () => {
  const source = await emptySnapshot(), history = source[1];
  history.notes.push({ id: 'old', reference: { trackID: tracks[0].id, fingerprint: tracks[0].fingerprint, subtune: null }, text: 'Legacy', updatedAt: 0 });
  history.heard = [tracks[0].fingerprint, 'cccccccccccccccc'];
  api.bindCollectionHistory(history, tracks);
  assert.equal(history.notes[0].reference.md5, mainMD5); assert.deepEqual(history.heardMD5s, [mainMD5]);
  assert.equal(history.heard.length, 2);
  const exported = api.exportWebCollection(...source, tracks, true);
  assert.equal(exported.omittedLegacy, 1); assert.equal(exported.document.notes[0].text, 'Legacy');
});
test('apply refuses a stale preview and preserves foreign bytes; successful apply adopts both stores', async () => {
  const ctx = await context(), before = ctx.stores.map(s => clone(s.document)), expected = [...ctx.saved];
  const after = clone(before); after[0].favorites.push('import');
  ctx.storage.setItem(keys[1], 'external');
  await assert.rejects(ctx.apply(after, expected, before), /changed/);
  assert.equal(ctx.storage.getItem(keys[1]), 'external'); assert.deepEqual(ctx.stores[0].document.favorites, []);
  const fresh = await context(), old = fresh.stores.map(s => clone(s.document)), next = clone(old); next[0].favorites.push('success');
  await fresh.apply(next, [...fresh.saved], old);
  assert.deepEqual(fresh.stores[0].document.favorites, ['success']);
  assert.equal((await context(fresh.storage)).stores[0].document.favorites[0], 'success');
});
test('portable fallback IDs survive a deliberate collision with a native UUID and reimport stays idempotent', async () => {
  const source = await emptySnapshot(), reference = { trackID: tracks[0].id, md5: mainMD5, path: tracks[0].path, subtune: 2 };
  const collision = api.collectionUUID('legacy-bookmark', 'bookmark');
  source[1].bookmarks = [{ id: 'legacy-bookmark', reference, name: 'Legacy', position: 1, updatedAt: 0 },
    { id: collision, reference, name: 'Native', position: 2, updatedAt: 0 }];
  const first = api.exportWebCollection(...source, tracks), second = api.exportWebCollection(...source, tracks);
  assert.notEqual(first.document.bookmarks[0].id, first.document.bookmarks[1].id);
  assert.deepEqual(first.document.bookmarks, second.document.bookmarks);
  const merged = api.mergeWebCollection(first.document, source, tracks);
  assert.equal(merged.hasChanges, false); assert.equal(merged.duplicates, 2);
});
test('calendar overflow and Unicode drive prefixes cannot cross the native format boundary', () => {
  for (const date of ['2026-02-30T00:00:00Z', '2026-13-01T00:00:00Z', '2026-01-01T24:00:00Z']) {
    const doc = decode(golden); doc.createdAt = date; assert.throws(() => encode(doc));
  }
  const doc = decode(golden); doc.favorites[0].path = '🕹️:/A.sid'; assert.throws(() => encode(doc));
  doc.favorites[0].path = 'Folder/🕹️.sid'; doc.notes[0].text = 'e\u0301'.repeat(16000); assert.doesNotThrow(() => encode(doc));
});

test('invalid UTF-8 and unpaired surrogates are rejected while a UTF-8 BOM is retained in the original', () => {
  assert.throws(() => api.collectionUTF8(Uint8Array.of(0xc3, 0x28)), /valid UTF-8/);
  const raw = '\uFEFF' + golden;
  assert.equal(api.collectionUTF8(new TextEncoder().encode(raw)), raw);
  assert.deepEqual(decode(raw), decode(golden));
  const doc = decode(golden); doc.notes[0].text = '\ud800'; assert.throws(() => encode(doc));
  assert.throws(() => decode(golden.replace('Importierte Dateinotiz', '\\udc00')));
});
