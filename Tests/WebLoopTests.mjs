import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
const source = await readFile(new URL('../sid-player-worklet.js', import.meta.url), 'utf8');
const engineSource = source.slice(0, source.indexOf('class SidPlayerWorklet'));
const workerSource = await readFile(new URL('../sid-loop-worker.js', import.meta.url), 'utf8');
const Engine = new Function('sampleRate', engineSource + ';return SidPlayerProcessor;')(44100);
const analysis = await readFile(new URL('../src/analysis.js', import.meta.url), 'utf8');
const { Loop, pitch } = new Function(analysis + ';return {Loop:WebPlaybackLoop,pitch:sidPitch};')();
const wrapper = await readFile(new URL('../sidplayer.js', import.meta.url), 'utf8');
const { SidPlayer } = await import(`data:text/javascript;base64,${Buffer.from(wrapper).toString('base64')}`);
function fixture(model = 6581) {
  const code = [], store = (value, address) => code.push(0xa9, value, 0x8d, address & 255, address >> 8);
  for (let chip = 0; chip < 3; chip++) {
    const base = 0xd400 + chip * 0x20;
    store(0x1f, base + 0x18); store(0xf7, base + 0x17); store(0x20, base + 0x16);
    for (let voice = 0; voice < 3; voice++) {
      const address = base + voice * 7;
      store(37 + chip + voice, address); store(0x10 + (chip * 3 + voice) * 3, address + 1);
      store(0, address + 5); store(0xf0, address + 6); store(0x21, address + 4);
    }
  }
  code.push(0x60); const play = 0x1000 + code.length;
  code.push(0xad, 0x1b, 0xd4, 0x8d, 0x16, 0xd4, 0xad, 0x1c, 0xd4, 0x8d, 0x00, 0xd4, 0x60);
  const data = new Uint8Array(0x7c + code.length); data.set(Buffer.from('PSID'));
  const put = (value, offset) => { data[offset] = value >> 8; data[offset + 1] = value & 255; };
  put(4, 4); put(0x7c, 6); put(0x1000, 8); put(0x1000, 10); put(play, 12); put(1, 14); put(1, 16);
  put(model === 6581 ? 0x154 : 0x2a4, 0x76); data[0x7a] = 0x42; data[0x7b] = 0x44;
  data.set(code, 0x7c); return data;
}
function engine(data, clock = 'pal', muted = Array(9).fill(false)) {
  const p = new Engine(); p.setClockMode(clock); p.loadSID(data); p.initSubtune(0); p.setMutedChannels(muted); return p;
}
test('native pitch and marker vectors match and unreliable waveforms have no note', () => {
  const p = pitch(7493, 'pal', 0x20, 1); assert.equal(p.name, 'A4'); assert.equal(p.hertz, 440.0291004180908);
  assert.ok(pitch(7493, 'ntsc', 0x20, 1).hertz > p.hertz);
  for (const waveform of [0, 0x80, 0x30, 0xf0]) assert.equal(pitch(7493, 'pal', waveform, 1), null);
  const loop = new Loop(); loop.setStart(NaN, 10); assert.equal(loop.start, null);
  loop.setEnd(4, 10); assert.equal(loop.end, null);
  loop.setStart(-1, 10); loop.setEnd(0.1, 10); assert.equal(loop.range, null);
  loop.setEnd(4, 10); loop.setEnabled(true); assert.deepEqual(loop.range, [0, 4]);
  loop.setStart(5, 10); assert.equal(loop.end, null); assert.equal(loop.enabled, false);
});
test('filtered three-SID loops restore CPU, RAM, oscillators and envelopes bit for bit', () => {
  const muted = [false, true, false, false, false, true, false, false, false];
  for (const model of [6581, 8580]) for (const clock of ['pal', 'ntsc']) {
    const data = fixture(model), ref = engine(data, clock, muted), live = engine(data, clock, muted);
    ref.seek(0.2); const snapshot = ref.captureLoop(0.45);
    const expected = Array.from({ length: Math.floor(0.45 * 44100) - Math.floor(0.2 * 44100) }, () => ref.playSample());
    live.seek(0.45); live.setVolume(0.5); assert.equal(live.installLoop(structuredClone(snapshot)), true);
    for (let loop = 0; loop < 5; loop++) for (const sample of expected) assert.equal(live.playSample(), sample * 0.5);
    assert.ok(Math.abs(live.getChannelsData().playtime - 0.45) < 1e-8);
    live.disableLoop(); live.playSample(); assert.ok(live.getChannelsData().playtime > 0.45);
    live.seek(0); assert.equal(live.installLoop(snapshot), true);
    for (const sample of expected.slice(0, 2048)) assert.equal(live.playSample(), sample * 0.5);
  }
});
test('register peeks retain real slot addresses and do not change emulation', () => {
  const data = fixture(), p = engine(data), ref = engine(data);
  for (let i = 0; i < 3000; i++) {
    const v = p.getChannelsData(); assert.equal(v.chips[2].baseAddress, 0xd440);
    assert.equal(v.chips[1].registers[0], 38); assert.equal(v.chips[0].registers[25], null);
    assert.equal(p.playSample(), ref.playSample());
  }
});
test('a snapshot from another tune, clock or mix is rejected', () => {
  const data = fixture(), p = engine(data); p.seek(0.2); const snapshot = p.captureLoop(0.45);
  const other = data.slice(); other[other.length - 2] ^= 1;
  assert.equal(engine(other).installLoop(snapshot), false);
  assert.equal(engine(data, 'ntsc').installLoop(snapshot), false);
  assert.equal(engine(data, 'pal', Array(9).fill(true)).installLoop(snapshot), false);
  const unloaded = new Engine(); unloaded.loadSID(data); assert.equal(unloaded.installLoop(snapshot), false);
  const incomplete = structuredClone(snapshot); delete incomplete.state.voiceBandpass;
  assert.equal(engine(data).installLoop(incomplete), false);
});
test('the actual Dedicated Worker produces a transferable state matching the live engine', () => {
  let result;
  const context = vm.createContext({ self: { postMessage: value => { result = structuredClone(value); } } });
  vm.runInContext('let sampleRate=44100;\n' + engineSource + workerSource, context);
  context.input = { sampleRate: 44100, data: fixture(), subtune: 0, clockMode: 'ntsc', muted: Array(9).fill(false), start: 2, end: 2.25 };
  vm.runInContext('self.onmessage({data:input})', context);
  assert.ok(result.snapshot); const live = engine(context.input.data, 'ntsc'); assert.equal(live.installLoop(result.snapshot), true);
  live.seek(2.25); assert.equal(live.installLoop(result.snapshot), true);
  const ref = engine(context.input.data, 'ntsc'); ref.seek(2);
  for (let i = 0; i < 2048; i++) assert.equal(live.playSample(), ref.playSample());
});
test('stale preparation, mute and outside seek cannot reactivate an old loop', async () => {
  const previousWorker = globalThis.Worker, workers = [];
  globalThis.Worker = class {
    constructor() { workers.push(this); }
    postMessage(message) { this.input = message; }
    terminate() { this.terminated = true; }
  };
  try {
    const player = new SidPlayer(), messages = [];
    player.audioCtx = { sampleRate: 44100 }; player.workletNode = { port: { postMessage: value => messages.push(value) } };
    await player.loadBuffer(fixture());
    player.setLoopRange([0.2, 0.45], 'fixture worker');
    player.loopWorker.terminate(); player.loopWorker = null; player.loopReady = true;
    const preparedCount = workers.length;
    player.stop(); await player.play('fixture worklet');
    assert.equal(workers.length, preparedCount, 'resume reuses the prepared state');
    player.setLoopRange([0.2, 0.45], 'fixture worker'); const first = workers.at(-1);
    player.setMutedChannels(Array(9).fill(true)); assert.equal(first.terminated, true);
    first.onmessage({ data: { snapshot: {} } }); assert.equal(messages.filter(m => m.type === 'installLoop').length, 0);
    const second = workers.at(-1); player.seek(3); assert.equal(player.loopRange, null); assert.equal(second.terminated, true);
    second.onmessage({ data: { snapshot: {} } }); assert.equal(messages.filter(m => m.type === 'installLoop').length, 0);
    player.setLoopRange([0, 0.25], 'fixture worker'); player.setSubtune(0); assert.equal(player.loopRange, null);
    assert.equal(player.setLoopRange([NaN, 2]), false); assert.equal(player.setLoopRange([0, 0.1]), false);
    player.loopWorkerSource = null; player.setLoopRange([0, 0.25]); assert.equal(player.loopRange, null);
  } finally { globalThis.Worker = previousWorker; }
});
