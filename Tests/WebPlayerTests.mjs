import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
const wrapper = await readFile(new URL('../sidplayer.js', import.meta.url), 'utf8');
const { SidPlayer, parseSidHeader } = await import(`data:text/javascript;base64,${Buffer.from(wrapper).toString('base64')}`);
const source = await readFile(new URL('../sid-player-worklet.js', import.meta.url), 'utf8');
const listeningSource = await readFile(new URL('../src/listening.js', import.meta.url), 'utf8');
const historySource = await readFile(new URL('../src/history.js', import.meta.url), 'utf8');
const collectionSource = await readFile(new URL('../src/collection.js', import.meta.url), 'utf8');
const storageSource = await readFile(new URL('../src/personal-storage.js', import.meta.url), 'utf8');
const collectionUI = await readFile(new URL('../src/collection-ui.js', import.meta.url), 'utf8');
const analysisSource = await readFile(new URL('../src/analysis.js', import.meta.url), 'utf8');
const analysisUI = await readFile(new URL('../src/analysis-ui.js', import.meta.url), 'utf8');
const historyUI = await readFile(new URL('../src/history-ui.js', import.meta.url), 'utf8');
const listeningUI = await readFile(new URL('../src/listening-ui.js', import.meta.url), 'utf8');
const appSource = await readFile(new URL('../src/app.js', import.meta.url), 'utf8');
const Engine = new Function('sampleRate', source.slice(0, source.indexOf('class SidPlayerWorklet')) + '; return SidPlayerProcessor;')(44100);

function sid(code = [0x60], version = 2, playOffset = code.length - 1) {
  const data = new Uint8Array((version === 1 ? 0x76 : 0x7C) + code.length);
  data.set(Buffer.from('PSID'));
  const put = (value, offset) => { data[offset] = value >> 8; data[offset + 1] = value & 255; };
  put(version, 4); put(data.length - code.length, 6); put(0x1000, 8); put(0x1000, 10);
  put(0x1000 + playOffset, 12); put(1, 14); put(1, 16);
  if (version > 1) data[0x77] = 0x20;
  data.set(code, data.length - code.length);
  return data;
}
function engine(data) { const p = new Engine(); p.loadSID(data); p.initSubtune(0); return p; }

test('clock flags select PAL/NTSC VBI and CIA pacing', () => {
  for (const [flag, calls] of [[4, 50], [8, 60], [0, 50], [12, 50]]) {
    const data = sid([0x60, 0xEE,0x00,0xD4,0x60], 2, 1);
    data[0x77] |= flag;
    assert.equal(parseSidHeader(data).clockPreference, ['unknown', 'pal', 'ntsc', 'both'][flag >> 2]);
    const p = engine(data);
    for (let i = 0; i < 44100; i++) p.playSample();
    assert.equal(p.getChannelsData().frequencies[0], calls);
    data[0x15] = 1;
    const cia = engine(data);
    for (let i = 0; i < 44100; i++) cia.playSample();
    assert.equal(cia.getChannelsData().frequencies[0], 60);
  }
});

test('clock override rebuilds the same position and preserves seek determinism', () => {
  const data = sid([0x60,0xEE,0x00,0xD4,0x60], 2, 1);
  data[0x77] |= 8;
  const p = engine(data);
  for (let i = 0; i < 44100; i++) p.playSample();
  p.setClockMode('pal'); p.advanceSeek(Number.MAX_SAFE_INTEGER);
  assert.equal(p.getChannelsData().frequencies[0], 50);
  assert.equal(p.getChannelsData().clock, 'pal');
  p.setClockMode('auto'); p.advanceSeek(Number.MAX_SAFE_INTEGER);
  assert.equal(p.getChannelsData().frequencies[0], 60);
  assert.equal(p.getChannelsData().clock, 'ntsc');
});

