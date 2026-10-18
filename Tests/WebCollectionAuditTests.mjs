import { sidSource } from './WebSourceSupport.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const files = ['sidplayer.js', 'src/listening.js', 'src/history.js', 'src/collection.js', 'src/personal-storage.js', 'src/collection-audit.js'];
const source = (await Promise.all(files.map(f => f === 'sidplayer.js' ? sidSource(f) : readFile(new URL('../' + f, import.meta.url), 'utf8')))).join('\n').replace(/^export /gm, '');
const { auditWebCollection: audit, repairWebAudit: repair, collectionMD5: md5, listeningFileFingerprint: fingerprint,
  emptyListeningDocument: emptyListening, emptyHistoryDocument: emptyHistory } = new Function(source + ';return {auditWebCollection,repairWebAudit,collectionMD5,listeningFileFingerprint,emptyListeningDocument,emptyHistoryDocument};')();
function sid(marker = 0) {
  const bytes = new Uint8Array(0x7f); bytes.set([80, 83, 73, 68]);
  for (const [offset, value] of [[4,2],[6,0x7c],[8,0x1000],[10,0x1000],[12,0x1001],[14,2],[16,1]]) {
    bytes[offset] = value >> 8; bytes[offset + 1] = value & 255;
  }
  bytes.set([0x60,0x60,marker], 0x7c); return bytes;
}
function file(path, buffer = sid()) { return { id: `${path}:${fingerprint(buffer)}`, sourcePath: path, name: path, buffer }; }
function fixture() {
  const bytes = sid(), old = file('Old/Tune.sid', bytes), moved = file('New/Tune.sid', bytes);
  const catalog = f => ({ id: f.id, path: f.sourcePath, name: f.name, fingerprint: fingerprint(f.buffer),
    md5: md5(f.buffer), size: f.buffer.length, subtunesCount: 2 });
  const listening = { ...emptyListening(), version: 2 }, history = { ...emptyHistory(), version: 2, heardMD5s: [md5(bytes)] };
  listening.catalog = [catalog(old), catalog(moved)]; listening.libraryIDs = [old.id, moved.id]; listening.favorites = [old.id];
  listening.lists = [{ id: 'list', name: 'Keep order', kind: 'regular', entries: [{ id: 'a', trackID: old.id, subtune: null }, { id: 'b', trackID: old.id, subtune: 1 }] }];
  const reference = { trackID: old.id, path: old.sourcePath, md5: md5(bytes), fingerprint: fingerprint(bytes), subtune: 1 };
  history.bookmarks = [{ id: 'bookmark', reference, name: 'Mark', position: 1.25, updatedAt: 1 }];
  history.notes = [{ id: 'note', reference, text: 'Keep my text', updatedAt: 1 }];
  return { documents: [listening, history], old, moved };
}
test('complete-content matches require explicit selection and keep names, order, positions and music', async () => {
  const { documents, moved } = fixture(), original = JSON.stringify(documents), audio = moved.buffer.slice();
  const other = file('Other/Tune.sid', sid(1));
  const report = await audit(documents, [moved, other]);
  assert.equal(report.issues.filter(i => i.kind === 'moved').length, 2);
  assert.deepEqual(repair(documents, report, new Set()), documents);
  const chosen = new Set(report.issues.filter(i => i.canRepair).map(i => i.id));
  const result = repair(documents, report, chosen);
  assert.deepEqual(result[0].favorites, [moved.id]); assert.deepEqual(result[0].lists[0].entries.map(e => e.trackID), [moved.id, moved.id]);
  assert.deepEqual(result[0].lists[0].entries.map(e => e.id), ['a','b']); assert.equal(result[1].bookmarks[0].position, 1.25);
  assert.equal(result[1].bookmarks[0].reference.path, moved.sourcePath); assert.equal(result[1].notes[0].text, 'Keep my text');
  assert.equal(JSON.stringify(documents), original); assert.deepEqual(moved.buffer, audio);
});
test('ambiguous content, different contents with equal file names, unsupported and damaged files are reported without repair', async () => {
  const { documents, moved } = fixture();
  const damaged = file('Broken.sid', new Uint8Array([1,2,3])), futureBytes = sid(); futureBytes[5] = 6;
  const report = await audit(documents, [moved, file('Copy.sid'), file('Other/Tune.sid', sid(1)), damaged, file('Future.sid', futureBytes)]);
  assert.equal(report.validCount, 3); assert.equal(report.fileCount, 5);
  assert.equal(report.issues.filter(i => i.kind === 'duplicate').length, 1);
  assert.equal(report.issues.filter(i => i.kind === 'damaged').length, 1);
  assert.equal(report.issues.filter(i => i.kind === 'unsupported').length, 1);
  assert.equal(report.issues.filter(i => i.kind === 'ambiguous').length, 2);
  assert.ok(report.issues.every(i => !i.canRepair));
});
test('missing fingerprints never produce a file-name association and loaded subtrees stay separate', async () => {
  const { documents, moved } = fixture();
  for (const track of documents[0].catalog) delete track.md5;
  for (const item of [...documents[1].bookmarks, ...documents[1].notes]) delete item.reference.md5;
  const report = await audit(documents, [moved]);
  assert.ok(report.issues.some(i => i.kind === 'unverified')); assert.ok(report.issues.every(i => !i.canRepair));
});
test('changed reference occurrences reject a stale preview while unrelated note edits survive', async () => {
  const { documents, moved } = fixture(), report = await audit(documents, [moved]);
  const chosen = new Set(report.issues.filter(i => i.canRepair).map(i => i.id));
  const changed = structuredClone(documents); changed[0].lists[0].entries.push({ ...changed[0].lists[0].entries[1], id: 'new' });
  assert.throws(() => repair(changed, report, chosen), /changed/);
  const edited = structuredClone(documents); edited[1].notes[0].text = 'New text';
  assert.equal(repair(edited, report, chosen)[1].notes[0].text, 'New text');
  assert.throws(() => repair(documents, report, new Set(['made-up'])), /no longer unique/);
});
test('cancellation yields to the browser and never returns a partial report or changes documents', async () => {
  const { documents, moved } = fixture(), before = JSON.stringify(documents), controller = new AbortController();
  const task = audit(documents, Array.from({ length: 1000 }, (_, i) => ({ ...moved, id: 'id:' + i })), {
    signal: controller.signal, progress: count => { if (count === 8) controller.abort(); }
  });
  await assert.rejects(task, { name: 'AbortError' }); assert.equal(JSON.stringify(documents), before);
});
test('a missing selected subtune is unavailable and no report contains binary music', async () => {
  const { documents, moved } = fixture(); documents[1].notes[0].reference = { ...documents[1].notes[0].reference, subtune: 9 };
  const report = await audit(documents, [moved]);
  assert.ok(report.issues.some(i => i.reference?.subtune === 9 && !i.canRepair));
  assert.ok(report.issues.some(i => i.reference?.subtune === 9 && i.kind === 'missing' && /Subtune 10/.test(i.detail)));
  assert.ok(!JSON.stringify(report).includes('buffer'));
});
