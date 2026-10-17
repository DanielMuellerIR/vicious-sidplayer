// Das Austauschformat entspricht PersonalCollectionDocument im nativen Core.
// MD5 belegt Dateiinhalt; bestehende FNV-Katalogkennungen bleiben eigenständig.
function collectionMD5(bytes) {
  const shifts = [7,12,17,22,7,12,17,22,7,12,17,22,7,12,17,22,
    5,9,14,20,5,9,14,20,5,9,14,20,5,9,14,20,
    4,11,16,23,4,11,16,23,4,11,16,23,4,11,16,23,
    6,10,15,21,6,10,15,21,6,10,15,21,6,10,15,21];
  const constants = Array.from({length:64}, (_,i) => Math.floor(Math.abs(Math.sin(i+1))*4294967296) >>> 0);
  const padded = new Uint8Array(Math.ceil((bytes.byteLength+9)/64)*64);
  padded.set(bytes); padded[bytes.byteLength]=0x80;
  const view = new DataView(padded.buffer), bits = bytes.byteLength*8;
  view.setUint32(padded.byteLength-8,bits>>>0,true); view.setUint32(padded.byteLength-4,Math.floor(bits/4294967296),true);
  let a=0x67452301,b=0xefcdab89,c=0x98badcfe,d=0x10325476;
  for(let offset=0;offset<padded.byteLength;offset+=64) {
    let aa=a,bb=b,cc=c,dd=d;
    for(let i=0;i<64;i++) {
      let f,g;
      if(i<16) { f=(bb&cc)|(~bb&dd);g=i; }
      else if(i<32) { f=(dd&bb)|(~dd&cc);g=(5*i+1)%16; }
      else if(i<48) { f=bb^cc^dd;g=(3*i+5)%16; }
      else { f=cc^(bb|~dd);g=(7*i)%16; }
      const x=(f+aa+constants[i]+view.getUint32(offset+g*4,true))|0, n=shifts[i];
      aa=dd;dd=cc;cc=bb;bb=(bb+((x<<n)|(x>>>(32-n))))|0;
    }
    a=(a+aa)|0;b=(b+bb)|0;c=(c+cc)|0;d=(d+dd)|0;
  }
  const result=new DataView(new ArrayBuffer(16));[a,b,c,d].forEach((v,i)=>result.setUint32(i*4,v,true));
  return Array.from(new Uint8Array(result.buffer),n=>n.toString(16).padStart(2,'0')).join('');
}