test('clock changes during preparation preserve the complete seek target', () => {
  const p = engine(sid());
  p.beginSeek(5); p.advanceSeek(4410);
  p.setClockMode('ntsc'); p.advanceSeek(8820);
  p.setClockMode('pal'); p.advanceSeek(Number.MAX_SAFE_INTEGER);
  assert.ok(Math.abs(p.getChannelsData().playtime - 5) < 2 / 44100);
  assert.equal(p.getChannelsData().clock, 'pal');
  p.playSample(); p.setClockMode('ntsc'); p.advanceSeek(Number.MAX_SAFE_INTEGER);
  assert.ok(Math.abs(p.getChannelsData().playtime - 5) < 4 / 44100);
});

test('CIA latch changes during play take effect after the running interval', () => {
  const data = sid([0x60,0xA9,0,0x8D,4,0xDC,0xA9,0x10,0x8D,5,0xDC,0xEE,0,0xD4,0x60], 2, 1);
  data[0x77] |= 8; data[0x15] = 1;
  const p = engine(data);
  for (let i = 0; i < 22050; i++) p.playSample();
  const expected = 1 + (0.5 - 17046 / 1022727) * 1022727 / 4097;
  assert.ok(Math.abs(p.getChannelsData().frequencies[0] - expected) < 1.5);
});
function audioMock() {
  let release;
  const module = new Promise(resolve => { release = resolve; });
  const nodes = [];
  globalThis.window = { AudioContext: class {
    state = 'running'; destination = {}; audioWorklet = { addModule: () => module };
    createBuffer() { return {}; }
    createBufferSource() { return { connect() {}, start() {}, disconnect() {} }; }
  }};
  globalThis.AudioWorkletNode = class {
    messages = []; port = { postMessage: message => this.messages.push(message) };
    constructor() { nodes.push(this); }
    connect() {} disconnect() {}
  };
  return { nodes, release };
}

async function ui() {
  class Element {
    listeners = {}; style = {}; dataset = {}; disabled = true; value = ''; children = [];
    classes = new Set();
    classList = { add: (...names) => names.forEach(n => this.classes.add(n)),
      remove: (...names) => names.forEach(n => this.classes.delete(n)), contains: name => this.classes.has(name) };
    addEventListener(name, fn) { this.listeners[name] = fn; }
    appendChild(child) { this.children.push(child); }
    append(...children) { this.children.push(...children); }
    replaceChildren(...children) { this.children = children; }
    removeAttribute() {}
    setAttribute() {} querySelectorAll() { return []; } getContext() { return {}; }
    showModal() { this.open = true; } close() { this.open = false; } focus() {}
  }
  let release;
  const module = new Promise(resolve => { release = resolve; });
  const elements = new Map();
  const storageValues = new Map();
  const context = vm.createContext({ console, Uint8Array, WeakMap, setTimeout, clearTimeout, performance, TextEncoder, AbortController,
    navigator: { locks: { request: (_name, _options, action) => Promise.resolve().then(action) } },
    document: { getElementById(id) { if (!elements.has(id)) elements.set(id, new Element()); return elements.get(id); },
      createElement() { return new Element(); }, createTextNode(value) { return value; } },
    window: { addEventListener() {}, confirm() { return true; }, matchMedia() { return { matches: true }; }, AudioContext: class {
      state = 'running'; destination = {}; audioWorklet = { addModule: () => module };
      createBuffer() { return {}; } createBufferSource() { return { connect() {}, start() {}, disconnect() {} }; }
    } },
    AudioWorkletNode: class { messages = []; port = { postMessage: message => this.messages.push(message) }; connect() {} },
    localStorage: { getItem(key) { return storageValues.get(key) ?? null; }, setItem(key, value) { storageValues.set(key, value); }, removeItem(key) { storageValues.delete(key); } }, requestAnimationFrame() {}, WORKLET_URL: 'fixture'
  });
  context.window.document = context.document;
  vm.runInContext(wrapper.replaceAll('export ', ''), context);
  vm.runInContext(listeningSource, context);
  vm.runInContext(historySource, context);
  vm.runInContext(collectionSource, context);
  vm.runInContext(storageSource, context);
  vm.runInContext(historyUI, context);
  vm.runInContext(listeningUI, context);
  vm.runInContext(collectionUI, context);
  vm.runInContext(analysisSource, context);
  vm.runInContext(analysisUI, context);
  vm.runInContext(appSource, context);
  await vm.runInContext('webListeningReady', context);
  context.valid = sid();
  vm.runInContext("trackList = [{name:'Valid',buffer:valid,isUser:true},{name:'Invalid',buffer:new Uint8Array(5),isUser:true}]", context);
  return { elements, release, run: code => vm.runInContext(code, context) };
}

