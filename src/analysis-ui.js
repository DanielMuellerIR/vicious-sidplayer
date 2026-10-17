const webAnalysisMix = new WebAnalysisMix();
let webAnalysisChip = 0;
function activeWebSIDChips() { return currentMetadata?.activeSIDChips || [0]; }
function initializeWebAnalysisUI() {
  $('analysis-open').addEventListener('click', () => { renderWebAnalysisUI(); $('analysis-dialog').showModal(); });
  $('analysis-close').addEventListener('click', () => $('analysis-dialog').close());
  $('scope-chip').addEventListener('change', () => { webAnalysisChip = Number($('scope-chip').value); phases.fill(0); renderWebAnalysisUI(); });
  $('analysis-clear-solo').addEventListener('click', () => { webAnalysisMix.clearSolos(); applyWebAnalysisMix(); });
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
