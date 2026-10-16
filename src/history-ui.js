let webHistoryStore = null;
const webHistoryRecorder = new WebHistoryRecorder();
let lastHistoryObservation = -1, lastHistorySave = -1, historyEditor = null;
function currentWebHistoryReference() {
  const track = trackList[currentIdx], metadata = track && webCatalogEntry(track.id);
  return metadata ? { trackID: track.id, fingerprint: metadata.fingerprint, ...(metadata.md5 ? { md5: metadata.md5, path: metadata.path } : {}), subtune: currentSubtune } : null;
}
function initializeWebHistory(storage, store = null) {
  webHistoryStore = store || new WebHistoryStore(storage);
  if (!webHistoryStore.readOnly) pruneHistory(webHistoryStore.document);
  $('never-heard').addEventListener('input', () => { listeningUI.offset = 0; renderListeningUI(); });
  $('history-section').addEventListener('change', () => { listeningUI.offset = 0; renderListeningUI(); });
  $('add-bookmark').addEventListener('click', () => openWebHistoryEditor('bookmark'));
  $('add-note').addEventListener('click', () => openWebHistoryEditor('note'));
  $('clear-history').addEventListener('click', () => {
    if (webHistoryStore.readOnly || !window.confirm('Clear all listening history and heard status? Bookmarks, notes and music files are kept.')) return;
    webHistoryStore.document.events = []; webHistoryStore.document.heard = [];
    if (webHistoryStore.document.heardMD5s) webHistoryStore.document.heardMD5s = [];
    webHistoryRecorder.reset();
    lastHistoryObservation = -1; saveWebHistory(); renderListeningUI();
  });
  $('history-editor-cancel').addEventListener('click', () => $('history-editor').close());
  $('history-note-scope').addEventListener('change', () => {
    if (historyEditor?.kind !== 'note') return;
    historyEditor.reference.subtune = $('history-note-scope').value === 'file' ? null : historyEditor.subtune;
    $('history-editor-text').value = webHistoryStore.document.notes.find(n => historyContentKey(n.reference) === historyContentKey(historyEditor.reference))?.text || '';
  });
  $('history-editor-form').addEventListener('submit', event => {
    event.preventDefault();
    if (!historyEditor || webHistoryStore.readOnly) return;
    const text = $('history-editor-text').value, doc = JSON.parse(JSON.stringify(webHistoryStore.document));
    const reference = { ...historyEditor.reference }, now = Date.now();
    if (historyEditor.kind === 'bookmark') {
      if (!text.trim()) return;
      doc.bookmarks.unshift({ id: listeningID(), reference, name: text, position: historyEditor.position, updatedAt: now });
    } else {
      const previous = doc.notes.find(n => historyContentKey(n.reference) === historyContentKey(reference));
      doc.notes = doc.notes.filter(n => historyContentKey(n.reference) !== historyContentKey(reference));
      if (text.trim()) doc.notes.push({ id: previous?.id || listeningID(), reference, text, updatedAt: now });
    }
    try { (doc.version === 2 ? validateHistoryV2 : validateHistoryDocument)(doc); } catch (_) { showError('Personal data is too large or invalid. Existing data is kept.'); return; }
    webHistoryStore.document = doc; saveWebHistory(); $('history-editor').close(); renderListeningUI();
  });
  window.addEventListener('pagehide', () => { observeWebHistory(false, true); saveWebHistory(); });
}
function saveWebHistory() {
  if (!webHistoryStore || webCollectionBusy) return Promise.resolve(false);
  const saved = webHistoryStore.save();
  $('history-status').textContent = webHistoryStore.error || '';
  return Promise.resolve(saved).then(result => { $('history-status').textContent = webHistoryStore.error || ''; return result; });
}
function observeWebHistory(playing = playingState && player.playing && !player.seeking, force = false) {
  if (!webHistoryStore || webHistoryStore.readOnly || webCollectionBusy) return;
  const uptime = performance.now() / 1000;
  if (!force && lastHistoryObservation >= 0 && uptime - lastHistoryObservation < 1) return;
  lastHistoryObservation = uptime;
  const reference = currentWebHistoryReference();
  const event = webHistoryRecorder.observe({ reference, title: metaTitle.textContent || trackList[currentIdx]?.name || 'Untitled',
    position: Math.max(0, lastVisuals.playtime || 0), playing, uptime });
  if (event) {
    const doc = webHistoryStore.document, index = doc.events.findIndex(e => e.id === event.id);
    if (index >= 0) doc.events[index] = event; else doc.events.push(event);
    if (event.reference.md5 && doc.heardMD5s) {
      if (!doc.heardMD5s.includes(event.reference.md5)) doc.heardMD5s.push(event.reference.md5);
    } else if (!doc.heard.includes(event.reference.fingerprint)) doc.heard.push(event.reference.fingerprint);
    pruneHistory(doc);
    if (force || uptime - lastHistorySave >= 5) { saveWebHistory(); lastHistorySave = uptime; }
    if (listeningUI.page === 'history' || $('never-heard').checked) renderListeningUI();
  }
}
function seekWebPlayback(seconds) { if (webCollectionBusy) return; observeWebHistory(false, true); player.seek(seconds); }
function openWebHistoryEditor(kind, note = null) {
  const reference = note?.reference || currentWebHistoryReference();
  if (!reference || webHistoryStore.readOnly) return;
  historyEditor = { kind, reference: { ...reference }, subtune: reference.subtune ?? currentSubtune, position: lastVisuals.playtime || 0 };
  $('history-editor-title').textContent = kind === 'bookmark' ? 'Bookmark' : 'Personal note';
  $('history-editor-reference').textContent = webCatalogEntry(reference.trackID)?.path || reference.path || reference.trackID;
  $('history-note-scope-label').hidden = kind !== 'note' || !!note;
  $('history-note-scope').value = reference.subtune == null ? 'file' : 'subtune';
  $('history-editor-text').removeAttribute('maxlength');
  $('history-editor-text').value = kind === 'bookmark' ? `${metaTitle.textContent} · ${fmtTime(historyEditor.position)}`.slice(0, 200)
    : webHistoryStore.document.notes.find(n => historyContentKey(n.reference) === historyContentKey(reference))?.text || '';
  $('history-editor').showModal(); $('history-editor-text').focus();
}
async function playWebHistoryReference(reference, position) {
  if (!Number.isFinite(position) || position < 0 || position > 1200) { showError('Position jumps are supported up to 20:00 min. Your saved position is kept.'); return; }
  if (webCollectionBusy) return;
  let matches = trackList.filter(t => reference.md5 ? webCatalogEntry(t.id)?.md5 === reference.md5 : webCatalogEntry(t.id)?.fingerprint === reference.fingerprint);
  const exact = matches.find(t => t.id === reference.trackID);
  if (exact) matches = [exact];
  if (matches.length !== 1) { showError(matches.length ? 'Several files have this content. Select the intended file in Music.' : 'This file is unavailable. Select its file or folder again.'); return; }
  const generation = trackLoadGeneration + 1;
  if (!await loadTrack(trackList.indexOf(matches[0]), false, reference.subtune ?? 0)) return;
  seekWebPlayback(position); lastVisuals.playtime = position;
  const playGeneration = ++playbackGeneration;
  try {
    player.resumeContext(); await player.play(WORKLET_URL);
    if (generation === trackLoadGeneration && playGeneration === playbackGeneration) setPlayingUI(player.playing);
  } catch (error) { if (generation === trackLoadGeneration) showError(error.message || String(error)); }
  persistWebListening(); renderListeningUI();
}
function renderWebHistory() {
  const doc = webHistoryStore.document, readonly = webHistoryStore.readOnly, section = $('history-section').value || 'events';
  const items = doc[section];
  for (const id of ['add-bookmark', 'add-note']) $(id).disabled = readonly || currentIdx < 0;
  $('clear-history').disabled = readonly || !(doc.heard.length || doc.heardMD5s?.length);
  $('history-status').textContent = webHistoryStore.error || '';
  listeningUI.offset = Math.min(listeningUI.offset, Math.max(0, Math.floor((items.length - 1) / listeningUI.pageSize) * listeningUI.pageSize));
  trackListContainer.innerHTML = '';
  for (const item of items.slice(listeningUI.offset, listeningUI.offset + listeningUI.pageSize)) {
    const row = document.createElement('div'); row.className = 'history-entry';
    const title = document.createElement('strong'); title.textContent = item.title || item.name || 'Personal note'; row.appendChild(title);
    const detail = document.createElement('small'); detail.textContent = (webCatalogEntry(item.reference.trackID)?.path || item.reference.path || item.reference.trackID) + (item.reference.subtune == null ? ' · whole file' : ` · subtune ${item.reference.subtune + 1}`); row.appendChild(detail);
    if (section === 'events') {
      const time = document.createElement('small'); time.textContent = `${new Date(item.lastHeardAt).toLocaleString()} · ${fmtTime(item.heardSeconds)} heard`; row.appendChild(time);
    }
    if (section === 'notes') {
      const note = document.createElement('p'); note.textContent = item.text; row.appendChild(note);
      row.appendChild(webButton('Edit note', () => openWebHistoryEditor('note', item), readonly));
    }
    const actions = document.createElement('div'); actions.className = 'tool-row';
    actions.appendChild(webButton('From start', () => playWebHistoryReference(item.reference, 0)));
    const position = item.lastPosition ?? item.position;
    if (position != null) actions.appendChild(webButton(`At ${fmtTime(position)}`, () => playWebHistoryReference(item.reference, position), position > 1200));
    row.appendChild(actions);
    if (position > 1200) { const limit = document.createElement('small'); limit.textContent = 'Position jumps are supported up to 20:00 min.'; row.appendChild(limit); }
    if (section === 'bookmarks') row.appendChild(webButton('Delete bookmark', () => { doc.bookmarks = doc.bookmarks.filter(b => b.id !== item.id); saveWebHistory(); renderListeningUI(); }, readonly));
    trackListContainer.appendChild(row);
  }
  if (!items.length) { const empty = document.createElement('p'); empty.className = 'history-entry'; empty.textContent = section === 'events' ? 'Nothing heard yet. Playback is recorded after ten seconds.' : 'No saved entries yet. Add one from the current track.'; trackListContainer.appendChild(empty); }
  $('entries-page').textContent = items.length ? `${listeningUI.offset + 1}–${Math.min(items.length, listeningUI.offset + listeningUI.pageSize)} / ${items.length}` : '0 entries';
  $('entries-previous').disabled = listeningUI.offset === 0; $('entries-next').disabled = listeningUI.offset + listeningUI.pageSize >= items.length;
}