test('PSID v1 has no model flags; truncated and overlapping headers are rejected', () => {
  assert.equal(parseSidHeader(sid([0x60], 1)).prefModel, 6581);
  assert.equal(parseSidHeader(sid([0x60, 0x30, 0, 0, 0, 0x60], 1)).prefModel, 6581);
  const bad = sid(); bad[7] = 1;
  assert.equal(parseSidHeader(bad), null);
});
test('indirect pointer bytes wrap at the zero-page boundary', () => {
  for (const opcode of [0xA1, 0xB1]) {
    const p = engine(sid([0xA9,0,0x85,0xFF,0xA9,0x20,0x85,0,
      0xA9,0x30,0x8D,0,1,0xA9,0x11,0x8D,0,0x20,
      0xA9,0x22,0x8D,0,0x30,opcode,0xFF,0x8D,1,0xD4,0x60]));
    assert.equal(p.getChannelsData().frequencies[0], 0x1100);
  }
});
test('noise restart reproduces the fresh beginning', () => {
  const p = engine(sid([0xA9,15,0x8D,0x18,0xD4,0xA9,0,0x8D,5,0xD4,
    0xA9,0xF0,0x8D,6,0xD4,0xA9,0x20,0x8D,1,0xD4,0xA9,0x81,0x8D,4,0xD4,0x60]));
  const first = Array.from({ length: 4000 }, () => p.playSample());
  p.seek(0);
  assert.deepEqual(Array.from({ length: 4000 }, () => p.playSample()), first);
});
test('seek preserves ENV3-dependent CPU decisions and following audio', () => {
  const code = [0xA9,15,0x8D,0x18,0xD4,0xA9,0,0x8D,0x13,0xD4,
    0xA9,0xF0,0x8D,0x14,0xD4,0xA9,0x11,0x8D,0x12,0xD4,0xA9,0x20,0x8D,1,0xD4,0x60];
  const offset = code.length;
  code.push(0xAD,0x1C,0xD4,0xC9,0x80,0x90,5,0xA9,0x50,0x8D,1,0xD4,0x60);
  const played = engine(sid(code, 2, offset)), skipped = engine(sid(code, 2, offset));
  for (let i = 0; i < 44100; i++) played.playSample();
  skipped.seek(1);
  assert.equal(skipped.getChannelsData().frequencies[0], 0x5000);
  assert.deepEqual(Array.from({ length: 1000 }, () => skipped.playSample()), Array.from({ length: 1000 }, () => played.playSample()));
});
test('seek and subtune restart restore RAM before a non-idempotent init', () => {
  const p = engine(sid([0xEE,0,0x20,0xAD,0,0x20,0x8D,1,0xD4,0x60]));
  assert.equal(p.getChannelsData().frequencies[0], 256);
  for (let i = 0; i < 1000; i++) p.playSample();
  p.seek(0);
  assert.equal(p.getChannelsData().frequencies[0], 256);
  p.initSubtune(0);
  assert.equal(p.getChannelsData().frequencies[0], 256);
});
test('file model flags change filtered audio for each SID chip', () => {
  for (const chip of [0, 1, 2]) {
    const address = [0xD400, 0xD420, 0xD440][chip];
    const code = [];
    for (const [offset, value] of [[0x18,0x1F],[5,0],[6,0xF0],[1,0x20],[4,0x21],[0x16,0x40],[0x17,1]]) {
      code.push(0xA9,value,0x8D,(address + offset) & 255,(address + offset) >> 8);
    }
    code.push(0x60);
    const render = model => {
      const data = sid(code, 4);
      data[0x7A] = chip > 0 ? 0x42 : 0;
      data[0x7B] = chip > 1 ? 0x44 : 0;
      if (chip === 0) data[0x77] = model === 6581 ? 0x10 : 0x20;
      if (chip === 1) data[0x77] |= model === 6581 ? 0x40 : 0x80;
      if (chip === 2) data[0x76] = model === 6581 ? 1 : 2;
      const p = engine(data);
      return Array.from({ length: 4000 }, () => p.playSample());
    };
    assert.notDeepEqual(render(6581), render(8580));
  }
});
test('concurrent play requests create one connected worklet', async () => {
  const mock = audioMock(), player = new SidPlayer();
  await player.loadBuffer(sid());
  const first = player.play('fixture'), second = player.play('fixture');
  mock.release(); await Promise.all([first, second]);
  assert.equal(mock.nodes.length, 1);
  assert.equal(mock.nodes[0].messages.filter(m => m.type === 'play').length, 1);
});
test('stop during audio setup prevents late playback', async () => {
  const mock = audioMock(), player = new SidPlayer();
  await player.loadBuffer(sid());
  const pending = player.play('fixture'); player.stop(); mock.release(); await pending;
  assert.equal(player.playing, false);
  assert.equal(mock.nodes.flatMap(n => n.messages).filter(m => m.type === 'play').length, 0);
});
test('an existing worklet receives one load and metadata callback', async () => {
  const mock = audioMock(), player = new SidPlayer(); mock.release();
  await player.setupAudio('fixture');
  let loaded = 0; player.watchLoaded(() => loaded++);
  await player.loadBuffer(sid());
  player.setSubtune(0); await player.play('fixture');
  const node = mock.nodes[0];
  node.port.onmessage({ data: { type: 'loaded', generation: player.loadGen, metadata: {} } });
  assert.equal(loaded, 1);
  assert.equal(node.messages.filter(m => m.type === 'load').length, 1);
});
test('unload invalidates an outstanding fetch', async () => {
  let release;
  globalThis.fetch = () => new Promise(resolve => { release = resolve; });
  const player = new SidPlayer(), pending = player.load('fixture'); player.unload();
  release({ ok: true, arrayBuffer: async () => sid().buffer }); await pending;
  assert.equal(player.loaded, false); assert.equal(player.pendingData, null);
});

