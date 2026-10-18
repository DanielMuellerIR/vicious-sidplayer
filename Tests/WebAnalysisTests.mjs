import { sidSource } from './WebSourceSupport.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const analysis = await readFile(new URL('../src/analysis.js', import.meta.url), 'utf8');
const Mix = new Function(analysis + ';return WebAnalysisMix')();
const source = await sidSource('sid-player-worklet.js');
const Engine = new Function('sampleRate', source.slice(0, source.indexOf('class SidPlayerWorklet')) + ';return SidPlayerProcessor;')(44100);
const wrapper = await sidSource('sidplayer.js');
const { parseSidHeader } = await import(`data:text/javascript;base64,${Buffer.from(wrapper).toString('base64')}`);
function sid(chips, filtered = false, changingRouting = false) {
  const code = [], store = (value, address) => code.push(0xa9, value, 0x8d, address & 255, address >> 8);
  for (let chip = 0; chip < chips; chip++) {
    const base = 0xd400 + chip * 0x20; store(filtered ? 0x1f : 15, base + 0x18);
    if (filtered) { store(0xf7, base + 0x17); store(0x20, base + 0x16); }
    for (let voice = 0; voice < 3; voice++) {
      const address = base + voice * 7;
      store(37 + voice, address); store(0x10 + (chip * 3 + voice) * 3, address + 1);
      store(0, address + 5); store(0xf0, address + 6); store(0x21, address + 4);
    }
  }
  code.push(0x60);
  const playOffset = changingRouting ? code.length : code.length - 1;
  if (changingRouting) {
    for (let chip = 0; chip < chips; chip++) {
      const address = 0xd417 + chip * 0x20;
      code.push(0xad, address & 255, address >> 8, 0x49, 7, 0x8d, address & 255, address >> 8);
    }
    code.push(0x60);
  }
  const data = new Uint8Array(0x7c + code.length); data.set(Buffer.from('PSID'));
  const put = (value, offset) => { data[offset] = value >> 8; data[offset + 1] = value & 255; };
  put(chips + 1, 4); put(0x7c, 6); put(0x1000, 8); put(0x1000, 10); put(0x1000 + playOffset, 12);
  put(1, 14); put(1, 16); put(0x194, 0x76);
  if (chips > 1) data[0x7a] = 0x42;
  if (chips > 2) data[0x7b] = 0x44;
  data.set(code, 0x7c); return data;
}
function engine(data) { const p = new Engine(); p.loadSID(data); p.initSubtune(0); return p; }

