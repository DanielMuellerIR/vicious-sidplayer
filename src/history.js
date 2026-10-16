// Wie im nativen Core: monotone Hoerzeit, begrenzte Ereignisse und ein
// davon unabhaengiger Gehoert-Index. Alte FNV-Referenzen bleiben lesbar;
// nach Inhaltsprüfung ergänzt MD5 die portable Identität.
function emptyHistoryDocument() { return { version: 1, events: [], heard: [], bookmarks: [], notes: [] }; }
function historyContentKey(reference) { return (reference.md5 || reference.fingerprint) + ':' + (reference.subtune ?? 'file'); }
function validateHistoryDocument(doc) {
  const string = (value, maximum) => typeof value === 'string' && value.length > 0 && value.length <= maximum && !value.includes('\0');
  const position = value => Number.isFinite(value) && value >= 0;
  const reference = value => value && string(value.trackID, 8192) && typeof value.fingerprint === 'string' && /^[a-f0-9]{16}$/.test(value.fingerprint)
    && (value.subtune == null || Number.isInteger(value.subtune) && value.subtune >= 0 && value.subtune < 256);
  const array = (value, maximum) => Array.isArray(value) && value.length <= maximum;
  const unique = values => new Set(values).size === values.length;
  if (!doc || doc.version !== 1 || !array(doc.events, 20000) || !array(doc.heard, 200000)
    || !array(doc.bookmarks, 20000) || !array(doc.notes, 20000)
    || !doc.heard.every(value => typeof value === 'string' && /^[a-f0-9]{16}$/.test(value)) || !unique(doc.heard)
    || ![doc.events, doc.bookmarks, doc.notes].every(values => unique(values.map(item => item.id)))
    || !doc.events.every(e => string(e.id, 128) && reference(e.reference) && e.reference.subtune != null
      && string(e.title, 1024) && position(e.startedAt) && position(e.lastHeardAt) && e.lastHeardAt >= e.startedAt
      && Number.isFinite(e.heardSeconds) && e.heardSeconds >= 1 && position(e.lastPosition) && doc.heard.includes(e.reference.fingerprint))
    || !doc.bookmarks.every(e => string(e.id, 128) && reference(e.reference) && e.reference.subtune != null
      && string(e.name, 200) && e.name.trim() && position(e.position) && position(e.updatedAt))
    || !doc.notes.every(e => string(e.id, 128) && reference(e.reference) && string(e.text, 16000) && e.text.trim() && position(e.updatedAt))
    || !unique(doc.notes.map(e => historyContentKey(e.reference)))) throw new Error('Invalid or unsupported personal data. The original data is preserved.');
}
function pruneHistory(document, now = Date.now(), count = 2000, days = 180) {
  document.events = document.events.filter(e => e.lastHeardAt >= now - days * 86400000)
    .sort((a, b) => b.lastHeardAt - a.lastHeardAt || a.id.localeCompare(b.id)).slice(0, count);
}
class WebHistoryStore extends ListeningDataStore {
  constructor(storage) { super(storage, 'vicious-history-v1', emptyHistoryDocument, validateHistoryDocument); }
}
class WebHistoryRecorder {
  constructor() { this.reset(); }
  reset() { this.episode = null; this.previous = null; this.lastPlaying = null; this.threshold = 10; }
  qualified() { return this.episode?.heardSeconds >= this.threshold ? { ...this.episode } : null; }
  observe({ reference, title, position, knownDuration = null, playing, uptime, now = Date.now() }) {
    if (![position, uptime, now].every(value => Number.isFinite(value) && value >= 0)) { this.reset(); return null; }
    if (this.previous && uptime < this.previous.uptime) this.reset();
    const previous = this.previous;
    if (previous?.playing && this.episode) {
      const delta = uptime - previous.uptime;
      if (delta > 0 && delta <= 30) {
        this.episode.heardSeconds += delta; this.episode.lastHeardAt = Math.max(this.episode.lastHeardAt, now);
        if (reference?.trackID === previous.reference.trackID && reference?.subtune === previous.reference.subtune
          && (playing || position >= previous.position)) this.episode.lastPosition = position;
        this.lastPlaying = uptime;
      }
    }
    const completed = this.qualified();
    if (!reference || reference.subtune == null) { this.reset(); return completed; }
    if (this.episode && (JSON.stringify(reference) !== JSON.stringify(this.episode.reference)
      || playing && this.lastPlaying != null && uptime - this.lastPlaying > 900)) this.episode = null;
    if (playing) {
      if (!this.episode) this.episode = { id: listeningID(), reference: { ...reference }, title, startedAt: now, lastHeardAt: now, heardSeconds: 0, lastPosition: position };
      this.episode.lastPosition = position; this.lastPlaying = uptime;
    }
    this.threshold = Number.isFinite(knownDuration) && knownDuration > 0 ? Math.min(10, Math.max(1, knownDuration / 2)) : 10;
    this.previous = { reference, position, uptime, playing };
    return this.qualified() || completed;
  }
}
