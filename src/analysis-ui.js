const webAnalysisMix = new WebAnalysisMix();
let webAnalysisChip = 0;
function activeWebSIDChips() { return currentMetadata?.activeSIDChips || [0]; }
function initializeWebAnalysisUI() {
  $('analysis-open').addEventListener('click', () => { renderWebAnalysisUI(); $('analysis-dialog').showModal(); });
  $('analysis-close').addEventListener('click', () => $('analysis-dialog').close());
  $('scope-chip').addEventListener('change', () => { webAnalysisChip = Number($('scope-chip').value); phases.fill(0); renderWebAnalysisUI(); renderWebAnalysisValues(true); });
  $('analysis-clear-solo').addEventListener('click', () => { webAnalysisMix.clearSolos(); applyWebAnalysisMix(); });
  $('analysis-view').addEventListener('change', () => { renderWebAnalysisValues(true); resizeCanvas(); });
  $('loop-a').addEventListener('click', () => { webPlaybackLoop.setStart(lastVisuals.playtime, Math.min(1200, SCRUB_MAX)); applyWebLoop(); });
  $('loop-b').addEventListener('click', () => { webPlaybackLoop.setEnd(lastVisuals.playtime, SCRUB_MAX); applyWebLoop(); });
  $('loop-enabled').addEventListener('change', () => { webPlaybackLoop.setEnabled($('loop-enabled').checked); applyWebLoop(); });
  $('loop-clear').addEventListener('click', clearWebLoopMarkers);
  player.loopStateCallback = status => {
    webLoopStatus = status;
    if ((status === 'off' || status === 'error') && !player.loopRange) webPlaybackLoop.setEnabled(false);
    renderWebLoop();
  };
  renderWebLoop();
  applyWebAnalysisMix();
}
function applyWebAnalysisMix() {
  player.setMutedChannels(webAnalysisMix.effectiveMuted(activeWebSIDChips()));
  renderWebAnalysisUI();
}
function renderWebAnalysisUI() {
  const chips = activeWebSIDChips();
  if (!chips.includes(webAnalysisChip)) webAnalysisChip = chips[0];
  const picker = $('scope-chip'); picker.replaceChildren();
  for (const chip of chips) {
    const option = document.createElement('option'); option.value = String(chip); option.textContent = `SID ${chip + 1}`; picker.append(option);
  }
  picker.value = String(webAnalysisChip); $('scope-chip-label').hidden = chips.length === 1;
  const model = currentMetadata?.chipModels?.[webAnalysisChip];
  $('scope-model').textContent = `SID ${webAnalysisChip + 1}${model ? ' · ' + model : ''}`;
  const container = $('analysis-groups'); container.replaceChildren();
  for (const chip of chips) {
    const section = document.createElement('section'); section.className = 'analysis-chip';
    const header = document.createElement('div'); header.className = 'analysis-chip-header';
    const title = document.createElement('strong'); title.textContent = `SID ${chip + 1}${currentMetadata?.chipModels?.[chip] ? ' · ' + currentMetadata.chipModels[chip] : ''}`;
    const chipMute = webButton('Mute chip', () => { webAnalysisMix.toggleChipMuted(chip); applyWebAnalysisMix(); }, webCollectionBusy);
    chipMute.setAttribute('aria-label', `SID ${chip + 1} mute chip`); chipMute.setAttribute('aria-pressed', String(webAnalysisMix.chipMuted[chip]));
    header.append(title, chipMute); section.append(header);
    const voices = document.createElement('div'); voices.className = 'analysis-voices';
    for (let voice = 0; voice < 3; voice++) {
      const channel = chip * 3 + voice, column = document.createElement('div'); column.className = 'analysis-voice';
      const label = document.createElement('strong'); label.textContent = `V${voice + 1}`;
      const mute = webButton('Mute', () => { webAnalysisMix.toggleChannelMuted(channel); applyWebAnalysisMix(); }, webCollectionBusy);
      const solo = webButton('Solo', () => { webAnalysisMix.toggleSolo(channel); applyWebAnalysisMix(); }, webCollectionBusy);
      mute.setAttribute('aria-label', `SID ${chip + 1} voice ${voice + 1} mute`); mute.setAttribute('aria-pressed', String(webAnalysisMix.channelMuted[channel]));
      solo.setAttribute('aria-label', `SID ${chip + 1} voice ${voice + 1} solo`); solo.setAttribute('aria-pressed', String(webAnalysisMix.soloChannels.has(channel)));
      const actions = document.createElement('div'); actions.className = 'analysis-voice-actions'; actions.append(mute, solo);
      column.append(label, actions); voices.append(column);
    }
    section.append(voices); container.append(section);
  }
  $('analysis-clear-solo').disabled = webAnalysisMix.soloChannels.size === 0;
  $('analysis-open').textContent = webAnalysisMix.soloChannels.size ? 'Mix / Solo •' : 'Mix / Solo';
  resizeCanvas();
}

