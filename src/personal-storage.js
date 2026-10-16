const personalStorageKeys = ['vicious-listening-v2', 'vicious-history-v2'];
const personalLegacyKeys = ['vicious-listening-v1', 'vicious-history-v1'];
const personalJournalKey = 'vicious-collection-journal-v1';
const personalStorageLock = 'vicious-personal-data-v2';
function personalRawSignature(raw) { return raw == null ? null : collectionMD5(new TextEncoder().encode(raw)); }
function validateListeningV2(doc) {
  if (doc?.version !== 2 || !(doc.legacySignature == null || collectionMD5Valid(doc.legacySignature))) throw new Error('Unsupported listening data.');
  validateListeningDocument({ ...doc, version: 1 });
  if (!doc.catalog.every(t => t.md5 == null || collectionMD5Valid(t.md5))) throw new Error('Invalid catalog identity.');
}
function validateHistoryV2(doc) {
  const string = (value, maximum, required = true) => collectionTextValid(value, maximum, required);
  const unique = values => new Set(values).size === values.length;
  const position = value => Number.isFinite(value) && value >= 0;
  const date = value => Number.isFinite(value) && value >= -62135596800000 && value <= 253402300799000;
  const reference = ref => ref && string(ref.trackID, 8192) && collectionSubtuneValid(ref.subtune)
    && (collectionMD5Valid(ref.md5) || typeof ref.fingerprint === 'string' && /^[a-f0-9]{16}$/.test(ref.fingerprint))
    && (ref.md5 == null || collectionMD5Valid(ref.md5)) && (ref.path == null || collectionPathValid(ref.path));
  const array = (value, maximum) => Array.isArray(value) && value.length <= maximum;
  const heard = new Set(Array.isArray(doc?.heard) ? doc.heard : []), heardMD5s = new Set(Array.isArray(doc?.heardMD5s) ? doc.heardMD5s : []);
  if (doc?.version !== 2 || !(doc.legacySignature == null || collectionMD5Valid(doc.legacySignature))
    || !array(doc.events, 20000) || !array(doc.bookmarks, 20000) || !array(doc.notes, 20000)
    || !array(doc.heard, 200000) || !doc.heard.every(v => typeof v === 'string' && /^[a-f0-9]{16}$/.test(v)) || !unique(doc.heard)
    || !array(doc.heardMD5s, 200000) || !doc.heardMD5s.every(collectionMD5Valid) || !unique(doc.heardMD5s)
    || ![doc.events, doc.bookmarks, doc.notes].every(values => unique(values.map(e => e.id)) && values.every(e => string(e.id, 128) && reference(e.reference)))
    || !doc.events.every(e => e.reference.subtune != null && string(e.title, 1024, false) && date(e.startedAt) && date(e.lastHeardAt)
      && e.lastHeardAt >= e.startedAt && Number.isFinite(e.heardSeconds) && e.heardSeconds >= 1 && position(e.lastPosition)
      && (e.reference.md5 ? heardMD5s.has(e.reference.md5) : heard.has(e.reference.fingerprint)))
    || !doc.bookmarks.every(e => e.reference.subtune != null && string(e.name, 200) && position(e.position) && date(e.updatedAt))
    || !doc.notes.every(e => string(e.text, 16000) && date(e.updatedAt)) || !unique(doc.notes.map(e => historyContentKey(e.reference)))) throw new Error('Invalid or unsupported personal data. The original data is preserved.');
}
class WebPersonalStorage {
  constructor(storage, locks) {
    this.storage = storage; this.locks = locks; this.stores = []; this.saved = []; this.pending = Promise.resolve();
    this.generation = 0; this.error = null; this.readOnly = false;
  }
  protect(message) {
    this.error = message; this.readOnly = true;
    for (const store of this.stores) { store.readOnly = true; store.error = message; }
  }
  async locked(action) {
    if (!this.storage || !this.locks?.request) throw new Error('This browser cannot safely lock personal data. Use a browser with Web Locks support.');
    const abort = new AbortController(), timeout = setTimeout(() => abort.abort(), 10000);
    try { return await this.locks.request(personalStorageLock, { mode: 'exclusive', signal: abort.signal }, action); }
    finally { clearTimeout(timeout); }
  }
  recover() {
    const raw = this.storage.getItem(personalJournalKey);
    if (raw == null) return;
    let journal;
    try {
      if (new TextEncoder().encode(raw).byteLength > collectionMaximumBytes * 5) throw new Error();
      journal = JSON.parse(raw);
      if (journal.version !== 1 || !['prepared', 'committed'].includes(journal.phase) || !Array.isArray(journal.records)
        || journal.records.length !== 2 || !journal.records.every((r, i) => r.key === personalStorageKeys[i]
          && (r.before == null || typeof r.before === 'string') && typeof r.after === 'string')) throw new Error();
      journal.records.forEach((record, i) => {
        for (const value of [record.before, record.after]) if (value != null) {
          if (new TextEncoder().encode(value).byteLength > collectionMaximumBytes) throw new Error();
          [validateListeningV2, validateHistoryV2][i](JSON.parse(value));
        }
      });
      for (const record of journal.records) {
        const current = this.storage.getItem(record.key);
        if (current !== record.before && current !== record.after) throw new Error();
      }
    } catch (_) { throw new Error('An unfinished import conflicts with saved data. All original data and the recovery journal are preserved.'); }
    for (const record of journal.records) {
      const target = journal.phase === 'committed' ? record.after : record.before;
      if (target == null) this.storage.removeItem(record.key); else this.storage.setItem(record.key, target);
    }
    this.storage.removeItem(personalJournalKey);
  }
  assertCurrent(expected = this.saved) {
    for (let i = 0; i < 2; i++) {
      if (this.storage.getItem(personalStorageKeys[i]) !== expected[i]
        || personalRawSignature(this.storage.getItem(personalLegacyKeys[i])) !== this.stores[i].document.legacySignature) {
        throw new Error('Personal data changed in another page, including an older player. Reload this page; the other data is preserved.');
      }
    }
  }
  commit(documents, expected = this.saved) {
    this.recover(); this.assertCurrent(expected);
    const after = documents.map((doc, i) => {
      [validateListeningV2, validateHistoryV2][i](doc);
      const raw = JSON.stringify(doc);
      if (new TextEncoder().encode(raw).byteLength > collectionMaximumBytes) throw new Error('Personal data is limited to 32 MiB per document.');
      return raw;
    });
    if (after.every((raw, i) => raw === expected[i])) return;
    const records = personalStorageKeys.map((key, i) => ({ key, before: expected[i], after: after[i] }));
    const journal = { version: 1, phase: 'prepared', records };
    this.storage.setItem(personalJournalKey, JSON.stringify(journal));
    try {
      for (const record of records) this.storage.setItem(record.key, record.after);
      this.storage.setItem(personalJournalKey, JSON.stringify({ ...journal, phase: 'committed' }));
    } catch (error) {
      try { this.recover(); } catch (_) { this.protect('Import recovery is required. The saved originals and recovery journal are preserved. Reload before editing.'); }
      throw error;
    }
    this.saved = after;
    this.error = null;
    this.stores.forEach((store, i) => { store.savedRaw = after[i]; store.error = null; });
    // Nach dem Commit ist ein fehlgeschlagenes Journal-Cleanup kein Rollback.
    // Der nächste gesperrte Zugriff oder Neustart beendet nur dieses Cleanup.
    try { this.storage.removeItem(personalJournalKey); } catch (_) {}
  }
  async open() {
    const empty = [emptyListeningDocument, emptyHistoryDocument], validators = [validateListeningDocument, validateHistoryDocument];
    try {
      await this.locked(() => {
        this.recover();
        const raws = personalStorageKeys.map(key => this.storage.getItem(key));
        if (raws.some(raw => raw != null) && raws.some(raw => raw == null)) throw new Error('Incomplete personal data. Existing data is preserved.');
        const documents = raws.map((raw, i) => {
          if (raw != null) {
            if (new TextEncoder().encode(raw).byteLength > collectionMaximumBytes) throw new Error('Personal data is too large.');
            const doc = JSON.parse(raw); [validateListeningV2, validateHistoryV2][i](doc); return doc;
          }
          const legacy = this.storage.getItem(personalLegacyKeys[i]);
          if (legacy != null && new TextEncoder().encode(legacy).byteLength > collectionMaximumBytes) throw new Error('Legacy personal data is too large.');
          const doc = legacy == null ? empty[i]() : JSON.parse(legacy); validators[i](doc);
          return { ...doc, version: 2, legacySignature: personalRawSignature(legacy), ...(i === 1 ? { heardMD5s: [] } : {}) };
        });
        this.saved = raws;
        this.stores = documents.map((document, i) => ({ document, storage: this.storage, key: personalStorageKeys[i],
          readOnly: false, error: null, savedRaw: raws[i], save: () => this.save() }));
        this.assertCurrent();
        if (raws.every(raw => raw == null)) this.commit(documents);
      });
    } catch (error) {
      if (!this.stores.length) this.stores = empty.map((factory, i) => {
        const store = new ListeningDataStore(this.storage, personalLegacyKeys[i], factory, validators[i]);
        return { ...store, save: () => Promise.resolve(false) };
      });
      this.protect(error.name === 'QuotaExceededError' ? 'Browser storage could not migrate personal data. All original data is preserved.'
        : error.message || 'Personal data cannot be loaded. The originals are preserved.');
    }
    return this;
  }
  save() {
    if (this.readOnly) return Promise.resolve(false);
    const generation = this.generation, documents = this.stores.map(store => collectionClone(store.document));
    const operation = this.pending.then(() => this.locked(() => {
      if (generation !== this.generation || this.readOnly) return false;
      this.commit(documents); return true;
    })).catch(error => {
      if (/changed in another|recovery|unfinished|Incomplete/.test(error.message)) this.protect(error.message);
      else for (const store of this.stores) store.error = 'Changes could not be saved. They remain available in this session.';
      this.error = error.message; return false;
    });
    this.pending = operation; return operation;
  }
  async apply(documents, expected, before) {
    await this.pending;
    return this.locked(() => {
      if (this.readOnly) throw new Error(this.error);
      if (!this.stores.every((store, i) => collectionEqual(store.document, before[i]))) throw new Error('Personal data changed during the preview. Refresh the preview.');
      this.assertCurrent(expected); this.generation++;
      this.commit(documents, expected);
      this.stores.forEach((store, i) => { store.document = documents[i]; });
    });
  }
}
