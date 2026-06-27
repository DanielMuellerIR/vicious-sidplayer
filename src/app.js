// ─────────────────────────────────────────────────────────────────────────────
// Standalone C64 SID Player UI Controller
//
// Wirbt die Web-Audio-Schnittstelle, Drag-and-Drop, Playlist-Verwaltung,
// Hüllkurven-Visualisierung und den Oszilloskop-Renderer.
// ─────────────────────────────────────────────────────────────────────────────

// Base64-decoding helper for inlined default tracks
function base64ToUint8(base64) {
  const binary = atob(base64);
  const len = binary.length;
  const bytes = new Uint8Array(len);
  for (let i = 0; i < len; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

// Format seconds as M:SS
function fmtTime(sec) {
  const s = Math.max(0, Math.floor(sec));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}

// SID waveform bitmasks
const WF_TRI = 0x10;
const WF_SAW = 0x20;
const WF_PULSE = 0x40;
const WF_NOISE = 0x80;

// Computes procedural waveform sample (-1..1) at phase frac (0..1)
function sidWaveSample(frac, wf, duty) {
  if (wf & WF_NOISE) return Math.random() * 2 - 1;
  if (wf & WF_PULSE) return frac < duty ? 1 : -1;
  if (wf & WF_SAW) return 2 * frac - 1;
  if (wf & WF_TRI) return frac < 0.5 ? 4 * frac - 1 : 3 - 4 * frac;
  return 0;
}

function wfName(wf) {
  if (wf & WF_NOISE) return 'NOI';
  if (wf & WF_PULSE) return 'PUL';
  if (wf & WF_SAW) return 'SAW';
  if (wf & WF_TRI) return 'TRI';
  return '---';
}

const SCRUB_MAX = 360; // 6 minutes limit

// ─── DOM References ─────────────────────────────────────────────────────────
const $ = (id) => document.getElementById(id);
const playerEl = $('player');
const trackSelect = $('track-select');
const fileInput = $('file-input');
const folderInput = $('folder-input');
const autoNextCheck = $('auto-next');
const subtuneControls = $('subtune-controls');
const subtuneLabel = $('subtune-label');
const prevSubtuneBtn = $('prev-subtune');
const nextSubtuneBtn = $('next-subtune');
const playBtn = $('play-btn');
const timeCurrent = $('time-current');
const positionScrubber = $('position-scrubber');
const timeTotal = $('time-total');
const volumeSlider = $('volume-slider');
const trackListContainer = $('track-list');
const metaTitle = $('meta-title');
const metaAuthor = $('meta-author');
const metaInfo = $('meta-info');
const errorDisplay = $('error-display');
const themeBtn = $('theme-btn');
const footerState = $('footer-state');
const canvas = $('oscilloscope');
const folderLabel = $('folder-label');

// ─── Setup folder picker directory attributes ────────────────────────────────
if (folderInput) {
  folderInput.setAttribute('webkitdirectory', '');
  folderInput.setAttribute('directory', '');
}

// ─── Player State ───────────────────────────────────────────────────────────
const player = new SidPlayer();
let trackList = []; // Array of { id, name, composer, year, isUser, buffer, base64Key }
let currentIdx = -1;
let currentSubtune = 0;
let totalSubtunesCount = 1;
let currentMetadata = null;
let playingState = false;
let userVolume = 0.3;

// Scrubber seeking state
let isSeeking = false;
let seekTimer = null;

// Oscilloscope visualizer state
let phases = [0, 0, 0];
let traceColors = ['#00f0ff', '#a3e635', '#ec4899'];
const lastVisuals = {
  envelopes: [0, 0, 0],
  frequencies: [0, 0, 0],
  gates: [0, 0, 0],
  waveforms: [0, 0, 0],
  pulsewidths: [0.5, 0.5, 0.5],
  playtime: 0
};

// No built-in tracks — all SIDs come from user via drag & drop or file picker
trackList = [];
refreshPlaylistUI();

// ─── Event Listeners ────────────────────────────────────────────────────────
fileInput.addEventListener('change', (e) => {
  player.resumeContext();
  const files = Array.from(e.target.files || []);
  if (files.length) {
    addUserFiles(files, true);
  }
  e.target.value = '';
});

folderInput.addEventListener('change', (e) => {
  player.resumeContext();
  const files = Array.from(e.target.files || []);
  if (files.length) {
    addUserFiles(files, true);
  }
  e.target.value = '';
});

trackSelect.addEventListener('change', (e) => {
  const val = e.target.value;
  if (val !== '') {
    loadTrack(Number(val), true);
  }
});

volumeSlider.addEventListener('input', (e) => {
  userVolume = Number(e.target.value);
  player.setVolume(userVolume);
});

playBtn.addEventListener('click', async () => {
  if (currentIdx === -1) return;
  if (playingState) {
    player.stop();
    setPlayingUI(false);
  } else {
    try {
      player.resumeContext();
      setPlayingUI(true);
      await player.play(WORKLET_BLOB_URL);
    } catch (err) {
      showError(err.message || String(err));
      setPlayingUI(false);
    }
  }
});

positionScrubber.addEventListener('input', (e) => {
  isSeeking = true;
  const target = Number(e.target.value);
  timeCurrent.textContent = fmtTime(target);
  
  if (seekTimer) clearTimeout(seekTimer);
  seekTimer = setTimeout(() => {
    player.seek(target);
    lastVisuals.playtime = target;
    isSeeking = false;
    seekTimer = null;
  }, 120);
});

prevSubtuneBtn.addEventListener('click', () => {
  if (totalSubtunesCount <= 1) return;
  const prev = (currentSubtune - 1 + totalSubtunesCount) % totalSubtunesCount;
  setSubtune(prev);
});

nextSubtuneBtn.addEventListener('click', () => {
  if (totalSubtunesCount <= 1) return;
  const next = (currentSubtune + 1) % totalSubtunesCount;
  setSubtune(next);
});

// Keyboard Shortcuts
window.addEventListener('keydown', (e) => {
  if (document.activeElement && (
    document.activeElement.tagName === 'INPUT' && document.activeElement.type !== 'range' && document.activeElement.type !== 'checkbox' ||
    document.activeElement.tagName === 'SELECT')) {
    return;
  }

  const key = e.key.toLowerCase();

  // Space -> Play/Stop
  if (e.key === ' ' || e.key === 'Spacebar') {
    e.preventDefault();
    if (!playBtn.disabled) playBtn.click();
  }

  // M -> Mute/Unmute
  if (key === 'm') {
    e.preventDefault();
    if (volumeSlider.value > 0) {
      volumeSlider.dataset.prevVal = volumeSlider.value;
      volumeSlider.value = 0;
      player.setVolume(0);
    } else {
      const prevVal = volumeSlider.dataset.prevVal || 0.3;
      volumeSlider.value = prevVal;
      player.setVolume(Number(prevVal));
    }
  }

  // Left/Right -> seek 5s
  if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') {
    e.preventDefault();
    if (currentIdx === -1) return;
    const diff = e.key === 'ArrowLeft' ? -5 : 5;
    const pt = Math.max(0, Math.min(SCRUB_MAX, lastVisuals.playtime + diff));
    player.seek(pt);
    lastVisuals.playtime = pt;
    positionScrubber.value = pt;
    timeCurrent.textContent = fmtTime(pt);
  }

  // Up/Down -> change tracks
  if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
    e.preventDefault();
    if (trackList.length <= 1) return;
    const dir = e.key === 'ArrowUp' ? -1 : 1;
    const next = (currentIdx + dir + trackList.length) % trackList.length;
    loadTrack(next, true);
  }
});