test('worklet seek yields between blocks and a newer seek replaces it', () => {
  const Worklet = new Function('sampleRate', 'AudioWorkletProcessor', 'registerProcessor', source + '; return SidPlayerWorklet;')(
    44100, class { port = { postMessage() {} }; }, () => {});
  const worklet = new Worklet();
  const send = data => worklet.port.onmessage({ data });
  send({ type: 'load', data: sid(), generation: 1 });
  send({ type: 'seek', seconds: 300 });
  const outputs = [[new Float32Array(128), new Float32Array(128)]];
  worklet.process([], outputs, {});
  assert.equal(worklet.seeking, true);
  send({ type: 'seek', seconds: 0 });
  worklet.process([], outputs, {});
  assert.equal(worklet.seeking, false);
  assert.equal(worklet.engine.getChannelsData().playtime, 0);
});

test('a failed UI selection cannot play the previously loaded title', async () => {
  const page = await ui(); page.release();
  await page.run('loadTrack(0, true)');
  await page.run('loadTrack(1, true)');
  await page.elements.get('play-btn').listeners.click();
  assert.equal(page.elements.get('play-btn').disabled, true);
  assert.equal(page.run('player.loaded'), false);
  assert.equal(page.run('player.playing'), false);
  assert.match(page.elements.get('error-display').textContent, /bad header/);
});

test('Stop during initial autoplay setup leaves the UI idle after setup completes', async () => {
  const page = await ui();
  const pending = page.run('loadTrack(0, true)');
  await Promise.resolve(); await Promise.resolve();
  assert.equal(page.run('playingState'), true);
  await page.elements.get('play-btn').listeners.click();
  page.release(); await pending;
  assert.equal(page.run('player.playing'), false);
  assert.equal(page.run('playingState'), false);
  assert.equal(page.elements.get('footer-state').textContent, '■ IDLE');
});

test('the first theme click switches a dark system default to light', async () => {
  const page = await ui();
  assert.equal(page.elements.get('theme-btn').textContent, 'LIGHT');
  page.elements.get('theme-btn').listeners.click();
  assert.equal(page.elements.get('player').classList.contains('theme-light'), true);
  assert.equal(page.elements.get('theme-btn').textContent, 'DARK');
});

