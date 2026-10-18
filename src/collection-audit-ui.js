let webAuditImportIssues = [];
const auditUI = { controller: null, report: null, selected: new Set(), page: 0, applying: false };
const auditLabels = { damaged: 'Damaged or unreadable', unsupported: 'Unsupported', duplicate: 'Identical contents',
  missingSTIL: 'No STIL association', missingLength: 'Unknown duration', missing: 'Unavailable reference', moved: 'Found again',
  ambiguous: 'Ambiguous association', changed: 'Changed contents', unverified: 'Unknown identity' };
function initializeAuditUI() {
  $('audit-open').addEventListener('click', () => { showWebDialog($('audit-dialog'), { fallbackID: 'audit-open' }); renderAuditUI(); });
  $('audit-close').addEventListener('click', () => $('audit-dialog').close());
  $('audit-dialog').addEventListener('cancel', event => { if (auditUI.applying) event.preventDefault(); });
  $('audit-dialog').addEventListener('close', () => { auditUI.controller?.abort(); auditUI.controller = null; });
  $('audit-cancel').addEventListener('click', () => auditUI.controller?.abort());
  $('audit-start').addEventListener('click', startWebAudit);
  $('audit-filter').addEventListener('change', () => { auditUI.page = 0; renderAuditUI(); });
  $('audit-previous').addEventListener('click', () => { auditUI.page = Math.max(0, auditUI.page - 1); renderAuditUI(); });
  $('audit-next').addEventListener('click', () => { auditUI.page++; renderAuditUI(); });
  $('audit-apply').addEventListener('click', applyWebAudit);
  $('audit-export').addEventListener('click', () => {
    if (!auditUI.report) return;
    const { tracks, baseline, ...report } = auditUI.report;
    downloadCollection(JSON.stringify(report, null, 2), 'Collection-check.vicious-audit.json');
  });
}
async function startWebAudit() {
  if (auditUI.controller || auditUI.applying || webCollectionBusy) return;
  const controller = new AbortController(); auditUI.controller = controller; auditUI.report = null;
  auditUI.selected.clear(); auditUI.page = 0; $('audit-status').textContent = 'Checking selected files…'; renderAuditUI();
  try {
    const documents = [webListeningStore, webHistoryStore].map(store => collectionClone(store.document));
    const report = await auditWebCollection(documents, [...trackList], { signal: controller.signal, importIssues: webAuditImportIssues,
      progress: (count, total) => { $('audit-progress').max = Math.max(1, total); $('audit-progress').value = count;
        $('audit-status').textContent = `Checked ${count} of ${total} selected files`; } });
    if (auditUI.controller !== controller || controller.signal.aborted || !$('audit-dialog').open) return;
    auditUI.report = report;
    $('audit-status').textContent = `${report.fileCount} files checked, ${report.validCount} readable SID files, ${report.issues.length} findings.`;
  } catch (error) {
    if (auditUI.controller === controller && $('audit-dialog').open) $('audit-status').textContent = error.name === 'AbortError'
      ? 'Check cancelled. Personal data and music files are unchanged.' : error.message;
  } finally { if (auditUI.controller === controller) auditUI.controller = null; renderAuditUI(); }
}
function renderAuditUI() {
  const running = !!auditUI.controller || auditUI.applying, report = auditUI.report;
  $('audit-start').disabled = running || webCollectionBusy; $('audit-cancel').hidden = !auditUI.controller;
  $('audit-progress').hidden = !auditUI.controller; $('audit-close').disabled = auditUI.applying;
  $('audit-export').disabled = running || !report;
  $('audit-apply').disabled = running || webCollectionBusy || webPersonalStorage.readOnly || !auditUI.selected.size;
  $('audit-selection').textContent = `${auditUI.selected.size} associations selected. Only personal references are updated; the active queue keeps its order and position.`;
  const values = (report?.issues || []).filter(issue => !$('audit-filter').value || issue.kind === $('audit-filter').value);
  auditUI.page = Math.min(auditUI.page, Math.floor(Math.max(0, values.length - 1) / 20));
  const offset = auditUI.page * 20, rows = $('audit-rows'); rows.replaceChildren();
  for (const issue of values.slice(offset, offset + 20)) {
    const row = document.createElement('section'); row.className = 'collection-row';
    const title = document.createElement('h4'); title.textContent = auditLabels[issue.kind] || issue.kind; row.append(title);
    for (const path of issue.paths.slice(0, 3)) { const text = document.createElement('p'); text.textContent = path; row.append(text); }
    const detail = document.createElement('small'); detail.textContent = issue.detail + (issue.reference?.subtune != null ? ` · Subtune ${issue.reference.subtune + 1}` : '')
      + (issue.paths.length > 3 ? ` · ${issue.paths.length - 3} further paths in the saved report` : ''); row.append(detail);
    if (issue.canRepair) {
      const label = document.createElement('label'), input = document.createElement('input'); input.type = 'checkbox';
      input.checked = auditUI.selected.has(issue.id); input.disabled = running;
      input.addEventListener('change', () => { if (input.checked) auditUI.selected.add(issue.id); else auditUI.selected.delete(issue.id); renderAuditUI(); });
      label.append(input, document.createTextNode('Use this association')); row.append(label);
    }
    rows.append(row);
  }
  if (report && !values.length) rows.textContent = 'No findings in this selection.';
  $('audit-page').textContent = `${values.length ? offset + 1 : 0}–${Math.min(offset + 20, values.length)} / ${values.length}`;
  $('audit-previous').disabled = running || !offset; $('audit-next').disabled = running || offset + 20 >= values.length;
}
async function applyWebAudit() {
  if (!auditUI.report || !auditUI.selected.size || auditUI.controller || auditUI.applying || webCollectionBusy || webPersonalStorage.readOnly) return;
  const shown = auditUI.report, selected = new Set(auditUI.selected); auditUI.applying = true; renderAuditUI();
  let wasPlaying = false, paused = false;
  try {
    await fileImportQueue; observeWebHistory(false, true); await persistWebListening(); await saveWebHistory();
    webCollectionBusy = true; $('player').inert = true;
    const before = [webListeningStore, webHistoryStore].map(store => collectionClone(store.document));
    const verified = await auditWebCollection(before, [...trackList]);
    if (!collectionEqual(verified.tracks, shown.tracks)) throw new Error('The selected music changed. Run the collection check again.');
    const result = repairWebAudit(before, shown, selected);
    if (collectionEqual(before, result)) throw new Error('No unchanged personal references remain. Run the collection check again.');
    wasPlaying = playingState; if (wasPlaying) player.pause(); setPlayingUI(false); paused = true;
    await webPersonalStorage.apply(result, [...webPersonalStorage.saved], before);
    webHistoryRecorder.reset(); lastHistoryObservation = -1;
    auditUI.report = null; auditUI.selected.clear();
    $('audit-status').textContent = 'Selected personal references updated. Music files are unchanged.';
  } catch (error) { $('audit-status').textContent = webPersonalStorage.readOnly ? webPersonalStorage.error : error.message; }
  finally {
    if (paused && wasPlaying) {
      try { await player.play(WORKLET_URL); setPlayingUI(player.playing); }
      catch (error) { setPlayingUI(false); $('audit-status').textContent += ` Playback could not resume: ${error.message}`; }
    }
    webCollectionBusy = false; auditUI.applying = false; $('player').inert = false; renderListeningUI(); renderAuditUI();
  }
}
