import {sidSource} from './WebSourceSupport.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';

const source = await sidSource('sid-player-worklet.js');
function fixture() {
  // Eigenes Signal; derselbe 200-Frame-Cutoff-Schritt wie im nativen Vergleich.
  const code = [
    0xa9,0,0x8d,0,0xd4, 0xa9,12,0x8d,1,0xd4,
    0xa9,0,0x8d,5,0xd4, 0xa9,0xf0,0x8d,6,0xd4,
    0xa9,0x21,0x8d,4,0xd4, 0xa9,6,0x8d,0x15,0xd4,
    0xa9,23,0x8d,0x16,0xd4, 0xa9,1,0x8d,0x17,0xd4,
    0xa9,0x1f,0x8d,0x18,0xd4, 0xa9,0,0x8d,2,0,0x60,
    0xe6,2,0xa5,2,0xc9,200,0x90,12,0xa9,0,0x85,2,
    0xad,0x15,0xd4,0x49,1,0x8d,0x15,0xd4,0x60
  ];
  const data = new Uint8Array(124 + code.length); data.set(Buffer.from('PSID'));
  const put = (value, offset) => {data[offset] = value >> 8; data[offset + 1] = value & 255;};
  put(2,4); put(124,6); put(0x1000,8); put(0x1000,10); put(0x1033,12); put(1,14); put(1,16); put(0x14,118);
  data.set(code,124); return data;
}
function render(rate) {
  const Engine = new Function('sampleRate', source.slice(0, source.indexOf('class SidPlayerWorklet')) + ';return SidPlayerProcessor;')(rate);
  const p = new Engine(); p.loadSID(fixture()); p.initSubtune(0); p.setVolume(1);
  const pcm = Buffer.alloc(rate * 8 * 2), sums = [0,0], squares = [0,0], counts = [0,0];
  for (let frame = 0; frame < rate * 8; frame++) {
    const value = p.playSample(); assert(Number.isFinite(value));
    const sample = Math.trunc(Math.max(-1, Math.min(1, value)) * 32767); pcm.writeInt16LE(sample, frame * 2);
    const second = Math.floor(frame / rate);
    if ((second >= 1 && second < 3) || (second >= 5 && second < 7)) {
      const i = second < 4 ? 0 : 1, v = sample / 32768;
      sums[i] += v; squares[i] += v * v; counts[i]++;
    }
  }
  const rms = sums.map((sum,i) => Math.sqrt(squares[i] / counts[i] - (sum / counts[i]) ** 2));
  return {pcm, changeDB:20 * Math.log10(rms[1] / rms[0])};
}
test('44.1 kHz retains its approved PCM and 48 kHz avoids the low-cutoff level drop', () => {
  const reference = render(44100), adjusted = render(48000);
  assert.equal(createHash('md5').update(reference.pcm).digest('hex'), '96a6bebb36bf3d3756d594cc1dd96ed3');
  assert(Math.abs(adjusted.changeDB) < 0.5, `${adjusted.changeDB} dB at 48 kHz`);
  assert(Math.abs(adjusted.changeDB - reference.changeDB) < 0.02);
});

test('maximum 6581 cutoff and resonance stay finite across supported output rates', () => {
  for (const rate of [8000,22050,32000,44100,48000,96000,192000]) {
    const Engine = new Function('sampleRate', source.slice(0, source.indexOf('class SidPlayerWorklet')) + ';return SidPlayerProcessor;')(rate);
    const data = fixture(); data[124 + 5 * 5 + 1] = 7; data[124 + 6 * 5 + 1] = 255;
    const p = new Engine(); p.loadSID(data); p.initSubtune(0);
    for (let i = 0; i < 4096; i++) assert(Number.isFinite(p.playSample()), `${rate} Hz`);
  }
});