// ─── Drag and Drop ──────────────────────────────────────────────────────────
let dragDepth = 0;
window.addEventListener('dragenter', (e) => {
  e.preventDefault();
  dragDepth++;
  playerEl.classList.add('drag-over');
});
window.addEventListener('dragover', (e) => {
  e.preventDefault();
  e.dataTransfer.dropEffect = 'copy';
});
window.addEventListener('dragleave', (e) => {
  e.preventDefault();
  dragDepth--;
  if (dragDepth <= 0) {
    dragDepth = 0;
    playerEl.classList.remove('drag-over');
  }
});
window.addEventListener('drop', async (e) => {
  e.preventDefault();
  dragDepth = 0;
  playerEl.classList.remove('drag-over');
  player.resumeContext();

  try {
    const files = await collectDroppedFiles(e.dataTransfer);
    const sids = files.filter(f => f.name.toLowerCase().endsWith('.sid'));
    if (!sids.length) {
      if (files.length) showError('No .sid files found in drop.');
      return;
    }
    addUserFiles(sids, true);
  } catch (err) {
    console.error('Drop error:', err);
    const files = Array.from(e.dataTransfer.files || []);
    if (files.length) {
      addUserFiles(files, true);
    }
  }
});

async function collectDroppedFiles(dt) {
  const out = [];
  const items = dt.items;
  if (items && items.length && typeof items[0].webkitGetAsEntry === 'function') {
    const entries = [];
    for (let i = 0; i < items.length; i++) {
      const entry = items[i].webkitGetAsEntry();
      if (entry) entries.push(entry);
    }
    for (const entry of entries) await walkEntry(entry, out);
    return out;
  }
  for (let i = 0; i < dt.files.length; i++) out.push(dt.files[i]);
  return out;
}