test('seek before the first audio node is sent between load and play', async () => {
  const mock = audioMock(), player = new SidPlayer();
  await player.loadBuffer(sid()); player.seek(12); const pending = player.play('fixture'); mock.release(); await pending;
  const messages = mock.nodes[0].messages;
  const load = messages.findIndex(m => m.type === 'load'), seek = messages.findIndex(m => m.type === 'seek'), play = messages.findIndex(m => m.type === 'play');
  assert.ok(load < seek && seek < play); assert.equal(messages[seek].seconds, 12); assert.equal(player.pendingSeekSeconds, null);
});
test('a different file or subtune clears a buffered seek', async () => {
  const player = new SidPlayer(); await player.loadBuffer(sid()); player.seek(12);
  player.setSubtune(0); assert.equal(player.pendingSeekSeconds, null);
  player.seek(5); await player.loadBuffer(sid()); assert.equal(player.pendingSeekSeconds, null);
});
test('late visualizer messages cannot advance the next file or subtune', async () => {
  const mock = audioMock(), player = new SidPlayer(); mock.release(); await player.loadBuffer(sid()); await player.play('fixture');
  const node = mock.nodes[0], oldGeneration = player.loadGen; let visuals = 0; player.watchVisuals(() => visuals++);
  player.setSubtune(0); node.port.onmessage({ data: { type: 'visualizer', generation: oldGeneration, data: {} } });
  assert.equal(visuals, 0);
  node.port.onmessage({ data: { type: 'visualizer', generation: player.loadGen, data: {} } }); assert.equal(visuals, 1);
});
test('explicit search selection is stable after the visible filter changes', async () => {
  const page = await ui(); page.release();
  page.run(`files = [{name:'Alpha.sid', arrayBuffer: async () => valid.buffer}, {name:'Beta.sid', arrayBuffer: async () => valid.buffer}]`);
  await page.run('importUserFiles(files, false)');
  page.elements.get('library-search').value = 'Alpha'; await page.run("startWebScope('visible')");
  assert.equal(page.run('listeningQueue.items.length'), 1);
  page.elements.get('library-search').value = 'Beta'; page.run('refreshPlaylistUI()');
  assert.match(page.run('listeningQueue.current.trackID'), /Alpha/);
});
test('reselecting one moved file reconnects its saved identity without autoplay', async () => {
  const page = await ui(); page.release();
  page.run(`trackList=[];currentIdx=-1;files=[{name:'A.sid',webkitRelativePath:'Old/A.sid',arrayBuffer:async()=>valid.buffer}]`);
  await page.run('importUserFiles(files,false);');
  await page.run('loadTrack(0,false)');
  const id = page.run('trackList[0].id');
  page.run(`trackList=[];currentIdx=-1;pendingWebRestore=true;files=[{name:'A.sid',webkitRelativePath:'Moved/A.sid',arrayBuffer:async()=>valid.buffer}]`);
  await page.run('importUserFiles(files,true)');
  assert.equal(page.run('trackList[0].id'), id);
  assert.equal(page.run('webListeningStore.document.catalog[0].path'), 'Moved/A.sid');
  assert.equal(page.run('playingState'), false);
});
test('two incoming identical copies cannot both relink to one old identity', async () => {
  const page = await ui(); page.release();
  page.run(`trackList=[];currentIdx=-1;files=[{name:'A.sid',webkitRelativePath:'Old/A.sid',arrayBuffer:async()=>valid.buffer}]`);
  await page.run('importUserFiles(files,false)');
  const old = page.run('trackList[0].id');
  page.run(`trackList=[];currentIdx=-1;pendingWebRestore=true;files=['First','Second'].map(folder=>({name:'A.sid',webkitRelativePath:folder+'/A.sid',arrayBuffer:async()=>valid.buffer}))`);
  await page.run('importUserFiles(files,false)');
  assert.equal(page.run('trackList.length'), 2);
  assert.notEqual(page.run('trackList[0].id'), old);
  assert.notEqual(page.run('trackList[1].id'), old);
  assert.notEqual(page.run('trackList[0].id'), page.run('trackList[1].id'));
});