const collectionMaximumBytes = 32 * 1024 * 1024;
const collectionAreas = ['favorites', 'lists', 'bookmarks', 'notes', 'history'];
const collectionSegmenter = typeof Intl.Segmenter === 'function' ? new Intl.Segmenter(undefined, { granularity: 'grapheme' }) : null;
const collectionClone = value => JSON.parse(JSON.stringify(value));
const collectionEqual = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const collectionMD5Valid = value => typeof value === 'string' && /^[a-f0-9]{32}$/.test(value);
const collectionUUIDValid = value => typeof value === 'string' && /^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(value);
const collectionSubtuneValid = value => value == null || Number.isInteger(value) && value >= 0 && value < 256;
function collectionUnicodeValid(value) {
  for (let i = 0; i < value.length; i++) {
    const unit = value.charCodeAt(i);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      const next = value.charCodeAt(++i);
      if (!(next >= 0xdc00 && next <= 0xdfff)) return false;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) return false;
  }
  return true;
}
function collectionTextValid(value, maximum, required = true) {
  if (typeof value !== 'string' || !collectionUnicodeValid(value) || value.includes('\0') || required && !value.trim()) return false;
  if (!collectionSegmenter) return value.length <= maximum;
  let count = 0;
  for (const _ of collectionSegmenter.segment(value)) if (++count > maximum) return false;
  return true;
}
function collectionPathValid(path) {
  const first = typeof path === 'string' ? path.split('/')[0] : '';
  const drive = first.endsWith(':') && (collectionSegmenter ? [...collectionSegmenter.segment(first)].length : first.length) === 2;
  return collectionTextValid(path, 8192) && !path.startsWith('/') && !drive
    && !path.includes('\\') && !path.split('/').some(part => !part || part === '.' || part === '..') && /\.sid$/i.test(path);
}
function collectionReferenceValid(ref, needsMD5 = false, needsSubtune = false) {
  return ref && collectionPathValid(ref.path) && (ref.md5 == null ? !needsMD5 : collectionMD5Valid(ref.md5))
    && collectionSubtuneValid(ref.subtune) && (!needsSubtune || ref.subtune != null);
}
function collectionDateValid(value) {
  if (typeof value !== 'string') return false;
  const parts = value.match(/^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(\.\d+)?(Z|[+-]\d\d:\d\d)$/);
  if (!parts) return false;
  const [year, month, day, hour, minute, second] = parts.slice(1, 7).map(Number);
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  return year >= 1 && month >= 1 && month <= 12 && day >= 1 && day <= days[month - 1] && hour < 24 && minute < 60 && second < 60
    && Number.isFinite(Date.parse(value)) && Date.parse(value) >= -62135596800000 && Date.parse(value) <= 253402300799000;
}
const collectionContentKey = ref => `${ref.md5 || ''}:${ref.subtune ?? 'file'}`;
const collectionReferenceKey = ref => JSON.stringify([ref.path, ref.md5 ?? null, ref.subtune ?? null]);
function collectionUUID(value, namespace = '', occupied = new Set()) {
  if (collectionUUIDValid(value) && !occupied.has(value.toUpperCase())) return value.toUpperCase();
  for (let attempt = 0; ; attempt++) {
    const h = collectionMD5(new TextEncoder().encode(`vicioussid:${namespace}:${value}:${attempt}`));
    const id = `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`.toUpperCase();
    if (!occupied.has(id)) return id;
  }
}
function collectionIDs(values, namespace) {
  const occupied = new Set(values.filter(collectionUUIDValid).map(id => id.toUpperCase())), result = new Map(), assigned = new Set();
  for (const value of [...values].sort()) if (collectionUUIDValid(value)) {
    const upper = value.toUpperCase(), id = assigned.has(upper) ? collectionUUID(value, namespace, occupied) : upper;
    occupied.add(id); assigned.add(id); result.set(value, id);
  }
  for (const value of [...values].sort()) if (!collectionUUIDValid(value)) {
    const id = collectionUUID(value, namespace, occupied); occupied.add(id); result.set(value, id);
  }
  return result;
}
function emptyCollectionDocument(name = 'Personal collection', now = Date.now()) {
  return { format: 'vicioussid.personal-collection', version: 1, name, createdAt: new Date(now).toISOString(),
    favorites: [], lists: [], bookmarks: [], notes: [], endTimes: [] };
}
function validateCollectionDocument(doc) {
  const unique = values => new Set(values).size === values.length;
  const ids = values => values.every(e => collectionUUIDValid(e.id)) && unique(values.map(e => e.id.toUpperCase()));
  const array = (values, maximum) => Array.isArray(values) && values.length <= maximum;
  const number = value => Number.isFinite(value) && value >= 0;
  const heard = new Set(Array.isArray(doc?.history?.heardMD5s) ? doc.history.heardMD5s : []);
  if (!doc || doc.format !== 'vicioussid.personal-collection' || doc.version !== 1) throw new Error('Unsupported collection format. The original file is kept.');
  if (!collectionTextValid(doc.name, 200) || !collectionDateValid(doc.createdAt)
    || !array(doc.favorites, 200000) || !doc.favorites.every(r => collectionReferenceValid(r) && r.subtune == null)
    || !unique(doc.favorites.map(collectionReferenceKey)) || !array(doc.lists, 5000) || !ids(doc.lists)
    || doc.lists.filter(l => l.kind === 'subtuneFavorites').length > 1
    || !doc.lists.every(l => collectionTextValid(l.name, 200) && ['regular', 'subtuneFavorites'].includes(l.kind)
      && array(l.entries, 200000) && ids(l.entries) && l.entries.every(e => collectionReferenceValid(e.reference, false, l.kind === 'subtuneFavorites')))
    || doc.lists.reduce((sum, l) => sum + l.entries.length, 0) > 200000
    || !array(doc.bookmarks, 20000) || !ids(doc.bookmarks)
    || !doc.bookmarks.every(e => collectionReferenceValid(e.reference, true, true) && collectionTextValid(e.name, 200) && number(e.position) && collectionDateValid(e.updatedAt))
    || !array(doc.notes, 20000) || !ids(doc.notes) || !unique(doc.notes.map(e => collectionContentKey(e.reference || {})))
    || !doc.notes.every(e => collectionReferenceValid(e.reference, true) && collectionTextValid(e.text, 16000) && collectionDateValid(e.updatedAt))
    || !array(doc.endTimes, 200000) || !unique(doc.endTimes.map(e => `${e.md5}:${e.subtune}`))
    || !doc.endTimes.every(e => collectionMD5Valid(e.md5) && e.subtune != null && collectionSubtuneValid(e.subtune) && Number.isFinite(e.seconds) && e.seconds > 0 && e.seconds <= 3600)) throw new Error('Invalid collection data. The original file is kept.');
  if (doc.history != null && (!array(doc.history.events, 20000) || !ids(doc.history.events)
    || !array(doc.history.heardMD5s, 200000) || !doc.history.heardMD5s.every(collectionMD5Valid) || !unique(doc.history.heardMD5s)
    || !doc.history.events.every(e => collectionReferenceValid(e.reference, true, true) && collectionTextValid(e.title, 1024, false)
      && collectionDateValid(e.startedAt) && collectionDateValid(e.lastHeardAt) && Date.parse(e.lastHeardAt) >= Date.parse(e.startedAt)
      && Number.isFinite(e.heardSeconds) && e.heardSeconds >= 1 && number(e.lastPosition) && heard.has(e.reference.md5)))) throw new Error('Invalid collection history. The original file is kept.');
}
function decodeCollectionDocument(raw) {
  if (new TextEncoder().encode(raw).byteLength > collectionMaximumBytes) throw new Error('Collection files are limited to 32 MiB.');
  let doc;
  try {
    doc = JSON.parse(raw.replace(/^\uFEFF/, ''), (key, value) => {
      if (['__proto__', 'constructor', 'prototype'].includes(key) || !collectionUnicodeValid(key)
        || typeof value === 'string' && !collectionUnicodeValid(value)) throw new Error('Invalid collection key or text.');
      return value;
    });
    validateCollectionDocument(doc);
  } catch (error) {
    throw new Error(error.message.startsWith('Unsupported collection format') ? error.message : 'Invalid collection data. The original file is kept.');
  }
  for (const list of doc.lists) { list.id = list.id.toUpperCase(); for (const entry of list.entries) entry.id = entry.id.toUpperCase(); }
  for (const item of [...doc.bookmarks, ...doc.notes, ...(doc.history?.events || [])]) item.id = item.id.toUpperCase();
  return doc;
}
function collectionUTF8(bytes) {
  if (bytes.byteLength > collectionMaximumBytes) throw new Error('Collection files are limited to 32 MiB.');
  try { return new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes); }
  catch (_) { throw new Error('The collection file must contain valid UTF-8 JSON. The original file is unchanged.'); }
}
function encodeCollectionDocument(doc) {
  validateCollectionDocument(doc);
  const raw = JSON.stringify(doc, null, 2);
  if (new TextEncoder().encode(raw).byteLength > collectionMaximumBytes) throw new Error('Collection files are limited to 32 MiB.');
  return raw;
}
class CollectionResolver {
  constructor(tracks) {
    this.paths = new Map(); this.md5s = new Map();
    for (const track of tracks) {
      if (!collectionPathValid(track.path) || this.paths.has(track.path) || track.md5 != null && !collectionMD5Valid(track.md5)
        || track.subtunesCount != null && (!Number.isInteger(track.subtunesCount) || track.subtunesCount < 1 || track.subtunesCount > 256)) throw new Error('Ambiguous or invalid music catalog. Select a unique folder.');
      this.paths.set(track.path, track);
      if (track.md5) { if (!this.md5s.has(track.md5)) this.md5s.set(track.md5, []); this.md5s.get(track.md5).push(track); }
    }
  }
  resolve(ref) {
    const atPath = this.paths.get(ref.path);
    const confirmed = (track, kind) => ref.subtune != null && track.subtunesCount != null && ref.subtune >= track.subtunesCount
      ? { kind: 'unavailableSubtune', track } : { kind, track };
    if (!ref.md5) return atPath?.unavailable ? { kind: 'unavailable', track: atPath }
      : atPath ? confirmed(atPath, 'unverified') : { kind: 'missing' };
    if (atPath?.md5 === ref.md5) return confirmed(atPath, 'exact');
    const matches = this.md5s.get(ref.md5) || [];
    if (matches.length === 1) return confirmed(matches[0], 'moved');
    if (matches.length > 1) return { kind: 'ambiguous' };
    return !atPath ? { kind: 'missing' } : atPath.unavailable ? { kind: 'unavailable', track: atPath }
      : { kind: atPath.md5 ? 'changed' : 'unverified', track: atPath };
  }
}

