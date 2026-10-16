// Fachliche Web-Regeln entsprechen ListeningQueue im Swift-Core. Gespeichert
// werden nur Identitaeten und Reihenfolge, niemals Musik oder Dateiberechtigungen.
let listeningIDCounter = 0;
function listeningID() {
  return typeof crypto !== 'undefined' && crypto.randomUUID
    ? crypto.randomUUID() : `${Date.now().toString(36)}-${(++listeningIDCounter).toString(36)}-${Math.random().toString(36).slice(2)}`;
}
function listeningEntry(trackID, subtune = null) { return { id: listeningID(), trackID, subtune }; }
function shuffleListeningItems(items) {
  const copy = [...items];
  for (let i = copy.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1)); [copy[i], copy[j]] = [copy[j], copy[i]];
  }
  return copy;
}
class ListeningSequence {
  constructor({ name, kind = 'selection', entries = [], startingAt = 0, shuffled = false, wraps = false }) {
    this.name = name; this.kind = kind; this.items = entries.map(e => ({ ...e }));
    this.currentID = (entries[startingAt] || entries[0])?.id || null;
    this.shuffled = shuffled; this.wraps = wraps; this.oneShotIDs = [];
    if (shuffled && this.current) this.items = [this.current, ...shuffleListeningItems(this.items.filter(e => e.id !== this.currentID))];
  }
  static fromJSON(value) {
    const queue = new ListeningSequence({ ...value, entries: value.items });
    queue.name = value.name; queue.kind = value.kind; queue.currentID = value.currentID;
    queue.shuffled = value.shuffled; queue.wraps = value.wraps;
    queue.items = value.items.map(e => ({ ...e })); queue.oneShotIDs = [...value.oneShotIDs];
    return queue;
  }
  get currentIndex() { return this.items.findIndex(e => e.id === this.currentID); }
  get current() { return this.items[this.currentIndex] || null; }
  select(id) { if (this.items.some(e => e.id === id)) this.currentID = id; }
  setShuffle(enabled) {
    if (enabled === this.shuffled) return;
    this.shuffled = enabled;
    if (enabled) this.shuffleRemaining();
  }
  shuffleRemaining() {
    const start = this.currentIndex + 1, next = this.items.slice(start);
    this.items = [...this.items.slice(0, start), ...next.filter(e => this.oneShotIDs.includes(e.id)),
      ...shuffleListeningItems(next.filter(e => !this.oneShotIDs.includes(e.id)))];
  }
  restart(shuffled, preservePending = false) {
    const pending = preservePending ? this.items.slice(this.currentIndex + 1).filter(e => this.oneShotIDs.includes(e.id)) : [];
    this.items = this.items.filter(e => !this.oneShotIDs.includes(e.id)); this.oneShotIDs = [];
    this.shuffled = shuffled;
    if (shuffled) this.items = shuffleListeningItems(this.items);
    this.currentID = this.items[0]?.id || null;
    pending.forEach(e => this.enqueueNext(e));
  }
  next() {
    if (!this.items.length) return null;
    if (this.currentIndex + 1 < this.items.length) { this.currentID = this.items[this.currentIndex + 1].id; return this.current; }
    if (!this.wraps) return null;
    const previous = this.currentID; this.restart(this.shuffled);
    if (this.shuffled && this.items.length > 1 && this.items[0].id === previous) [this.items[0], this.items[1]] = [this.items[1], this.items[0]];
    this.currentID = this.items[0]?.id || null;
    return this.current;
  }
  previous() {
    const index = this.currentIndex;
    if (index > 0) this.currentID = this.items[index - 1].id;
    else if (this.wraps) this.currentID = this.items[this.items.length - 1]?.id || null;
    else return null;
    return this.current;
  }
  enqueueNext(entry) {
    let index = this.currentIndex + 1;
    while (index < this.items.length && this.oneShotIDs.includes(this.items[index].id)) index++;
    const fresh = listeningEntry(entry.trackID, entry.subtune);
    this.items.splice(index, 0, fresh); this.oneShotIDs.push(fresh.id);
    if (!this.currentID) this.currentID = fresh.id;
  }
  move(id, offset) {
    const index = this.items.findIndex(e => e.id === id);
    if (index < 0) return;
    const target = Math.max(0, Math.min(this.items.length - 1, index + offset));
    this.items.splice(target, 0, this.items.splice(index, 1)[0]);
  }
  remove(id) {
    if (id === this.currentID) return;
    this.items = this.items.filter(e => e.id !== id); this.oneShotIDs = this.oneShotIDs.filter(value => value !== id);
  }
  updateSubtune(subtune, trackID) {
    if (this.current?.trackID === trackID && this.current.subtune != null) this.current.subtune = subtune;
  }
}
function listeningFileFingerprint(bytes) {
  let hash = 14695981039346656037n;
  for (const byte of bytes) hash = BigInt.asUintN(64, (hash ^ BigInt(byte)) * 1099511628211n);
  return hash.toString(16).padStart(16, '0');
}
function emptyListeningDocument() { return { version: 1, catalog: [], libraryIDs: [], lists: [], favorites: [], queue: null, shuffle: false, session: null }; }
function validateListeningDocument(doc) {
  const string = value => typeof value === 'string' && value.length > 0 && !value.includes('\0');
  const unique = values => new Set(values).size === values.length;
  const entries = values => Array.isArray(values) && values.every(e => string(e.id) && string(e.trackID)
    && (e.subtune == null || Number.isInteger(e.subtune) && e.subtune >= 0 && e.subtune < 256)) && unique(values.map(e => e.id));
  if (!doc || doc.version !== 1) throw new Error('This listening data version is not supported. The original data is preserved.');
  if (!Array.isArray(doc.libraryIDs) || !doc.libraryIDs.every(string) || !unique(doc.libraryIDs) || !Array.isArray(doc.catalog) || !doc.catalog.every(t => string(t.id) && string(t.path) && string(t.fingerprint)
      && Number.isSafeInteger(t.size) && t.size > 0 && string(t.name)
      && Number.isInteger(t.subtunesCount) && t.subtunesCount > 0 && t.subtunesCount <= 256) || !unique(doc.catalog.map(t => t.id))
    || !Array.isArray(doc.favorites) || !doc.favorites.every(string) || !unique(doc.favorites) || typeof doc.shuffle !== 'boolean'
    || !Array.isArray(doc.lists) || !unique(doc.lists.map(l => l.id)) || !doc.lists.every(l => string(l.id) && string(l.name)
      && ['regular', 'subtuneFavorites'].includes(l.kind) && entries(l.entries)
      && (l.kind !== 'subtuneFavorites' || l.entries.every(e => e.subtune != null)
        && unique(l.entries.map(e => JSON.stringify([e.trackID, e.subtune])))))) throw new Error('Invalid listening data. The original data is preserved.');
  if (doc.queue && (!string(doc.queue.name) || !entries(doc.queue.items)
    || !['library', 'selection', 'savedList'].includes(doc.queue.kind) || typeof doc.queue.shuffled !== 'boolean'
    || typeof doc.queue.wraps !== 'boolean' || !Array.isArray(doc.queue.oneShotIDs)
    || doc.queue.currentID != null && !doc.queue.items.some(e => e.id === doc.queue.currentID)
    || !doc.queue.oneShotIDs.every(id => doc.queue.items.some(e => e.id === id)))) throw new Error('Invalid listening queue. The original data is preserved.');
  if (doc.session && (!string(doc.session.trackID) || !Number.isInteger(doc.session.subtune) || doc.session.subtune < 0
    || doc.session.subtune > 255 || !Number.isFinite(doc.session.position) || doc.session.position < 0)) throw new Error('Invalid listening session. The original data is preserved.');
}
class ListeningDataStore {
  constructor(storage, key = 'vicious-listening-v1', empty = emptyListeningDocument, validate = validateListeningDocument) {
    this.storage = storage; this.key = key; this.document = empty(); this.validate = validate; this.readOnly = false; this.error = null;
    if (!storage) { this.error = 'Storage is unavailable. Changes are temporary.'; return; }
    let raw;
    try { raw = storage.getItem(key); }
    catch (_) { this.storage = null; this.error = 'Storage is unavailable. Changes are temporary.'; return; }
    this.savedRaw = raw;
    if (raw) {
      try { if (raw.length > 32 * 1024 * 1024) throw new Error('Personal data is too large'); const doc = JSON.parse(raw); this.validate(doc); this.document = doc; }
      catch (_) { this.readOnly = true; this.error = 'Saved listening data cannot be read. The original data is preserved.'; }
    }
  }
  save() {
    if (this.readOnly) return false;
    if (!this.storage) { this.error = 'Storage is unavailable. Changes are temporary.'; return false; }
    try {
      if (this.storage.getItem(this.key) !== this.savedRaw) {
        this.readOnly = true; this.error = 'Listening data changed in another page. Reload this page before making changes.'; return false;
      }
      this.validate(this.document);
      const raw = JSON.stringify(this.document); if (raw.length > 32 * 1024 * 1024) throw new Error('Personal data is too large'); this.storage.setItem(this.key, raw); this.savedRaw = raw; this.error = null; return true;
    } catch (_) { this.error = 'Changes could not be saved. They remain available in this session.'; return false; }
  }
}