const webPlaybackLoop = new WebPlaybackLoop();
let webLoopStatus = 'off';
function applyWebLoop() {
  player.setLoopRange(webPlaybackLoop.enabled ? webPlaybackLoop.range : null, LOOP_WORKER_SOURCE);
  renderWebLoop();
}
function renderWebLoop() {
  const time = value => value == null ? '—' : value.toFixed(2) + ' s';
  $('loop-markers').textContent = `A ${time(webPlaybackLoop.start)} · B ${time(webPlaybackLoop.end)}`;
  $('loop-b').disabled = webPlaybackLoop.start == null || webCollectionBusy;
  $('loop-a').disabled = !player.loaded || webCollectionBusy;
  $('loop-enabled').disabled = !webPlaybackLoop.range || webCollectionBusy;
  $('loop-enabled').checked = webPlaybackLoop.enabled;
  $('loop-status').textContent = ({ preparing: 'Preparing loop…', waiting: 'Loop starts with playback.', ready: 'A/B loop active', error: 'Could not prepare loop.' })[webLoopStatus] || 'Minimum interval: 0.25 s. A seek outside A/B turns the loop off.';
}
function clearWebLoopMarkers() { webPlaybackLoop.clear(); applyWebLoop(); }
let webAnalysisLastPaint = -Infinity;
function renderWebAnalysisValues(force = false) {
  const now = performance.now();
  if (!force && now - webAnalysisLastPaint < 100) return;
  webAnalysisLastPaint = now;
  const mode = $('analysis-view').value;
  $('scope-canvas').hidden = mode !== 'scope';
  $('analysis-values').hidden = mode === 'scope';
  if (mode === 'scope') return;
  const target = $('analysis-values'); target.replaceChildren();
  const visuals = lastVisuals.chips?.[webAnalysisChip] || lastVisuals;
  const base = visuals.baseAddress || 0xd400;
  const heading = document.createElement('div'); heading.className = 'analysis-value-heading';
  heading.textContent = `SID ${webAnalysisChip + 1} · $${base.toString(16).toUpperCase()} · ${currentMetadata?.chipModels?.[webAnalysisChip] || '—'} · ${(lastVisuals.clock || 'pal').toUpperCase()}`;
  target.append(heading);
  if (mode === 'piano') {
    for (let voice = 0; voice < 3; voice++) {
      const pitch = sidPitch(visuals.frequencies?.[voice], lastVisuals.clock, visuals.waveforms?.[voice], visuals.envelopes?.[voice]);
      const row = document.createElement('div'); row.className = 'pitch-row';
      const muted = webAnalysisMix.effectiveMuted(activeWebSIDChips())[webAnalysisChip * 3 + voice];
      if (muted) row.classList.add('muted');
      const label = document.createElement('div'); label.textContent = `V${voice + 1} · ${pitch ? pitch.name + ' · ' + pitch.hertz.toFixed(1) + ' Hz · ' + pitch.cents.toFixed(0) + ' ct' : '— · ' + ((visuals.frequencies?.[voice] || 0) * (lastVisuals.clock === 'ntsc' ? 1022727 : 985248) / 16777216).toFixed(1) + ' Hz'} · G${visuals.gates?.[voice] || 0} · ${Math.round((visuals.envelopes?.[voice] || 0) * 100)}%`;
      const keys = document.createElement('div'); keys.className = 'piano-keys'; keys.setAttribute('aria-hidden', 'true');
      for (let key = 0; key < 12; key++) {
        const element = document.createElement('span');
        if ([1, 3, 6, 8, 10].includes(key)) element.classList.add('black-key');
        if (pitch?.midiNote % 12 === key) element.classList.add('active-key');
        keys.append(element);
      }
      row.append(label, keys); target.append(row);
    }
  } else {
    const table = document.createElement('table'); table.className = 'register-values';
    for (const offset of [...Array(25).keys(), 27, 28]) {
      const row = document.createElement('tr');
      for (const value of ['$' + (base + offset).toString(16).toUpperCase().padStart(4, '0'), sidRegisterLabel(offset),
        (visuals.registers?.[offset] || 0).toString(16).toUpperCase().padStart(2, '0')]) {
        const cell = document.createElement('td'); cell.textContent = value; row.append(cell);
      }
      table.append(row);
    }
    target.append(table);
  }
  const hint = document.createElement('p'); hint.className = 'analysis-hint';
  hint.textContent = mode === 'piano' ? 'Approximate register pitch, A4 = 440 Hz. Noise, combined waveforms and digi samples cannot be identified reliably.' : 'Written registers and emulated OSC3/ENV3 values. Read only.';
  target.append(hint);
}