function bindCollectionHistory(history, tracks) {
  const byID = new Map(tracks.filter(t => t.md5 && !t.unavailable).map(t => [t.id, t]));
  const bind = ref => {
    const track = byID.get(ref.trackID);
    return !ref.md5 && track?.fingerprint === ref.fingerprint ? { ...ref, md5: track.md5, path: track.path } : ref;
  };
  for (const item of [...history.events, ...history.bookmarks]) item.reference = bind(item.reference);
  const occupied = new Set(history.notes.filter(n => n.reference.md5).map(n => collectionContentKey(n.reference)));
  for (const note of history.notes) {
    const ref = bind(note.reference), key = collectionContentKey(ref);
    if (!note.reference.md5 && ref.md5 && !occupied.has(key)) { note.reference = ref; occupied.add(key); }
  }
  const heard = new Set(history.heardMD5s);
  const byFNV = new Map();
  for (const track of byID.values()) {
    if (!byFNV.has(track.fingerprint)) byFNV.set(track.fingerprint, new Set());
    byFNV.get(track.fingerprint).add(track.md5);
  }
  for (const value of history.heard) if (byFNV.get(value)?.size === 1) heard.add([...byFNV.get(value)][0]);
  for (const event of history.events) if (event.reference.md5) heard.add(event.reference.md5);
  history.heardMD5s = [...heard];
}
function exportWebCollection(listening, history, tracks, includeHistory = false, now = Date.now()) {
  const doc = emptyCollectionDocument('Personal collection', now), fresh = new Map(tracks.filter(t => !t.unavailable).map(t => [t.id, t]));
  const catalog = new Map(listening.catalog.map(t => [t.id, t]));
  let omittedLegacy = 0, unverified = 0;
  const reference = (id, subtune) => {
    const track = catalog.get(id), path = track?.path;
    if (!collectionPathValid(path)) { omittedLegacy++; return null; }
    const ref = { path, ...(fresh.get(id)?.md5 ? { md5: fresh.get(id).md5 } : {}), ...(subtune != null ? { subtune } : {}) };
    if (!ref.md5) unverified++;
    return ref;
  };
  doc.favorites = listening.favorites.map(id => reference(id, null)).filter(Boolean);
  const listIDs = collectionIDs(listening.lists.map(l => l.id), 'list');
  doc.lists = listening.lists.map(list => {
    const entries = collectionIDs(list.entries.map(e => e.id), `entry:${list.id}`);
    return { id: listIDs.get(list.id), name: list.name, kind: list.kind,
      entries: list.entries.map(entry => ({ id: entries.get(entry.id), reference: reference(entry.trackID, entry.subtune) })).filter(e => e.reference) };
  });
  const personal = ref => {
    if (!ref.md5) { omittedLegacy++; return null; }
    const path = fresh.get(ref.trackID)?.path || ref.path || catalog.get(ref.trackID)?.path;
    if (!collectionPathValid(path)) { omittedLegacy++; return null; }
    return { path, md5: ref.md5, ...(ref.subtune != null ? { subtune: ref.subtune } : {}) };
  };
  const bookmarkIDs = collectionIDs(history.bookmarks.map(e => e.id), 'bookmark'), noteIDs = collectionIDs(history.notes.map(e => e.id), 'note');
  doc.bookmarks = history.bookmarks.flatMap(item => {
    const ref = personal(item.reference);
    return ref ? [{ id: bookmarkIDs.get(item.id), reference: ref, name: item.name, position: item.position, updatedAt: new Date(item.updatedAt).toISOString() }] : [];
  });
  doc.notes = history.notes.flatMap(item => {
    const ref = personal(item.reference);
    return ref ? [{ id: noteIDs.get(item.id), reference: ref, text: item.text, updatedAt: new Date(item.updatedAt).toISOString() }] : [];
  });
  if (includeHistory) {
    const eventIDs = collectionIDs(history.events.map(e => e.id), 'event');
    doc.history = { heardMD5s: [...history.heardMD5s].sort(), events: history.events.flatMap(item => {
      const ref = personal(item.reference);
      return ref ? [{ id: eventIDs.get(item.id), reference: ref, title: item.title,
        startedAt: new Date(item.startedAt).toISOString(), lastHeardAt: new Date(item.lastHeardAt).toISOString(),
        heardSeconds: item.heardSeconds, lastPosition: item.lastPosition }] : [];
    }) };
    const verifiedFNV = new Set(tracks.filter(t => t.md5 && !t.unavailable).map(t => t.fingerprint));
    omittedLegacy += history.heard.filter(value => !verifiedFNV.has(value)).length;
  }
  validateCollectionDocument(doc);
  return { document: doc, omittedLegacy, unverified };
}
function collectionListValue(list, pathsByID) {
  return [`${list.name} · ${list.entries.length} entries`, ...list.entries.map((entry, index) =>
    `${index + 1}. ${pathsByID.get(entry.trackID) || entry.trackID} · ${entry.subtune == null ? 'File entry' : `Subtune ${entry.subtune + 1}`}`)].join('\n');
}
function mergeWebCollection(document, source, tracks, { areas = new Set(collectionAreas.filter(a => a !== 'history')),
  choices = new Map(), acceptedPaths = new Set(), now = Date.now() } = {}) {
  validateCollectionDocument(document); validateListeningV2(source[0]); validateHistoryV2(source[1]);
  const result = collectionClone(source), [listening, history] = result, resolver = new CollectionResolver(tracks);
  const pathsByID = new Map([...listening.catalog, ...tracks].map(track => [track.id, track.path]));
  const favorites = new Set(listening.favorites), listIDs = collectionIDs(listening.lists.map(l => l.id), 'list');
  const listIndices = new Map(listening.lists.map((l, i) => [listIDs.get(l.id), i]));
  const bookmarkIDs = collectionIDs(history.bookmarks.map(e => e.id), 'bookmark');
  const bookmarkIndices = new Map(history.bookmarks.map((e, i) => [bookmarkIDs.get(e.id), i]));
  const noteIndices = new Map(history.notes.map((e, i) => [historyContentKey(e.reference), i]));
  const noteIDs = new Set(collectionIDs(history.notes.map(e => e.id), 'note').values());
  const eventIDs = collectionIDs(history.events.map(e => e.id), 'event');
  const eventIndices = new Map(history.events.map((e, i) => [eventIDs.get(e.id), i]));
  const conflicts = [], unresolved = [], seenUnresolved = new Set();
  let additions = 0, duplicates = 0, updates = 0, skippedPathEntries = 0;
  const useImported = (id, label, existingValue, importedValue, allowed = true,
    existingIdentity = existingValue, importedIdentity = importedValue) => {
    conflicts.push({ id, label, existingValue, importedValue, allowed, existingIdentity, importedIdentity });
    return allowed && choices.get(id) === 'useImported';
  };
  const mapped = (ref, required) => {
    const resolution = resolver.resolve(ref), key = collectionReferenceKey(ref);
    const confirmed = ['exact', 'moved'].includes(resolution.kind);
    if (!confirmed && !seenUnresolved.has(key)) { unresolved.push({ reference: ref, resolution }); seenUnresolved.add(key); }
    const track = confirmed || resolution.kind === 'unverified' && acceptedPaths.has(key) ? resolution.track : null;
    if (!track && required) { skippedPathEntries++; return null; }
    if (required) return { trackID: track.id, subtune: ref.subtune ?? null };
    return { trackID: track?.id || `import:${ref.md5}:${ref.path}`, md5: ref.md5, path: track?.path || ref.path,
      ...(track?.fingerprint ? { fingerprint: track.fingerprint } : {}), subtune: ref.subtune ?? null };
  };
  if (areas.has('favorites')) for (const ref of document.favorites) {
    const entry = mapped(ref, true); if (!entry) continue;
    if (favorites.has(entry.trackID)) duplicates++; else { favorites.add(entry.trackID); listening.favorites.push(entry.trackID); additions++; }
  }
  if (areas.has('lists')) for (const list of document.lists) {
    const entries = list.entries.flatMap(entry => { const ref = mapped(entry.reference, true); return ref ? [{ id: entry.id, ...ref }] : []; });
    const existing = list.kind === 'subtuneFavorites' ? listening.lists.find(l => l.kind === 'subtuneFavorites') : null;
    if (existing) {
      const entryKeys = new Set(existing.entries.map(e => `${e.trackID}:${e.subtune}`));
      const ids = new Set(collectionIDs(existing.entries.map(e => e.id), `entry:${existing.id}`).values());
      for (const entry of entries) {
        const key = `${entry.trackID}:${entry.subtune}`;
        if (entryKeys.has(key)) { duplicates++; continue; }
        entryKeys.add(key);
        const id = ids.has(entry.id) ? collectionUUID(entry.id, key, ids) : entry.id;
        ids.add(id); existing.entries.push({ ...entry, id }); additions++;
      }
      continue;
    }
    const index = listIndices.get(list.id) ?? -1;
    const incoming = { id: index < 0 ? list.id : listening.lists[index].id, name: list.name, kind: list.kind, entries };
    if (index < 0) { listIndices.set(list.id, listening.lists.length); listening.lists.push(incoming); additions++; }
    else {
      const old = listening.lists[index];
      const canonical = l => {
        const ids = collectionIDs(l.entries.map(e => e.id), `entry:${l.id}`);
        return { name: l.name, kind: l.kind, entries: l.entries.map(e => ({ ...e, id: ids.get(e.id) })) };
      };
      if (collectionEqual(canonical(old), canonical(incoming))) duplicates++;
      else if (useImported(`list:${list.id}`, list.name, collectionListValue(old, pathsByID), collectionListValue(incoming, pathsByID),
        old.kind === list.kind, canonical(old), canonical(incoming))) {
        listening.lists[index] = incoming; updates++;
      }
    }
  }
  if (areas.has('bookmarks')) for (const item of document.bookmarks) {
    const incoming = { ...item, reference: mapped(item.reference, false), updatedAt: Date.parse(item.updatedAt) };
    const index = bookmarkIndices.get(item.id), old = history.bookmarks[index];
    if (!old) { bookmarkIndices.set(item.id, history.bookmarks.length); history.bookmarks.push(incoming); additions++; }
    else if (historyContentKey(old.reference) === historyContentKey(incoming.reference) && old.name === item.name && old.position === item.position) duplicates++;
    else if (useImported(`bookmark:${item.id}`, item.name, `${old.name} · ${old.position}s · ${old.reference.path || old.reference.trackID}`,
      `${item.name} · ${item.position}s · ${item.reference.path}`)) { history.bookmarks[index] = { ...incoming, id: old.id }; updates++; }
  }
  if (areas.has('notes')) for (const item of document.notes) {
    const reference = mapped(item.reference, false), key = historyContentKey(reference), index = noteIndices.get(key);
    if (index != null) {
      const old = history.notes[index];
      if (old.text === item.text) duplicates++;
      else if (useImported(`note:${key}`, `${reference.path} · ${reference.subtune == null ? 'whole file' : `subtune ${reference.subtune + 1}`}`, old.text, item.text)) {
        history.notes[index] = { id: old.id, reference, text: item.text, updatedAt: Date.parse(item.updatedAt) }; updates++;
      }
    } else {
      const collision = noteIDs.has(item.id);
      if (!collision || useImported(`note-id:${item.id}`, reference.path, 'This ID already belongs to another note. That note will be kept.', item.text)) {
        const id = collision ? collectionUUID(item.id, key, noteIDs) : item.id;
        noteIDs.add(id); noteIndices.set(key, history.notes.length);
        history.notes.push({ id, reference, text: item.text, updatedAt: Date.parse(item.updatedAt) }); additions++;
      }
    }
  }
  const heardBefore = history.heardMD5s.length;
  if (areas.has('history') && document.history) {
    history.heardMD5s = [...new Set([...history.heardMD5s, ...document.history.heardMD5s])];
    for (const item of document.history.events) {
      const incoming = { ...item, reference: mapped(item.reference, false), startedAt: Date.parse(item.startedAt), lastHeardAt: Date.parse(item.lastHeardAt) };
      const index = eventIndices.get(item.id), old = history.events[index];
      if (!old) { eventIndices.set(item.id, history.events.length); history.events.push(incoming); additions++; continue; }
      const same = historyContentKey(old.reference) === historyContentKey(incoming.reference) && Math.round(old.startedAt) === incoming.startedAt;
      if (same && old.heardSeconds >= item.heardSeconds && Math.round(old.lastHeardAt) >= incoming.lastHeardAt) duplicates++;
      else if (same && item.heardSeconds >= old.heardSeconds && incoming.lastHeardAt >= Math.round(old.lastHeardAt)) { history.events[index] = { ...incoming, id: old.id }; updates++; }
      else if (useImported(`event:${item.id}`, item.title, `${old.reference.path || old.reference.trackID} · ${old.heardSeconds}s heard`,
        `${item.reference.path} · ${item.heardSeconds}s heard`)) { history.events[index] = { ...incoming, id: old.id }; updates++; }
    }
    pruneHistory(history, now);
  }
  validateListeningV2(listening); validateHistoryV2(history);
  return { documents: result, conflicts, unresolved, additions, duplicates, updates, skippedPathEntries,
    heardAddedCount: history.heardMD5s.length - heardBefore, unsupportedEndTimes: document.endTimes.length,
    hasChanges: !collectionEqual(source, result) };
}