async function walkEntry(entry, out) {
  if (entry.isFile) {
    const file = await new Promise((res, rej) => entry.file(res, rej));
    out.push(file);
    return;
  }
  if (entry.isDirectory) {
    const reader = entry.createReader();
    while (true) {
      const batch = await new Promise((res, rej) => reader.readEntries(res, rej));
      if (!batch.length) break;
      for (const child of batch) await walkEntry(child, out);
    }
  }
}

// ─── Playlist & Loading Controller ──────────────────────────────────────────
async function addUserFiles(files, playFirst) {
  const sids = files.filter(f => f.name.toLowerCase().endsWith('.sid'));
  if (!sids.length) return;

  let firstAddedIdx = -1;
  const addedTracks = [];
  
  for (const file of sids) {
    try {
      const trackName = file.name.replace(/\.sid$/i, '');
      const trackId = `user:${file.name}:${file.size}`;
      
      // Duplicate detection
      const existingIdx = trackList.findIndex(t => t.name === trackName || t.id === trackId);
      if (existingIdx !== -1) {
        if (firstAddedIdx === -1) {
          firstAddedIdx = existingIdx;
        }
        continue; // Skip duplicates
      }

      const buf = await file.arrayBuffer();
      const uint8 = new Uint8Array(buf);
      const newTrack = {
        id: trackId,
        name: trackName,
        composer: 'Unknown Composer',
        year: 'N/A',
        isUser: true,
        buffer: uint8
      };
      
      addedTracks.push(newTrack);
      if (firstAddedIdx === -1) {
        firstAddedIdx = trackList.length + addedTracks.length - 1;
      }
    } catch (_) {}
  }

  if (addedTracks.length > 0) {
    trackList = [...trackList, ...addedTracks];
    refreshPlaylistUI();
  }

  if (playFirst && firstAddedIdx !== -1) {
    loadTrack(firstAddedIdx, true);
  }
}

function refreshPlaylistUI() {
  // Dropdown list
  trackSelect.innerHTML = '';
  const placeholder = document.createElement('option');
  placeholder.value = '';
  placeholder.textContent = `— ${trackList.length} Tunes —`;
  trackSelect.appendChild(placeholder);
  
  // Sidebar list HTML
  trackListContainer.innerHTML = '';

  trackList.forEach((track, i) => {
    const opt = document.createElement('option');
    opt.value = String(i);
    opt.textContent = track.name;
    trackSelect.appendChild(opt);

    const row = document.createElement('div');
    row.className = `track-row ${i === currentIdx ? 'active' : ''}`;
    row.innerHTML = `<span class="track-name">${track.name}</span>`;
    row.addEventListener('click', () => loadTrack(i, true));
    trackListContainer.appendChild(row);
  });

  if (currentIdx !== -1) {
    trackSelect.value = String(currentIdx);
  }
}

async function loadTrack(index, autoplay) {
  if (index < 0 || index >= trackList.length) return;
  
  currentIdx = index;
  const track = trackList[index];
  
  setPlayingUI(false);
  player.stop();
  showError(null);
  
  // Clean scrubber
  lastVisuals.playtime = 0;
  positionScrubber.value = 0;
  timeCurrent.textContent = '0:00';

  metaTitle.textContent = track.name;
  metaAuthor.textContent = track.composer;
  metaInfo.textContent = track.year ? `Hewson © ${track.year}` : 'C64 Chiptune';
  
  // Highlight active row in UI
  const rows = trackListContainer.querySelectorAll('.track-row');
  rows.forEach((r, idx) => {
    if (idx === index) r.classList.add('active');
    else r.classList.remove('active');
  });
  trackSelect.value = String(index);

  try {
    if (track.isUser && track.buffer) {
      await player.loadBuffer(track.buffer, 0);
    } else {
      // Fallback to URL fetch
      await player.load(track.url || `audio/${track.id}.sid`, 0);
    }
  } catch (err) {
    showError('Load failed: ' + err.message);
    return;
  }

  playBtn.disabled = false;
  positionScrubber.disabled = false;

  if (autoplay) {
    try {
      player.resumeContext();
      await player.play(WORKLET_BLOB_URL);
      setPlayingUI(true);
    } catch (e) {
      console.error('Autoplay failed:', e);
    }
  }
}

