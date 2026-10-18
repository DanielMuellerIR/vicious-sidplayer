let webPersonalStorage = null, webCollectionBusy = false;
const collectionUI = { generation: 0, document: null, raw: null, mode: 'import', offset: 0,
  areas: new Set(collectionAreas.filter(a => a !== 'history')), choices: new Map(), acceptedPaths: new Set(), preview: null, applying: false };
const collectionAreaLabels = { favorites: 'File favorites', lists: 'Lists and favorite subtunes', bookmarks: 'Bookmarks',
  notes: 'File and subtune notes', history: 'Listening history and heard status' };
function webCollectionTracks(verify = false) {
  const loaded = new Map(trackList.map(t => [t.id, t]));
  return webListeningStore.document.catalog.filter(t => collectionPathValid(t.path) && loaded.has(t.id)).map(t => {
    const track = loaded.get(t.id);
    return { ...t, md5: track ? verify ? collectionMD5(track.buffer) : t.md5 : null, unavailable: !track };
  });
}
function initializeCollectionUI() {
  $('collection-open').addEventListener('click', () => {
    collectionUI.generation++; collectionUI.document = null; collectionUI.raw = null; collectionUI.preview = null;
    collectionUI.mode = 'import'; collectionUI.offset = 0;
    collectionUI.areas = new Set(collectionAreas.filter(a => a !== 'history'));
    collectionUI.choices.clear(); collectionUI.acceptedPaths.clear();
    $('collection-file').value = ''; $('collection-skip').checked = false; $('collection-export-ack').checked = false;
    $('collection-error').textContent = ''; renderCollectionUI(); showWebDialog($('collection-dialog'), { fallbackID: 'collection-open' });
  });
  $('collection-close').addEventListener('click', () => $('collection-dialog').close());
  $('collection-dialog').addEventListener('cancel', event => { if (webCollectionBusy || collectionUI.applying) event.preventDefault(); });
  $('collection-dialog').addEventListener('close', () => {
    if ($('collection-dialog').open) return;
    collectionUI.generation++; collectionUI.document = null; collectionUI.raw = null; collectionUI.preview = null;
  });
  $('collection-mode').addEventListener('change', () => {
    collectionUI.mode = $('collection-mode').value; collectionUI.offset = 0; collectionUI.preview = null;
    $('collection-error').textContent = ''; renderCollectionUI();
  });
  $('collection-file').addEventListener('change', async event => {
    const file = event.target.files?.[0], generation = ++collectionUI.generation;
    collectionUI.document = null; collectionUI.raw = null; collectionUI.preview = null;
    collectionUI.choices.clear(); collectionUI.acceptedPaths.clear(); $('collection-skip').checked = false;
    $('collection-error').textContent = ''; renderCollectionUI();
    if (!file) return;
    try {
      if (file.size > collectionMaximumBytes) throw new Error('Collection files are limited to 32 MiB.');
      const raw = collectionUTF8(new Uint8Array(await file.arrayBuffer())), document = decodeCollectionDocument(raw);
      if (generation !== collectionUI.generation || !$('collection-dialog').open) return;
      collectionUI.document = document; collectionUI.raw = raw; collectionUI.offset = 0;
      refreshCollectionPreview();
    } catch (error) { if (generation === collectionUI.generation) $('collection-error').textContent = error.message; }
    renderCollectionUI();
  });
  $('collection-refresh').addEventListener('click', () => {
    collectionUI.choices.clear(); collectionUI.acceptedPaths.clear(); $('collection-skip').checked = false;
    refreshCollectionPreview(); renderCollectionUI();
  });
  $('collection-previous').addEventListener('click', () => { collectionUI.offset = Math.max(0, collectionUI.offset - 20); renderCollectionRows(); });
  $('collection-next').addEventListener('click', () => { collectionUI.offset += 20; renderCollectionRows(); });
  $('collection-skip').addEventListener('change', updateCollectionApplyButton);
  $('collection-export-ack').addEventListener('change', updateCollectionApplyButton);
  $('collection-apply').addEventListener('click', applyCollectionImport);
  $('collection-export').addEventListener('click', () => {
    try {
      const exported = makeCollectionExport();
      if ((exported.omittedLegacy || exported.unverified) && !$('collection-export-ack').checked) return;
      downloadCollection(encodeCollectionDocument(exported.document), 'Personal-collection.vicious-collection.json');
      $('collection-error').textContent = 'Export download prepared. Your browser controls where it is saved.';
    } catch (error) { $('collection-error').textContent = error.message; }
  });
  $('collection-original').addEventListener('click', () => {
    if (collectionUI.raw != null) downloadCollection(collectionUI.raw, 'Original.vicious-collection.json');
  });
}
function downloadCollection(raw, name) {
  const url = URL.createObjectURL(new Blob([raw], { type: 'application/json' })), anchor = document.createElement('a');
  anchor.href = url; anchor.download = name; anchor.click(); setTimeout(() => URL.revokeObjectURL(url), 30000);
}
function refreshCollectionPreview() {
  collectionUI.preview = null;
  if (!collectionUI.document || webPersonalStorage.readOnly) return;
  try {
    const source = [webListeningStore, webHistoryStore].map(store => collectionClone(store.document)), tracks = webCollectionTracks();
    const result = mergeWebCollection(collectionUI.document, source, tracks, collectionUI);
    collectionUI.preview = { source, result, tracks: collectionClone(tracks) };
  } catch (error) { $('collection-error').textContent = error.message; }
}
function makeCollectionExport() {
  const listening = collectionClone(webListeningStore.document), history = collectionClone(webHistoryStore.document);
  for (const area of ['favorites', 'lists']) if (!collectionUI.areas.has(area)) listening[area] = [];
  for (const area of ['bookmarks', 'notes']) if (!collectionUI.areas.has(area)) history[area] = [];
  const exported = exportWebCollection(listening, history, webCollectionTracks(), collectionUI.areas.has('history'));
  for (const area of collectionAreas) if (!collectionUI.areas.has(area)) {
    if (area === 'history') delete exported.document.history; else exported.document[area] = [];
  }
  return exported;
}
function updateCollectionApplyButton() {
  const preview = collectionUI.preview?.result;
  $('collection-apply').disabled = webCollectionBusy || collectionUI.applying || webPersonalStorage.readOnly || !collectionSegmenter || !preview?.hasChanges
    || preview.skippedPathEntries > 0 && !$('collection-skip').checked;
  $('collection-export').disabled = webCollectionBusy || webPersonalStorage.readOnly || !collectionSegmenter
    || !$('collection-export-ack-row').hidden && !$('collection-export-ack').checked;
}
function renderCollectionUI() {
  const importing = collectionUI.mode === 'import', document = collectionUI.document;
  $('collection-mode').value = collectionUI.mode;
  $('collection-import-controls').hidden = !importing; $('collection-export-controls').hidden = importing;
  $('collection-preview').hidden = !importing || !document;
  $('collection-protection').textContent = webPersonalStorage.error || (!collectionSegmenter ? 'This browser cannot validate portable Unicode text. Collection exchange is unavailable.' : '');
  const container = $('collection-areas'); container.replaceChildren();
  const legend = window.document.createElement('legend'); legend.textContent = 'Included data'; container.append(legend);
  for (const area of collectionAreas) {
    const label = window.document.createElement('label'), input = window.document.createElement('input');
    input.type = 'checkbox'; input.checked = collectionUI.areas.has(area); input.dataset.area = area;
    input.disabled = webCollectionBusy || collectionUI.applying || webPersonalStorage.readOnly || importing && area === 'history' && !document?.history;
    input.addEventListener('change', () => {
      if (input.checked) collectionUI.areas.add(area); else collectionUI.areas.delete(area);
      $('collection-skip').checked = false; $('collection-export-ack').checked = false;
      refreshCollectionPreview(); renderCollectionUI();
    });
    const count = !document ? '' : ` (${area === 'history' ? (document.history?.events.length || 0) + (document.history?.heardMD5s.length || 0) : document[area].length})`;
    label.append(input, window.document.createTextNode(collectionAreaLabels[area] + (importing ? count : ''))); container.append(label);
  }
  $('collection-file').disabled = webCollectionBusy || collectionUI.applying;
  $('collection-close').disabled = webCollectionBusy || collectionUI.applying; $('collection-mode').disabled = webCollectionBusy || collectionUI.applying;
  $('collection-refresh').disabled = webCollectionBusy || collectionUI.applying || webPersonalStorage.readOnly;
  $('collection-original').hidden = !document; $('collection-original').disabled = webCollectionBusy;
  $('collection-unsupported').textContent = 'Personal end times are not supported by the web player and are excluded. The original collection file is unchanged.'
    + (document ? ` This file contains ${document.endTimes.length} end time(s).` : '');
  const result = collectionUI.preview?.result;
  $('collection-summary').textContent = result ? `${result.additions} additions · ${result.updates} updates · ${result.duplicates} unchanged · ${result.heardAddedCount} new heard marks` : '';
  $('collection-skip-row').hidden = !result?.skippedPathEntries;
  $('collection-skip-label').textContent = `Import while skipping ${result?.skippedPathEntries || 0} unresolved favorite/list entries. Missing bookmarks and notes are kept.`;
  $('collection-export-ack-row').hidden = true;
  if (!importing && !webPersonalStorage.readOnly) {
    try {
      const exported = makeCollectionExport();
      $('collection-export-report').textContent = `${exported.omittedLegacy} legacy references or heard marks cannot be exported without verified music. ${exported.unverified} favorites/list entries have no verified MD5. Unresolved legacy data stays in this browser. Select its music files again to verify the content.`;
      $('collection-export-ack-row').hidden = !exported.omittedLegacy && !exported.unverified;
    } catch (error) { $('collection-error').textContent = error.message; $('collection-export-ack-row').hidden = false; }
  }
  renderCollectionRows(); updateCollectionApplyButton();
}
function renderCollectionRows() {
  const result = collectionUI.preview?.result, container = $('collection-rows'); container.replaceChildren();
  const rows = [...(result?.conflicts || []).map(value => ({ kind: 'conflict', value })), ...(result?.unresolved || []).map(value => ({ kind: 'unresolved', value }))];
  collectionUI.offset = Math.min(collectionUI.offset, Math.max(0, Math.floor((rows.length - 1) / 20) * 20));
  for (const row of rows.slice(collectionUI.offset, collectionUI.offset + 20)) {
    const section = document.createElement('section'); section.className = 'collection-row';
    const title = document.createElement('strong'); section.append(title);
    if (row.kind === 'conflict') {
      const conflict = row.value; title.textContent = conflict.label;
      const details = document.createElement('details'), summary = document.createElement('summary');
      summary.textContent = 'Read existing and imported values'; details.append(summary);
      for (const [label, value] of [['Existing', conflict.existingValue], ['Imported', conflict.importedValue]]) {
        const heading = document.createElement('h4'), text = document.createElement('pre'); heading.textContent = label; text.textContent = value; details.append(heading, text);
      }
      section.append(details);
      const select = document.createElement('select'); select.setAttribute('aria-label', `Conflict choice: ${conflict.label}`);
      for (const [value, label] of [['keepExisting', 'Keep existing'], ['useImported', 'Use imported']]) {
        const option = document.createElement('option'); option.value = value; option.textContent = label; option.disabled = value === 'useImported' && !conflict.allowed; select.append(option);
      }
      select.value = collectionUI.choices.get(conflict.id) || 'keepExisting';
      select.addEventListener('change', () => { collectionUI.choices.set(conflict.id, select.value); refreshCollectionPreview(); renderCollectionUI(); }); section.append(select);
      if (!conflict.allowed) { const reason = document.createElement('p'); reason.textContent = 'This ID belongs to a different list kind. The existing list is kept.'; section.append(reason); }
    } else {
      const { reference, resolution } = row.value; title.textContent = `${reference.path}${reference.subtune == null ? '' : ` · subtune ${reference.subtune + 1}`}`;
      const explanation = document.createElement('p'); explanation.textContent = {
        missing: 'File not selected. Personal MD5 data stays available.', changed: 'The selected file has different content.',
        ambiguous: 'Several selected files have this content.', unavailable: 'Select this file again before using it.',
        unavailableSubtune: 'This subtune does not exist in the selected file.', unverified: 'The archive has no matching content proof. Accept this path only if it is the intended file.'
      }[resolution.kind]; section.append(explanation);
      if (resolution.kind === 'unverified') {
        const label = document.createElement('label'), input = document.createElement('input'), key = collectionReferenceKey(reference);
        input.type = 'checkbox'; input.checked = collectionUI.acceptedPaths.has(key);
        input.addEventListener('change', () => {
          if (input.checked) collectionUI.acceptedPaths.add(key); else collectionUI.acceptedPaths.delete(key);
          $('collection-skip').checked = false; refreshCollectionPreview(); renderCollectionUI();
        }); label.append(input, document.createTextNode('Accept this unverified path')); section.append(label);
      }
    }
    container.append(section);
  }
  $('collection-page').textContent = rows.length ? `${collectionUI.offset + 1}–${Math.min(collectionUI.offset + 20, rows.length)} of ${rows.length}` : 'No conflicts or unresolved references';
  $('collection-previous').disabled = !collectionUI.offset || webCollectionBusy;
  $('collection-next').disabled = collectionUI.offset + 20 >= rows.length || webCollectionBusy;
}
async function applyCollectionImport() {
  if ($('collection-apply').disabled || !collectionUI.preview) return;
  const generation = collectionUI.generation, shown = collectionUI.preview;
  let paused = false, wasPlaying = false;
  collectionUI.applying = true; renderCollectionUI();
  try {
    await fileImportQueue;
    if (generation !== collectionUI.generation || !$('collection-dialog').open) return;
    observeWebHistory(false, true); await persistWebListening(); await saveWebHistory();
    if (generation !== collectionUI.generation || !$('collection-dialog').open) return;
    webCollectionBusy = true; $('player').inert = true; renderCollectionUI();
    const tracks = webCollectionTracks(true);
    if (!collectionEqual(tracks, shown.tracks)) throw new Error('The selected music changed. Refresh the preview before importing.');
    const before = [webListeningStore, webHistoryStore].map(store => collectionClone(store.document));
    const result = mergeWebCollection(collectionUI.document, before, tracks, collectionUI);
    if (!collectionEqual(result.conflicts, shown.result.conflicts) || !collectionEqual(result.unresolved, shown.result.unresolved)
      || result.skippedPathEntries !== shown.result.skippedPathEntries) throw new Error('Personal data changed. Refresh the preview and check the conflicts again.');
    // Auch ein noch laufender Audioaufbau darf nach der Übernahme nicht mit
    // einem alten Play-Auftrag gewinnen. Vorbereitete Titel bleiben vorbereitet.
    wasPlaying = playingState; ++playbackGeneration;
    player.stop(); setPlayingUI(false); paused = true;
    await webPersonalStorage.apply(result.documents, [...webPersonalStorage.saved], before);
    webHistoryRecorder.reset(); lastHistoryObservation = -1;
    collectionUI.preview = null;
    $('collection-error').textContent = `Import complete: ${result.additions} additions, ${result.updates} updates. The active queue and playback position are preserved.`;
  } catch (error) {
    $('collection-error').textContent = webPersonalStorage.readOnly ? webPersonalStorage.error
      : error.name === 'QuotaExceededError' ? 'The browser has insufficient storage for a safe import. Existing data is preserved.'
        : error.message || String(error);
  }
  finally {
    if (paused && wasPlaying) {
      try { await player.play(WORKLET_URL); setPlayingUI(player.playing); }
      catch (error) { setPlayingUI(false); $('collection-error').textContent += ` Playback could not resume: ${error.message}`; }
    }
    webCollectionBusy = false; collectionUI.applying = false; $('player').inert = false; renderListeningUI(); renderCollectionUI();
  }
}
