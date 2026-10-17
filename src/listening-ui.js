const listeningUI = { page: 'library', offset: 0, pageSize: 100, selectedListID: null, nameAction: null, editingEntryID: null };
async function initializeListeningUI() {
  let storage;
  try { storage = localStorage; } catch (_) {}
  webPersonalStorage = await new WebPersonalStorage(storage, navigator.locks).open();
  webListeningStore = webPersonalStorage.stores[0];
  initializeWebHistory(storage, webPersonalStorage.stores[1]);
  initializeCollectionUI();
  initializeWebAnalysisUI();
  listeningQueue = webListeningStore.document.queue ? ListeningSequence.fromJSON(webListeningStore.document.queue) : null;
  pendingWebRestore = !!(listeningQueue || webListeningStore.document.session);
  if (listeningQueue && webListeningStore.document.shuffle) listeningQueue.restart(true, true);
  $('listening-shuffle').checked = webListeningStore.document.shuffle;
  for (const page of ['library', 'lists', 'queue', 'history']) $('tab-' + page).addEventListener('click', () => switchListeningPage(page));
  for (const id of ['library-search', 'favorites-only']) $(id).addEventListener('input', () => { listeningUI.offset = 0; refreshPlaylistUI(); });
  $('play-library').addEventListener('click', () => startWebScope('library'));
  $('play-selection').addEventListener('click', () => startWebScope('visible'));
  $('play-favorites').addEventListener('click', () => startWebScope('favorites'));
  $('play-folder').addEventListener('click', () => startWebScope('folder'));
  $('save-selection').addEventListener('click', () => promptListeningName('Save results', '', name => createWebList(name, webScopeEntries('visible'))));
  $('new-list').addEventListener('click', () => promptListeningName('New listening list', '', name => createWebList(name, [])));
  $('rename-list').addEventListener('click', () => {
    const list = selectedWebList(); if (!list || list.kind !== 'regular') return;
    promptListeningName('Rename list', list.name, name => { list.name = name; persistWebListening(); renderListeningUI(); });
  });
  $('delete-list').addEventListener('click', () => {
    const list = selectedWebList(); if (!list || webListeningStore.readOnly) return;
    if (!window.confirm('Delete this saved list? Music files are kept.')) return;
    webListeningStore.document.lists = webListeningStore.document.lists.filter(l => l.id !== list.id);
    listeningUI.selectedListID = null; persistWebListening(); renderListeningUI();
  });
  $('list-picker').addEventListener('change', () => { listeningUI.selectedListID = $('list-picker').value; listeningUI.offset = 0; renderListeningUI(); });
  $('play-list').addEventListener('click', () => { const list = selectedWebList(); if (list) startWebList(list); });
  $('append-subtune').addEventListener('click', () => {
    const list = selectedWebList(), track = trackList[currentIdx];
    if (list && track) appendWebListEntry(list, listeningEntry(track.id, currentSubtune));
  });
  $('save-queue').addEventListener('click', () => {
    if (listeningQueue) promptListeningName('Save queue', listeningQueue.name, name => createWebList(name, listeningQueue.items));
  });
  $('end-queue').addEventListener('click', () => { stopWebSequence(); listeningQueue = null; persistWebListening(); renderListeningUI(); });
  $('clear-library').addEventListener('click', () => {
    if (!window.confirm('Clear the library and queue? Saved lists and music files are kept.')) return;
    observeWebHistory(false, true);
    player.unload(); bindWebPlayerCallbacks(); currentIdx = -1; trackList = []; listeningQueue = null; pendingWebRestore = false;
    currentMetadata = null; applyWebAnalysisMix();
    webListeningStore.document.libraryIDs = []; webListeningStore.document.session = null;
    playBtn.disabled = true; positionScrubber.disabled = true; setPlayingUI(false);
    persistWebListening(); renderListeningUI();
  });
  $('previous-track').addEventListener('click', () => advanceWebQueue(false, playingState));
  $('next-track').addEventListener('click', () => advanceWebQueue(true, playingState));
  $('listening-shuffle').addEventListener('change', () => {
    listeningQueue?.setShuffle($('listening-shuffle').checked); persistWebListening(); renderListeningUI();
  });
  $('favorite-subtune').addEventListener('click', toggleWebSubtuneFavorite);
  $('entries-previous').addEventListener('click', () => { listeningUI.offset = Math.max(0, listeningUI.offset - listeningUI.pageSize); renderListeningUI(); });
  $('entries-next').addEventListener('click', () => { listeningUI.offset += listeningUI.pageSize; renderListeningUI(); });
  $('cancel-list-name').addEventListener('click', () => $('list-name-dialog').close());
  $('list-name-form').addEventListener('submit', event => {
    event.preventDefault(); const name = $('list-name').value.trim(); if (!name || webListeningStore.readOnly) return;
    listeningUI.nameAction?.(name); $('list-name-dialog').close();
  });
  $('cancel-entry-subtune').addEventListener('click', () => $('entry-subtune-dialog').close());
  $('entry-subtune-form').addEventListener('submit', event => {
    event.preventDefault(); const list = selectedWebList(), entry = list?.entries.find(e => e.id === listeningUI.editingEntryID);
    const sub = Number($('entry-subtune').value) - 1, meta = entry && webCatalogEntry(entry.trackID);
    if (!entry || webListeningStore.readOnly || !Number.isInteger(sub) || sub < 0 || sub >= (meta?.subtunesCount || 1)) return;
    entry.subtune = sub; persistWebListening(); renderListeningUI(); $('entry-subtune-dialog').close();
  });
  window.addEventListener('pagehide', () => persistWebListening());
}
function webCatalogEntry(id) { return webListeningStore.document.catalog.find(t => t.id === id); }
function selectedWebList() { return webListeningStore.document.lists.find(l => l.id === listeningUI.selectedListID); }
function switchListeningPage(page) { listeningUI.page = page; listeningUI.offset = 0; renderListeningUI(); }
function promptListeningName(heading, name, action) {
  if (webListeningStore.readOnly) return;
  listeningUI.nameAction = action; $('list-name-heading').textContent = heading;
  $('list-name').value = name; $('list-name-dialog').showModal(); $('list-name').focus();
}
function createWebList(name, entries) {
  if (webListeningStore.readOnly) return;
  const list = { id: listeningID(), name, kind: 'regular', entries: entries.map(e => listeningEntry(e.trackID, e.subtune)) };
  webListeningStore.document.lists.push(list); listeningUI.selectedListID = list.id;
  persistWebListening(); switchListeningPage('lists');
}
function appendWebListEntry(list, entry) {
  if (webListeningStore.readOnly) return;
  if (list.kind === 'subtuneFavorites' && (entry.subtune == null || list.entries.some(e => e.trackID === entry.trackID && e.subtune === entry.subtune))) return;
  list.entries.push(listeningEntry(entry.trackID, entry.subtune)); persistWebListening(); renderListeningUI();
}
function toggleWebSubtuneFavorite() {
  if (webListeningStore.readOnly || !trackList[currentIdx]) return;
  let list = webListeningStore.document.lists.find(l => l.kind === 'subtuneFavorites');
  if (!list) {
    list = { id: listeningID(), name: 'Favorite subtunes', kind: 'subtuneFavorites', entries: [] };
    webListeningStore.document.lists.push(list);
  }
  const trackID = trackList[currentIdx].id, existing = list.entries.findIndex(e => e.trackID === trackID && e.subtune === currentSubtune);
  if (existing < 0) list.entries.push(listeningEntry(trackID, currentSubtune)); else list.entries.splice(existing, 1);
  persistWebListening(); renderListeningUI();
}
function visibleWebLibraryIDs() {
  const needle = $('library-search').value.trim().toLocaleLowerCase(), favorites = new Set(webListeningStore.document.favorites);
  const catalog = new Map(webListeningStore.document.catalog.map(t => [t.id, t]));
  return webListeningStore.document.libraryIDs.filter(id => {
    const track = catalog.get(id);
    return track && (!$('never-heard').checked || !webHistoryStore.readOnly && !!webHistoryStore.storage
      && !webHistoryStore.document.heard.includes(track.fingerprint) && !webHistoryStore.document.heardMD5s?.includes(track.md5))
      && (!$('favorites-only').checked || favorites.has(id)) && (!needle || (track.name + ' ' + track.path).toLocaleLowerCase().includes(needle));
  });
}
function webScopeEntries(scope) {
  let ids = webListeningStore.document.libraryIDs;
  if (scope === 'visible') ids = visibleWebLibraryIDs();
  if (scope === 'favorites') { const favorites = new Set(webListeningStore.document.favorites); ids = ids.filter(id => favorites.has(id)); }
  if (scope === 'folder') {
    const folder = $('folder-path').value.trim().replace(/^\/+|\/+$/g, '');
    ids = ids.filter(id => { const path = webCatalogEntry(id)?.path || ''; const parent = path.split('/').slice(0, -1).join('/'); return !folder || parent === folder || parent.startsWith(folder + '/'); });
  }
  return ids.map(id => listeningEntry(id));
}
async function startWebScope(scope) {
  const names = { library: 'Library', visible: 'Search results', favorites: 'Favorites', folder: $('folder-path').value || 'Library folder' };
  const entries = webScopeEntries(scope), shuffled = $('listening-shuffle').checked;
  const start = shuffled && entries.length ? Math.floor(Math.random() * entries.length) : 0;
  await startWebSequence(new ListeningSequence({ name: names[scope], kind: scope === 'library' ? 'library' : 'selection', entries,
    startingAt: start, shuffled, wraps: scope === 'library' && entries.length > 1 }));
}
async function startWebList(list, entryID = null) {
  const chosen = list.entries.findIndex(e => e.id === entryID), shuffled = $('listening-shuffle').checked;
  const start = chosen >= 0 ? chosen : shuffled && list.entries.length ? Math.floor(Math.random() * list.entries.length) : 0;
  await startWebSequence(new ListeningSequence({ name: list.name, kind: 'savedList', entries: list.entries, startingAt: start, shuffled }));
}
async function startWebSequence(queue) {
  if (!queue.items.length) { showError('This selection is empty.'); return; }
  let skipped = 0;
  for (let i = 0; i < queue.items.length; i++) {
    if (await playWebEntry(queue.current, true)) {
      listeningQueue = queue; pendingWebRestore = false; persistWebListening(); switchListeningPage('queue');
      if (skipped) showError(`${skipped} unavailable entries skipped. Select their files again to restore access.`);
      return;
    }
    skipped++; if (!queue.next()) break;
  }
  showError('No entries in this sequence are available. Select the same files or folder again.');
}
async function playWebEntry(entry, autoplay) {
  if (!entry) return false;
  const index = trackList.findIndex(t => t.id === entry.trackID);
  if (index < 0) return false;
  const meta = parseSidHeader(trackList[index].buffer), sub = entry.subtune ?? 0;
  if (!meta || sub >= meta.subtunesCount) return false;
  return await loadTrack(index, autoplay, sub, false);
}
async function advanceWebQueue(forward, autoplay) {
  if (!listeningQueue) return;
  const queue = ListeningSequence.fromJSON(listeningQueue);
  let skipped = 0;
  for (let i = 0; i < Math.max(1, queue.items.length); i++) {
    const entry = forward ? queue.next() : queue.previous();
    if (!entry) { if (forward) stopWebSequence(); else seekWebPlayback(0); return; }
    if (await playWebEntry(entry, autoplay)) {
      listeningQueue = queue; listeningUI.offset = Math.floor(queue.currentIndex / listeningUI.pageSize) * listeningUI.pageSize;
      persistWebListening(); renderListeningUI(); if (skipped) showError(`${skipped} unavailable entries skipped.`); return;
    }
    skipped++;
  }
  stopWebSequence(); showError('No further entries are available. Select their files again.');
}
async function enqueueWebEntry(entry) {
  if (!listeningQueue && currentIdx >= 0) makeDefaultWebQueue(currentIdx);
  if (listeningQueue) listeningQueue.enqueueNext(entry);
  else {
    listeningQueue = new ListeningSequence({ name: 'Next up', entries: [listeningEntry(entry.trackID, entry.subtune)] });
    await playWebEntry(listeningQueue.current, false);
  }
  persistWebListening(); renderListeningUI();
}
function stopWebSequence() { observeWebHistory(false, true); player.stop(); seekWebPlayback(0); lastVisuals.playtime = 0; setPlayingUI(false); persistWebListening(); }
function makeDefaultWebQueue(index) {
  const entries = webScopeEntries('library');
  const start = entries.findIndex(e => e.trackID === trackList[index]?.id);
  listeningQueue = new ListeningSequence({ name: 'Library', kind: 'library', entries, startingAt: Math.max(0, start),
    shuffled: $('listening-shuffle').checked, wraps: entries.length > 1 });
}
async function restoreWebListeningAfterImport() {
  if (!pendingWebRestore) return false;
  const saved = webListeningStore.document.session && { ...webListeningStore.document.session };
  const entry = listeningQueue?.current || (saved && listeningEntry(saved.trackID, saved.subtune));
  if (!entry || !await playWebEntry(entry, false)) return false;
  if (!$('listening-shuffle').checked && saved?.trackID === entry.trackID) {
    if (entry.subtune == null) setSubtune(saved.subtune);
    player.seek(saved.position); lastVisuals.playtime = saved.position;
  }
  pendingWebRestore = false; persistWebListening(); renderListeningUI(); return true;
}
function persistWebListening() {
  if (!webListeningStore || webCollectionBusy) return Promise.resolve(false);
  const doc = webListeningStore.document;
  doc.queue = listeningQueue; doc.shuffle = $('listening-shuffle').checked;
  if (trackList[currentIdx]?.id) doc.session = { trackID: trackList[currentIdx].id, subtune: currentSubtune, position: Math.max(0, lastVisuals.playtime || 0) };
  const saved = webListeningStore.save(); renderWebStorageStatus();
  return Promise.resolve(saved).then(result => { renderWebStorageStatus(); return result; });
}
function missingWebFileCount() {
  const doc = webListeningStore.document, loaded = new Set(trackList.map(t => t.id));
  const refs = [...doc.libraryIDs, ...doc.lists.flatMap(l => l.entries.map(e => e.trackID)), ...(listeningQueue?.items.map(e => e.trackID) || [])];
  return new Set(refs.filter(id => !loaded.has(id))).size;
}
function renderWebStorageStatus() {
  const missing = missingWebFileCount();
  $('listening-status').textContent = [webListeningStore.error, $('never-heard').checked ? webHistoryStore?.error : null, missing ? `${missing} files need selection. Reopen the same files or folder; saved lists do not grant file access.` : ''].filter(Boolean).join('\n');
}
function webButton(label, action, disabled = false, className = '') {
  const button = document.createElement('button'); button.type = 'button'; button.textContent = label; button.disabled = disabled;
  button.className = className;
  const names = { '↑': 'Move entry up', '↓': 'Move entry down', '↗': 'Play next', '#': 'Choose subtune', 'All': 'Play all subtunes', '×': 'Remove entry', '★': 'Remove favorite', '☆': 'Mark favorite' };
  if (names[label]) { button.setAttribute('aria-label', names[label]); button.title = names[label]; }
  button.addEventListener('click', action); return button;
}
function renderListeningUI() {
  if (!webListeningStore) return;
  const doc = webListeningStore.document, readonly = webListeningStore.readOnly, loaded = new Set(trackList.map(t => t.id));
  if (!selectedWebList()) listeningUI.selectedListID = doc.lists[0]?.id || null;
  for (const page of ['library', 'lists', 'queue', 'history']) {
    $('tab-' + page).setAttribute('aria-selected', String(listeningUI.page === page)); $(page + '-tools').hidden = listeningUI.page !== page;
  }
  for (const id of ['list-picker', 'append-list']) {
    const picker = $(id), previous = picker.value; picker.innerHTML = '';
    const placeholder = document.createElement('option'); placeholder.value = ''; placeholder.textContent = id === 'append-list' ? 'Add tracks to a list…' : 'Select a list'; picker.appendChild(placeholder);
    for (const list of doc.lists.filter(l => id !== 'append-list' || l.kind === 'regular')) {
      const option = document.createElement('option'); option.value = list.id; option.textContent = list.name; picker.appendChild(option);
    }
    picker.value = id === 'list-picker' ? listeningUI.selectedListID || '' : previous;
  }
  const list = selectedWebList();
  $('rename-list').disabled = readonly || !list || list.kind !== 'regular'; $('delete-list').disabled = readonly || !list;
  $('play-list').disabled = !list?.entries.length; $('append-subtune').disabled = readonly || !list || currentIdx < 0;
  for (const id of ['save-selection', 'new-list', 'save-queue']) $(id).disabled = readonly || id === 'save-queue' && !listeningQueue;
  $('queue-title').textContent = listeningQueue?.name || 'No active queue';
  $('queue-position').textContent = listeningQueue ? `${listeningQueue.currentIndex + 1} / ${listeningQueue.items.length} · ${listeningQueue.shuffled ? 'Shuffle' : 'In order'}` : 'Start a selection or a saved list.';
  const navigable = (listeningQueue?.items.length || 0) > 1;
  $('previous-track').disabled = !navigable; $('next-track').disabled = !navigable;
  const favorite = currentIdx >= 0 && doc.lists.some(l => l.kind === 'subtuneFavorites' && l.entries.some(e => e.trackID === trackList[currentIdx].id && e.subtune === currentSubtune));
  $('favorite-subtune').textContent = favorite ? '★ Favorite subtune' : '☆ Favorite subtune'; $('favorite-subtune').disabled = readonly || currentIdx < 0;
  trackSelect.innerHTML = '';
  const placeholder = document.createElement('option'); placeholder.value = ''; placeholder.textContent = `— ${trackList.length} available tunes —`; trackSelect.appendChild(placeholder);
  const menuStart = Math.max(0, Math.min(Math.max(0, currentIdx - 100), trackList.length - 200));
  for (let i = menuStart; i < Math.min(trackList.length, menuStart + 200); i++) {
    const option = document.createElement('option'); option.value = String(i); option.textContent = trackList[i].name; trackSelect.appendChild(option);
  }
  trackSelect.value = currentIdx >= 0 ? String(currentIdx) : '';
  if (listeningUI.page === 'history') { renderWebHistory(); renderWebStorageStatus(); return; }
  const rows = listeningUI.page === 'library' ? visibleWebLibraryIDs().map(id => ({ id, trackID: id, subtune: null }))
    : listeningUI.page === 'lists' ? list?.entries || [] : listeningQueue?.items || [];
  listeningUI.offset = Math.min(listeningUI.offset, Math.max(0, Math.floor((rows.length - 1) / listeningUI.pageSize) * listeningUI.pageSize));
  trackListContainer.innerHTML = '';
  for (const [localIndex, entry] of rows.slice(listeningUI.offset, listeningUI.offset + listeningUI.pageSize).entries()) {
    const absoluteIndex = listeningUI.offset + localIndex;
    const metadata = webCatalogEntry(entry.trackID), row = document.createElement('div'); row.className = 'listening-entry';
    if (listeningUI.page === 'queue' ? listeningQueue?.currentID === entry.id : trackList[currentIdx]?.id === entry.trackID && (entry.subtune == null || entry.subtune === currentSubtune)) row.classList.add('active');
    const main = webButton('', async () => {
      if (listeningUI.page === 'library') { const index = trackList.findIndex(t => t.id === entry.trackID); if (index >= 0) await loadTrack(index, true); else showError('Select this file again to restore access.'); }
      else if (listeningUI.page === 'lists') await startWebList(list, entry.id);
      else if (await playWebEntry(entry, true)) { listeningQueue.select(entry.id); persistWebListening(); renderListeningUI(); }
    }, false, 'entry-main');
    const title = document.createElement('span'); title.className = 'entry-title'; title.textContent = (metadata?.name || entry.trackID).split('/').pop();
    main.title = metadata?.path || entry.trackID;
    const detail = document.createElement('span'); detail.className = 'entry-detail'; detail.textContent = (listeningUI.page === 'library' && metadata?.path.includes('/') ? metadata.path.split('/').slice(0, -1).join('/') : entry.subtune == null ? 'All subtunes' : `Subtune ${entry.subtune + 1}`) + (loaded.has(entry.trackID) ? '' : ' · Select file again');
    main.appendChild(title); main.appendChild(detail); row.appendChild(main);
    if (listeningUI.page === 'library') {
      const favorite = doc.favorites.includes(entry.trackID);
      row.appendChild(webButton(favorite ? '★' : '☆', () => {
        if (readonly) return;
        doc.favorites = favorite ? doc.favorites.filter(id => id !== entry.trackID) : [...doc.favorites, entry.trackID]; persistWebListening(); renderListeningUI();
      }, readonly, 'entry-action'));
      row.appendChild(webButton('↗', () => {
        enqueueWebEntry(entry);
      }, false, 'entry-action'));
      const add = webButton('+', () => { const target = doc.lists.find(l => l.id === $('append-list').value); if (target) appendWebListEntry(target, entry); }, readonly, 'entry-action');
      add.setAttribute('aria-label', 'Add track to selected list'); row.appendChild(add);
    } else {
      for (const [label, delta] of [['↑', -1], ['↓', 1]]) row.appendChild(webButton(label, () => {
        if (listeningUI.page === 'queue') listeningQueue.move(entry.id, delta);
        else { const index = list.entries.findIndex(e => e.id === entry.id), target = Math.max(0, Math.min(list.entries.length - 1, index + delta)); list.entries.splice(target, 0, list.entries.splice(index, 1)[0]); }
        persistWebListening(); renderListeningUI();
      }, listeningUI.page === 'lists' && readonly || delta < 0 && absoluteIndex === 0 || delta > 0 && absoluteIndex === rows.length - 1, 'entry-action'));
      if (listeningUI.page === 'lists') {
        row.appendChild(webButton('↗', () => enqueueWebEntry(entry), false, 'entry-action'));
        if (list.kind === 'regular') {
          row.appendChild(webButton('#', () => { listeningUI.editingEntryID = entry.id; $('entry-subtune').max = metadata?.subtunesCount || 1; $('entry-subtune').value = (entry.subtune ?? 0) + 1; $('entry-subtune-dialog').showModal(); }, readonly, 'entry-action'));
          row.appendChild(webButton('All', () => { entry.subtune = null; persistWebListening(); renderListeningUI(); }, readonly, 'entry-action'));
        }
      }
      row.appendChild(webButton('×', () => {
        if (listeningUI.page === 'queue') listeningQueue.remove(entry.id); else list.entries = list.entries.filter(e => e.id !== entry.id);
        persistWebListening(); renderListeningUI();
      }, listeningUI.page === 'queue' ? listeningQueue.currentID === entry.id : readonly, 'entry-action'));
    }
    trackListContainer.appendChild(row);
  }
  if (!rows.length) { const empty = document.createElement('p'); empty.className = 'track-row empty'; empty.textContent = listeningUI.page === 'library' ? 'Load SID files or a folder to begin.' : 'No entries yet.'; trackListContainer.appendChild(empty); }
  $('entries-page').textContent = rows.length ? `${listeningUI.offset + 1}–${Math.min(rows.length, listeningUI.offset + listeningUI.pageSize)} / ${rows.length}` : '0 entries';
  $('entries-previous').disabled = listeningUI.offset === 0; $('entries-next').disabled = listeningUI.offset + listeningUI.pageSize >= rows.length;
  renderWebStorageStatus();
}