function setPlayingUI(isPlaying) {
  playingState = isPlaying;
  playBtn.textContent = isPlaying ? '■ STOP' : '▶ PLAY';
  footerState.textContent = isPlaying ? '▶ ACTIVE' : '■ IDLE';
  footerState.style.color = isPlaying ? 'var(--accent-color)' : 'var(--text-color)';
}

function setSubtune(sub) {
  currentSubtune = sub;
  player.setSubtune(sub);
  subtuneLabel.textContent = `SUBTUNE: ${sub + 1}/${totalSubtunesCount}`;
}

function showError(msg) {
  if (msg) {
    errorDisplay.textContent = msg;
    errorDisplay.style.display = 'block';
  } else {
    errorDisplay.style.display = 'none';
  }
}

// ─── Setup Callbacks ────────────────────────────────────────────────────────
player.watchLoaded((meta) => {
  currentMetadata = meta;
  currentSubtune = 0;
  totalSubtunesCount = meta.subtunesCount || 1;

  metaTitle.textContent = meta.title || trackList[currentIdx].name;
  metaAuthor.textContent = meta.author || 'Unknown Composer';
  metaInfo.textContent = meta.info || 'C64 Chiptune';

  // Toggle subtune HUD
  if (totalSubtunesCount > 1) {
    subtuneControls.style.display = 'inline-flex';
    subtuneLabel.textContent = `SUBTUNE: 1/${totalSubtunesCount}`;
  } else {
    subtuneControls.style.display = 'none';
  }
});

player.watchVisuals((visuals) => {
  // Store visuals for the draw loop
  lastVisuals.envelopes = visuals.envelopes;
  lastVisuals.frequencies = visuals.frequencies;
  lastVisuals.gates = visuals.gates;
  lastVisuals.waveforms = visuals.waveforms;
  lastVisuals.pulsewidths = visuals.pulsewidths;
  lastVisuals.playtime = visuals.playtime;
});

// ─── Visualizer Loop ────────────────────────────────────────────────────────
const ctx = canvas.getContext('2d');

function resizeCanvas() {
  const container = $('visualizer-container');
  canvas.width = container.clientWidth;
  canvas.height = container.clientHeight;
}
window.addEventListener('resize', resizeCanvas);
resizeCanvas();