test('solo union, chip priority and restoration match the native policy vectors', () => {
  const mix = new Mix(); mix.toggleChannelMuted(1); mix.toggleSolo(0); mix.toggleSolo(4);
  assert.deepEqual(mix.effectiveMuted([0, 1]), [false, true, true, true, false, true, true, true, true]);
  mix.toggleChipMuted(1); assert.equal(mix.effectiveMuted([0, 1])[4], true);
  mix.clearSolos(); assert.deepEqual(mix.channelMuted, [false, true, false, false, false, false, false, false, false]);
  assert.equal(mix.chipMuted[1], true);
});
test('invisible solos and sparse active slots never mute a smaller unrelated tune', () => {
  const mix = new Mix(); mix.toggleSolo(7);
  assert.deepEqual(mix.effectiveMuted([0]).slice(0, 3), [false, false, false]);
  assert.deepEqual(mix.effectiveMuted([0, 2]), [true, true, true, true, true, true, true, false, true]);
  for (const value of [-1, 9, 1.5, NaN]) mix.toggleSolo(value);
  assert.deepEqual([...mix.soloChannels], [7]);
});
test('headers and live register data identify each actual SID chip and its model', () => {
  const data = sid(3), meta = parseSidHeader(data), p = engine(data);
  assert.deepEqual(meta.activeSIDChips, [0, 1, 2]); assert.deepEqual(meta.chipModels, [6581, 8580, 6581]);
  for (let i = 0; i < 2048; i++) p.playSample();
  const values = p.getChannelsData();
  assert.deepEqual(values.frequencies, values.chips[0].frequencies);
  for (let chip = 0; chip < 3; chip++) {
    assert.equal(values.chips[chip].frequencies[0], 37 + (0x10 + chip * 9) * 256);
    assert(values.chips[chip].envelopes[0] > 0); assert.equal(values.chips[chip].gates[2], 1);
  }
  data[0x7a] = 0; assert.deepEqual(parseSidHeader(data).activeSIDChips, [0, 2]);
});
test('one muted channel removes its own mono contribution and unmute returns the continuous state', () => {
  for (const chips of [2, 3]) {
    const data = sid(chips), full = engine(data), muted = engine(data), isolated = engine(data);
    const muteMask = Array(9).fill(false); muteMask[3] = true;
    const soloMask = Array(9).fill(true); soloMask[3] = false;
    muted.setMutedChannels(muteMask); isolated.setMutedChannels(soloMask);
    for (let i = 0; i < 2048; i++) { full.playSample(); muted.playSample(); isolated.playSample(); }
    let peak = 0;
    for (let i = 0; i < 512; i++) {
      const a = full.playSample(), b = muted.playSample(), c = isolated.playSample();
      peak = Math.max(peak, Math.abs(c)); assert(Math.abs((a - b) - c) < 1e-12);
    }
    assert(peak > 0.001); assert.equal(muted.setMutedChannels([false]), false);
    muted.setMutedChannels(Array(9).fill(false));
    for (let i = 0; i < 512; i++) assert.equal(muted.playSample(), full.playSample());
  }
});
test('mask survives seek, subtune initialization and a new engine load without hidden state reset', () => {
  const data = sid(3), a = engine(data), b = engine(data), mask = Array(9).fill(true); mask[4] = false;
  a.setMutedChannels(mask); a.seek(0.1); a.initSubtune(0); a.loadSID(data); a.initSubtune(0); a.seek(0.2);
  b.setMutedChannels(mask); b.seek(0.2);
  assert.equal(a.setMutedChannels(Array(9).fill('false')), false);
  for (let i = 0; i < 256; i++) assert.equal(a.playSample(), b.playSample());
});

test('filtered mute returns the exact continuously emulated state after unmuting', () => {
  for (const chips of [1, 2, 3]) {
    for (const model of [6581, 8580]) {
      const data = sid(chips, true), flags = model === 6581 ? 0x154 : 0x2a4;
      data[0x76] = flags >> 8; data[0x77] = flags & 255;
      const reference = engine(data), muted = engine(data);
      for (let i = 0; i < 2048; i++) { reference.playSample(); muted.playSample(); }
      const mask = Array(9).fill(false); mask[chips * 3 - 1] = true; muted.setMutedChannels(mask);
      for (let i = 0; i < 1024; i++) { reference.playSample(); muted.playSample(); }
      muted.setMutedChannels(Array(9).fill(false));
      let difference = 0;
      for (let i = 0; i < 128; i++) difference = Math.max(difference, Math.abs(reference.playSample() - muted.playSample()));
      assert.equal(difference, 0, `${chips} SID, model ${model}`);
    }
  }
});

test('filtered contributions remain independent during routing changes and complete mute', () => {
  const data = sid(3, true, true), full = engine(data), muted = engine(data), isolated = engine(data);
  for (let i = 0; i < 2048; i++) { full.playSample(); muted.playSample(); isolated.playSample(); }
  const mask = Array(9).fill(false); mask[4] = true;
  const solo = Array(9).fill(true); solo[4] = false;
  muted.setMutedChannels(mask); isolated.setMutedChannels(solo);
  for (let i = 0; i < 2048; i++) {
    const a = full.playSample(), b = muted.playSample(), c = isolated.playSample();
    assert(Math.abs(a - b - c) < 1e-12);
  }
  muted.setMutedChannels(Array(9).fill(true));
  for (let i = 0; i < 1024; i++) { full.playSample(); assert.equal(muted.playSample(), 0); }
  muted.setMutedChannels(Array(9).fill(false));
  for (let i = 0; i < 128; i++) assert.equal(muted.playSample(), full.playSample());
});