test('only the latest seek completion can resume the listening clock', async () => {
  const mock = audioMock(), player = new SidPlayer(); mock.release();
  await player.loadBuffer(sid()); await player.play('fixture');
  player.seek(200); const first = player.seekRequest;
  player.seek(300); const second = player.seekRequest;
  const node = mock.nodes[0];
  node.port.onmessage({ data: { type: 'seekComplete', generation: player.loadGen, request: first } });
  assert.equal(player.seeking, true);
  node.port.onmessage({ data: { type: 'seekComplete', generation: player.loadGen - 1, request: second } });
  assert.equal(player.seeking, true);
  node.port.onmessage({ data: { type: 'seekComplete', generation: player.loadGen, request: second } });
  assert.equal(player.seeking, false);
  player.setClockMode('ntsc'); assert.equal(player.seeking, true);
  await player.loadBuffer(sid()); assert.equal(player.seeking, false);
});

test('a note editor keeps its original subtune when playback changes behind the dialog', async () => {
  const model = await ui();
  model.run("trackList=[{id:'one',name:'One',buffer:valid,isUser:true}];webListeningStore.document.catalog=[{id:'one',path:'A/One.sid',fingerprint:'123456789abcdef0',size:valid.length,name:'One',subtunesCount:3}]");
  await model.run('loadTrack(0,false)');
  model.run("openWebHistoryEditor('note');currentSubtune=2;document.getElementById('history-note-scope').value='file';document.getElementById('history-note-scope').listeners.change();document.getElementById('history-note-scope').value='subtune';document.getElementById('history-note-scope').listeners.change()");
  assert.equal(model.run('historyEditor.reference.subtune'), 0);
});

test('collection apply during initial audio setup invalidates the old play and resumes the requested playback once', async () => {
  const page = await ui();
  await page.run(`trackList=[{id:'one',name:'One',buffer:valid,isUser:true}];
    webListeningStore.document.catalog=[{id:'one',path:'A/One.sid',fingerprint:'123456789abcdef0',md5:collectionMD5(valid),size:valid.length,name:'One',subtunesCount:1}];
    webListeningStore.document.libraryIDs=['one']; loadTrack(0,false)`);
  page.run(`collectionUI.document=emptyCollectionDocument();collectionUI.document.favorites=[{path:'A/One.sid',md5:collectionMD5(valid)}];
    $('collection-dialog').showModal();refreshCollectionPreview();renderCollectionUI()`);
  const oldPlay = page.elements.get('play-btn').listeners.click();
  assert.equal(page.run('playingState'), true); assert.equal(page.run('player.playing'), false);
  const importing = page.run('applyCollectionImport()');
  for (let i = 0; i < 10; i++) await new Promise(resolve => setImmediate(resolve));
  assert.equal(page.run('webListeningStore.document.favorites.includes("one")'), true);
  assert.equal(page.run('webCollectionBusy'), true);
  page.release(); await Promise.all([oldPlay, importing]);
  assert.equal(page.run('player.playing'), true); assert.equal(page.run('playingState'), true);
  assert.equal(page.run('player.workletNode.messages.filter(m=>m.type==="play").length'), 1);
});

test('a delayed close event from the previous dialog cannot invalidate a newly opened preview', async () => {
  const page = await ui(), dialog = page.elements.get('collection-dialog');
  page.elements.get('collection-open').listeners.click();
  page.run('collectionUI.document=emptyCollectionDocument();refreshCollectionPreview()');
  const generation = page.run('collectionUI.generation');
  dialog.listeners.close();
  assert.equal(page.run('collectionUI.generation'), generation);
  assert.equal(page.run('collectionUI.preview!=null'), true);
  dialog.open = false; dialog.listeners.close();
  assert.equal(page.run('collectionUI.document'), null);
  assert.equal(page.run('collectionUI.generation'), generation + 1);
});