function draw() {
  requestAnimationFrame(draw);

  const W = canvas.width;
  const H = canvas.height;
  if (W === 0 || H === 0) return;

  // Clear background — read from CSS custom property to follow theme
  const computedBg = getComputedStyle(playerEl).getPropertyValue('--bg-panel').trim() || '#07080c';
  ctx.fillStyle = computedBg;
  ctx.fillRect(0, 0, W, H);

  // Draw Grid Lines
  ctx.strokeStyle = 'rgba(74, 85, 104, 0.15)';
  ctx.lineWidth = 1;
  const gridSpacingX = W / 10;
  for (let x = 0; x < W; x += gridSpacingX) {
    ctx.beginPath();
    ctx.moveTo(x, 0);
    ctx.lineTo(x, H);
    ctx.stroke();
  }
  const gridSpacingY = H / 8;
  for (let y = 0; y < H; y += gridSpacingY) {
    ctx.beginPath();
    ctx.moveTo(0, y);
    ctx.lineTo(W, y);
    ctx.stroke();
  }

  const live = playingState;
  const envelopes = lastVisuals.envelopes;
  const frequencies = lastVisuals.frequencies;
  const gates = lastVisuals.gates;
  const waveforms = lastVisuals.waveforms;
  const pulsewidths = lastVisuals.pulsewidths;
  const playtime = lastVisuals.playtime || 0;

  // Sync scrubber value and text
  if (!isSeeking && positionScrubber) {
    positionScrubber.value = String(Math.min(playtime, SCRUB_MAX));
    timeCurrent.textContent = fmtTime(playtime);
  }

  // Playlist Auto Next
  if (live && autoNextCheck.checked && playtime >= SCRUB_MAX) {
    player.stop();
    setPlayingUI(false);
    if (trackList.length > 1) {
      const next = (currentIdx + 1) % trackList.length;
      loadTrack(next, true);
    }
  }

  const channelH = H / 3;

  for (let c = 0; c < 3; c++) {
    const baselineY = channelH * c + channelH / 2;
    const rawFreq = live ? frequencies[c] : 0;
    const env = live ? envelopes[c] : 0;
    const gate = live ? gates[c] : 0;
    const wf = live ? waveforms[c] : 0;
    const duty = pulsewidths[c] || 0.5;

    const freqHz = rawFreq * 0.0587;

    // Advance phase
    if (live) {
      phases[c] += (freqHz * 0.005) + 0.02;
      if (phases[c] > Math.PI * 2) phases[c] -= Math.PI * 2;
    }

    // Draw baseline
    ctx.strokeStyle = 'rgba(74, 85, 104, 0.25)';
    ctx.beginPath();
    ctx.moveTo(0, baselineY);
    ctx.lineTo(W, baselineY);
    ctx.stroke();

    // Draw oscillating wave
    ctx.beginPath();
    ctx.lineWidth = gate ? 2.0 : 1.0;
    ctx.strokeStyle = traceColors[c];
    
    // Glowing trace shadow
    ctx.shadowColor = traceColors[c];
    ctx.shadowBlur = gate ? Math.max(3, env * 10) : 0;

    const amplitude = !live ? 0 : (env > 0.01 ? env * (channelH * 0.38) : (Math.random() * 1.5 - 0.75));
    const wavelength = freqHz > 10 ? Math.max(10, Math.min(300, 3000 / freqHz)) : 150;
    const phaseShift = phases[c] / (Math.PI * 2);

    for (let x = 0; x < W; x += 2) {
      const ph = x / wavelength - phaseShift;
      const frac = ph - Math.floor(ph);
      const waveVal = sidWaveSample(frac, wf, duty);
      const y = baselineY + waveVal * amplitude;
      if (x === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    }
    ctx.stroke();
    ctx.shadowBlur = 0; // Reset shadow

    // Voice Overlay Text Labels
    ctx.font = '9px monospace';
    ctx.fillStyle = traceColors[c];
    ctx.textBaseline = 'middle';
    ctx.textAlign = 'left';
    const gateStr = gate ? 'GATE:ON ' : 'GATE:OFF';
    const freqStr = freqHz > 20 ? `${Math.round(freqHz).toString().padStart(4, ' ')} Hz` : '0 Hz';
    const envStr = `${Math.round(env * 100).toString().padStart(3, ' ')}%`;
    const wfStr = wfName(wf);

    ctx.fillText(
      `V${c + 1} | ${wfStr} | [${gateStr}] | Freq:${freqStr} | Env:${envStr}`,
      10,
      channelH * c + 10
    );
  }

  // Draw HUD Chip Model indicator
  const model = currentMetadata?.prefModel === 8580 ? '8580' : '6581';
  ctx.fillStyle = 'rgba(74, 222, 128, 0.4)';
  ctx.font = '9px monospace';
  ctx.textAlign = 'right';
  ctx.fillText(
    `CHIP MODEL: C64 ${model} // CHANNELS: 3 TRACE`,
    W - 10,
    H - 10
  );
}

// ─── Theme Toggle ───────────────────────────────────────────────────────────
if (themeBtn) {
  themeBtn.addEventListener('click', () => {
    const wasDark = playerEl.classList.contains('theme-dark');
    playerEl.classList.remove('theme-dark', 'theme-light');
    if (wasDark) {
      playerEl.classList.add('theme-light');
      themeBtn.textContent = 'DARK';
      localStorage.setItem('vicious-theme', 'light');
    } else {
      playerEl.classList.add('theme-dark');
      themeBtn.textContent = 'LIGHT';
      localStorage.setItem('vicious-theme', 'dark');
    }
  });

  // Restore saved theme or use system preference
  const savedTheme = localStorage.getItem('vicious-theme');
  if (savedTheme === 'dark') {
    playerEl.classList.add('theme-dark');
    themeBtn.textContent = 'LIGHT';
  } else if (savedTheme === 'light') {
    playerEl.classList.add('theme-light');
    themeBtn.textContent = 'DARK';
  } else {
    // No saved preference — follow system
    const prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
    themeBtn.textContent = prefersDark ? 'LIGHT' : 'DARK';
  }
}

// Start render loop
requestAnimationFrame(draw);
