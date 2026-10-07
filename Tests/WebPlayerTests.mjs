import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const wrapper = await readFile(new URL('../sidplayer.js', import.meta.url), 'utf8');
const { SidPlayer, parseSidHeader } = await import(`data:text/javascript;base64,${Buffer.from(wrapper).toString('base64')}`);
const source = await readFile(new URL('../sid-player-worklet.js', import.meta.url), 'utf8');
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