test('analysis mask is copied and reaches a new audio node before the buffered seek and play', async () => {
  const mock = audioMock(), player = new SidPlayer(), mask = Array(9).fill(false); mask[4] = true;
  assert.equal(player.setMutedChannels(mask), true); mask[4] = false;
  await player.loadBuffer(sid()); player.seek(12);
  const pending = player.play('fixture'); mock.release(); await pending;
  const messages = mock.nodes[0].messages, mute = messages.findIndex(m => m.type === 'setMutedChannels');
  assert.equal(messages[mute].muted[4], true);
  assert(mute < messages.findIndex(m => m.type === 'seek'));
  assert(mute < messages.findIndex(m => m.type === 'play'));
});
test('clearing and reselecting the library keeps analysis callbacks and ignores an invisible solo', async () => {
  const page = await ui();
  page.run(`valid[5]=4;valid[0x7a]=0x42;valid[0x7b]=0x44;
    trackList=[{id:'one',name:'One',buffer:valid,isUser:true}];
    webListeningStore.document.catalog=[{id:'one',path:'One.sid',name:'One',fingerprint:'123456789abcdef0',size:valid.length,subtunesCount:1}];
    webListeningStore.document.libraryIDs=['one'];`);
  await page.run('loadTrack(0,false)');
  assert.deepEqual(Array.from(page.run('activeWebSIDChips()')), [0, 1, 2]);
  page.run('webAnalysisMix.toggleSolo(8);applyWebAnalysisMix()');
  page.elements.get('clear-library').listeners.click();
  page.run(`valid[5]=2;valid[0x7a]=0;valid[0x7b]=0;
    trackList=[{id:'two',name:'Two',buffer:valid,isUser:true}];
    webListeningStore.document.catalog.push({id:'two',path:'Two.sid',name:'Two',fingerprint:'abcdef0123456789',size:valid.length,subtunesCount:1});
    webListeningStore.document.libraryIDs=['two'];`);
  await page.run('loadTrack(0,false)');
  assert.deepEqual(Array.from(page.run('activeWebSIDChips()')), [0]);
  assert.deepEqual(Array.from(page.run('player.mutedChannels.slice(0,3)')), [false, false, false]);
  assert.equal(page.run('webAnalysisMix.soloChannels.has(8)'), true);
  assert.equal(page.run('typeof player.visualCallback'), 'function');
});

function seedSequenceFiles(page) {
  page.run(`trackList=[{id:'one',name:'One',buffer:valid,isUser:true},{id:'two',name:'Two',buffer:valid,isUser:true}];
    webListeningStore.document.catalog=trackList.map(t=>({id:t.id,path:t.name+'.sid',name:t.name,fingerprint:'123456789abcdef0',size:valid.length,subtunesCount:1}));
    webListeningStore.document.libraryIDs=['one','two'];`);
}
test('ending a queue during its pending start prevents late queue restoration', async () => {
  const page = await ui(); seedSequenceFiles(page);
  const pending = page.run('startWebScope("library")');
  for (let i=0;i<4;i++) await Promise.resolve();
  page.elements.get('end-queue').listeners.click(); page.release(); await pending;
  assert.equal(page.run('listeningQueue'), null);
  assert.equal(page.run('webListeningStore.document.queue'), null);
  assert.equal(page.run('player.playing'), false);
});
test('ending a queue during pending navigation prevents copying the old queue back', async () => {
  const page = await ui(); seedSequenceFiles(page); await page.run('loadTrack(0,false)');
  const pending = page.run('advanceWebQueue(true,true)');
  for (let i=0;i<4;i++) await Promise.resolve();
  page.elements.get('end-queue').listeners.click(); page.release(); await pending;
  assert.equal(page.run('listeningQueue'), null);
  assert.equal(page.run('webListeningStore.document.queue'), null);
});
test('clearing the library invalidates a pending queue start and its saved queue', async () => {
  const page = await ui(); seedSequenceFiles(page);
  const pending = page.run('startWebScope("library")');
  for (let i=0;i<4;i++) await Promise.resolve();
  page.elements.get('clear-library').listeners.click(); page.release(); await pending;
  assert.equal(page.run('listeningQueue'), null);
  assert.equal(page.run('webListeningStore.document.queue'), null);
  assert.equal(page.run('trackList.length'), 0);
});
