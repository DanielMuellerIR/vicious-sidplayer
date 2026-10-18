// Die portable Oberfläche kann nur ausdrücklich ausgewählte Dateien lesen.
// Nicht ausgewählt bedeutet deshalb nicht nachweislich gelöscht.
const auditMaximumFileBytes = 32 * 1024 * 1024;
const auditReferenceKey = ref => JSON.stringify([ref.trackID, ref.md5 || null, ref.subtune ?? null]);
function auditWebReferences(documents) {
  const [listening, history] = documents, catalog = new Map(listening.catalog.map(t => [t.id, t]));
  const result = new Map();
  const add = (trackID, subtune, owner, personal = null) => {
    const track = catalog.get(trackID), ref = { trackID, path: personal?.path || track?.path || trackID,
      md5: personal ? personal.md5 || null : track?.md5 || null, subtune: subtune ?? null };
    const key = auditReferenceKey(ref);
    if (!result.has(key)) result.set(key, { reference: ref, owners: [] });
    if (personal?.path) result.get(key).reference.path = personal.path;
    result.get(key).owners.push(owner);
  };
  for (const id of listening.libraryIDs) add(id, null, 'library:' + id);
  for (const id of listening.favorites) add(id, null, 'favorite:' + id);
  for (const list of listening.lists) for (const entry of list.entries) add(entry.trackID, entry.subtune, `list:${list.id}:${entry.id}`);
  for (const kind of ['events', 'bookmarks', 'notes']) for (const item of history[kind]) {
    add(item.reference.trackID, item.reference.subtune, `${kind}:${item.id}`, item.reference);
  }
  for (const value of result.values()) value.owners.sort();
  return result;
}
async function auditWebCollection(documents, loaded, { signal = null, progress = () => {}, importIssues = [] } = {}) {
  const check = () => { if (signal?.aborted) throw new DOMException('The collection check was cancelled.', 'AbortError'); };
  const issues = collectionClone(importIssues), tracks = [], byMD5 = new Map(), duplicates = new Map();
  progress(0, loaded.length);
  for (let i = 0; i < loaded.length; i++) {
    if (i % 8 === 0) { await new Promise(resolve => setTimeout(resolve, 0)); check(); }
    const file = loaded[i], path = file.sourcePath || file.name, bytes = file.buffer;
    let header = null, digest = null;
    if (bytes.byteLength <= auditMaximumFileBytes) {
      digest = collectionMD5(bytes); header = parseSidHeader(bytes);
      if (!duplicates.has(digest)) duplicates.set(digest, []); duplicates.get(digest).push(path);
    }
    const track = { id: file.id, path, md5: digest, fingerprint: bytes.byteLength <= auditMaximumFileBytes ? listeningFileFingerprint(bytes) : null,
      subtunesCount: header?.subtunesCount || null, valid: !!header };
    tracks.push(track);
    if (!header) {
      const diagnostic = bytes.byteLength <= auditMaximumFileBytes ? sidFileDiagnostic(bytes) : null;
      const unsupported = bytes.byteLength > auditMaximumFileBytes || diagnostic?.unsupported;
      issues.push({ id: 'file:' + file.id, kind: unsupported ? 'unsupported' : 'damaged', paths: [path],
        detail: bytes.byteLength > auditMaximumFileBytes ? 'SID files larger than 32 MiB are unsupported.' : diagnostic?.message || 'The selected file has no readable SID header.', canRepair: false });
    } else {
      if (!byMD5.has(digest)) byMD5.set(digest, []); byMD5.get(digest).push(track);
      const unknown = Array.from({ length: header.subtunesCount }, (_, sub) => listeningSIDDuration(header, sub)).filter(value => value === null).length;
      if (unknown) issues.push({ id: 'length:' + file.id, kind: 'missingLength', paths: [path],
        detail: `Only the fallback duration is known for ${unknown} of ${header.subtunesCount} subtunes. Native databases are unavailable here.`, canRepair: false });
    }
    progress(i + 1, loaded.length);
  }
  check();
  for (const [digest, paths] of duplicates) if (paths.length > 1) issues.push({ id: 'duplicate:' + digest,
    kind: 'duplicate', paths: paths.sort(), detail: 'Complete file contents are identical. All files are kept.', canRepair: false });
  const byID = new Map(tracks.map(t => [t.id, t]));
  for (const [key, item] of auditWebReferences(documents)) {
    const ref = item.reference, exact = byID.get(ref.trackID), matches = ref.md5 ? byMD5.get(ref.md5) || [] : [];
    if (exact && !exact.valid && item.owners.every(owner => owner.startsWith('library:'))) continue;
    if (exact?.valid && (!ref.md5 || exact.md5 === ref.md5) && exact.path === ref.path
      && (ref.subtune == null || ref.subtune < exact.subtunesCount)) continue;
    const target = matches.length === 1 && (ref.subtune == null || ref.subtune < matches[0].subtunesCount) ? matches[0] : null;
    const missingSubtune = ref.subtune != null && matches.length === 1 && ref.subtune >= matches[0].subtunesCount;
    const kind = target ? 'moved' : matches.length > 1 ? 'ambiguous' : !ref.md5 ? 'unverified'
      : missingSubtune ? 'missing' : exact?.valid ? 'changed' : 'missing';
    issues.push({ id: 'reference:' + key, kind, paths: [ref.path], reference: ref, target,
      proposedPath: target?.path || null, canRepair: !!target,
      detail: target ? `Identical file content found: ${target.path}` : missingSubtune
        ? `Subtune ${ref.subtune + 1} is not contained in the selected file. No association is changed.` : kind === 'ambiguous'
        ? 'Several selected files have this content. No automatic association is made.'
        : 'This reference is unavailable or has no verified identity. Reopen its files or folder; this browser cannot prove that a file was deleted.' });
  }
  return { format: 'vicioussid.collection-audit', version: 1, createdAt: new Date().toISOString(),
    fileCount: loaded.length, validCount: tracks.filter(t => t.valid).length, hasSTIL: false, hasLengths: false,
    issues, tracks, baseline: collectionClone(documents) };
}
function repairWebAudit(documents, report, selected) {
  const changes = new Map(), oldRefs = auditWebReferences(report.baseline), currentRefs = auditWebReferences(documents);
  for (const id of selected) {
    const issue = report.issues.find(i => i.id === id && i.canRepair);
    if (!issue?.target || report.tracks.filter(t => t.valid && t.md5 === issue.reference.md5).length !== 1)
      throw new Error('The association is no longer unique. Run the collection check again.');
    const key = auditReferenceKey(issue.reference);
    if (!collectionEqual(oldRefs.get(key), currentRefs.get(key))) throw new Error('Personal references changed. Run the collection check again.');
    changes.set(key, issue.target);
  }
  const result = collectionClone(documents), [listening, history] = result;
  const catalog = new Map(documents[0].catalog.map(t => [t.id, t]));
  const targetFor = (id, subtune) => changes.get(auditReferenceKey({ trackID: id, md5: catalog.get(id)?.md5, subtune }));
  listening.libraryIDs = [...new Set(listening.libraryIDs.map(id => targetFor(id, null)?.id || id))];
  listening.favorites = [...new Set(listening.favorites.map(id => targetFor(id, null)?.id || id))];
  for (const list of listening.lists) for (const entry of list.entries) entry.trackID = targetFor(entry.trackID, entry.subtune)?.id || entry.trackID;
  for (const kind of ['events', 'bookmarks', 'notes']) for (const item of history[kind]) {
    const target = changes.get(auditReferenceKey(item.reference));
    if (target) item.reference = { ...item.reference, trackID: target.id, path: target.path, fingerprint: target.fingerprint, md5: target.md5 };
  }
  validateListeningV2(listening); validateHistoryV2(history);
  return result;
}
