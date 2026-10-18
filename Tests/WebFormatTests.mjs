import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { sidSource } from './WebSourceSupport.mjs';
const wrapper = await sidSource('sidplayer.js');
const { parseSidHeader, sidFileDiagnostic, SidPlayer } = await import(`data:text/javascript;base64,${Buffer.from(wrapper).toString('base64')}`);
const source = await sidSource('sid-player-worklet.js');
const Engine = new Function('sampleRate', source.slice(0, source.indexOf('class SidPlayerWorklet')) + ';return SidPlayerProcessor;')(44100);
const listening = await readFile(new URL('../src/listening.js', import.meta.url), 'utf8');
const duration = new Function(listening + ';return listeningSIDDuration;')();
const word = (data, offset, value) => { data[offset] = value >> 8; data[offset + 1] = value & 255; };
function fixture(version = 5, songs = 1, code = [0x60], tail = []) {
  const headerSize = version === 1 ? 0x76 : 0x7c, data = new Uint8Array(headerSize + code.length + tail.length);
  data.set([80,83,73,68]); word(data,4,version);word(data,6,headerSize);word(data,8,0x1000);word(data,10,0x1000);
  word(data,12,0x1000);word(data,14,songs);word(data,16,1);if(version>=2)word(data,0x76,0x14);
  data.set(code,headerSize);data.set(tail,headerSize+code.length);return data;
}
test('Windows-1252 fixed fields and nonzero-offset views work in every version', () => {
  for(const version of [1,2,3,4,5]) {
    const data=fixture(version);data.set([0x80,32,0x93,83,73,68,0x94,32,0x97,32,0x8c],0x16);
    assert.equal(parseSidHeader(data).title,'€ “SID” — Œ');
    const wrapped=new Uint8Array(data.length+17);wrapped.set(data,17);assert.equal(parseSidHeader(wrapped.subarray(17)).title,'€ “SID” — Œ');
  }
});
test('v5 variable metadata fills 96 bytes and falls back for a full old title', () => {
  const data=fixture(),title='T'.repeat(70);data.set(Buffer.from(title+'\0'+'A'.repeat(20)+'\0'+'2026'),0x16);
  assert.deepEqual([parseSidHeader(data).title,parseSidHeader(data).author,parseSidHeader(data).info],[title,'A'.repeat(20),'2026']);
  const fixed=fixture();fixed.set(Buffer.from('T'.repeat(32)),0x16);fixed.set(Buffer.from('Composer'),0x36);fixed.set(Buffer.from('2026'),0x56);
  const meta=parseSidHeader(fixed);assert.deepEqual([meta.title,meta.author,meta.info],['T'.repeat(32),'Composer','2026']);
});
test('all supported v5 address configurations use one common chip model', () => {
  const expected=[[0xd420,0xd440],[0xd440,0xd480],[0xd480,0xd500],[0xd500,0xd600],[0xd420,0xd480],[0xd420,0xd500],[0xd500,0xde00]];
  for(let layout=0;layout<=6;layout++)for(const model of [6581,8580]) {
    const data=fixture();data[0x7a]=layout*16+3;word(data,0x76,0x3c4+(model===6581?0x10:0x20));
    const meta=parseSidHeader(data);assert.deepEqual(meta.addresses.slice(1),expected[layout]);assert.deepEqual(meta.chipModels,[model,model,model]);
    const engine=new Engine();engine.loadSID(data);engine.initSubtune(0);assert.equal(engine.getChannelsData().chips.filter(Boolean).length,3);
  }
  for(const [layout,start,expected] of [[0,0x7e,[0xd7e0,0xde00]],[6,0x50,[0xd500,0xd600]],[4,0x42,[0xd420,0xd440]],[0,0x43,[0xd420,0xd440]]]) {
    const data=fixture();data[0x7a]=layout*16+3;data[0x7b]=start;assert.deepEqual(parseSidHeader(data).addresses.slice(1),expected);
  }
});

test('a blank displayed v5 title keeps the variable author and release fields', () => {
  const data=fixture();data.set(Buffer.from('   \0Composer\0Released in 2026'),0x16);
  const meta=parseSidHeader(data);assert.equal(meta.title,'');assert.equal(meta.author,'Composer');assert.equal(meta.info,'Released in 2026');
});

test('every v5 layout renders like equivalent v4 addresses on both chip models', () => {
  const layouts=[[0xd400,0xd420,0xd440],[0xd400,0xd440,0xd480],[0xd400,0xd480,0xd500],
    [0xd400,0xd500,0xd600],[0xd400,0xd420,0xd480],[0xd400,0xd420,0xd500],[0xd400,0xd500,0xde00]];
  for(const [layout,addresses] of layouts.entries())for(const model of [6581,8580]) {
    const code=[],store=(value,address)=>code.push(0xa9,value,0x8d,address&255,address>>8);
    addresses.forEach((base,chip)=>{store(0x37+chip,base);store(0x10*(chip+1),base+1);store(0,base+5);store(0xf0,base+6);store(0x21,base+4);store(15,base+24);});code.push(0x60);
    const engines=[4,5].map(version=>{
      const data=fixture(version,1,[...code,0x60]);word(data,12,0x1000+code.length);
      word(data,0x76,(model===6581?0x14:0x24)|(version===5?0x3c0:0));
      data[0x7a]=version===5?layout*16+3:(addresses[1]-0xd000)/16;data[0x7b]=version===5?0:(addresses[2]-0xd000)/16;
      const engine=new Engine();engine.loadSID(data);engine.initSubtune(0);return engine;
    });
    assert.deepEqual(engines[1].getChannelsData().chips.map(chip=>chip.frequencies[0]),[0x1037,0x2038,0x3039]);
    const actual=[],expected=[];
    for(let i=0;i<1024;i++){expected.push(engines[0].playSample());actual.push(engines[1].playSample());}
    assert.deepEqual(actual,expected,`layout ${layout}, model ${model}`);assert.ok(actual.some(value=>Math.abs(value)>0.001));
  }
});
test('embedded lengths are excluded from C64 memory and zero remains unknown', () => {
  const data=fixture(5,2,[0x60],[0x02,0x34,0x05,0x54,0,0,0,0]);word(data,0x76,0x414);
  const meta=parseSidHeader(data);assert.deepEqual(meta.embeddedSongLengths,[154.554,0]);assert.equal(duration(meta,0),154.554);assert.equal(duration(meta,1),null);
  const reads=fixture(5,1,[0xad,0x07,0x10,0x8d,0,0xd4,0x60],[0x02,0x34,0x05,0x54]);word(reads,0x76,0x414);
  const engine=new Engine();engine.loadSID(reads);engine.initSubtune(0);assert.equal(engine.getChannelsData().frequencies[0],0);
  for(const tail of [[0,0x60,0,0],[0x0a,0,0,0],[0,0,0x10,0],[0,0,0]]) {
    const bad=fixture(5,1,[0x60],tail);word(bad,0x76,0x414);assert.equal(parseSidHeader(bad),null);assert.equal(sidFileDiagnostic(bad).code,'lengths');
  }
});
test('unsupported features have concrete diagnostics and invalid layouts stay damaged', async () => {
  for(const [flags,configuration,start,code,unsupported] of [[0x14,4,0,'chips',true],[0x15,0,0,'mus',true],[0x814,0,0,'opl',true],
    [0x814,2,0xf0,'addresses',false],[0x14,0x73,0,'addresses',false],[0x14,3,0xfe,'addresses',false]]) {
    const data=fixture();word(data,0x76,flags);data[0x7a]=configuration;data[0x7b]=start;
    assert.equal(parseSidHeader(data),null);const error=sidFileDiagnostic(data);assert.equal(error.code,code);assert.equal(error.unsupported,unsupported);
    assert.throws(()=>new Engine().loadSID(data),new RegExp(error.message.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')));
  }
  const chips=fixture();chips[0x7a]=4;await assert.rejects(new SidPlayer().loadBuffer(chips),/at most 3/);
});
test('legacy odd and sparse chip slots retain the defined interpretation', () => {
  const data=fixture(4);data[0x7a]=0x43;data[0x7b]=0xe0;
  assert.deepEqual(parseSidHeader(data).activeSIDChips,[0,2]);assert.deepEqual(parseSidHeader(data).addresses,[0xd400,0,0xde00]);
  data[0x7a]=data[0x7b];assert.equal(sidFileDiagnostic(data).code,'addresses');
});
test('RSID reserved fields and BASIC need precise rejection', () => {
  for(const version of [2,5]) {
    const data=fixture(version,1,[0,8,0x60]);data.set(Buffer.from('RSID'));word(data,8,0);word(data,10,0x0800);word(data,12,0);
    assert.equal(parseSidHeader(data).isRSID,true);
    for(const field of [8,12,18]){const bad=data.slice();word(bad,field,1);assert.equal(sidFileDiagnostic(bad).code,'rsid');}
    word(data,0x76,0x16);word(data,10,0);assert.equal(sidFileDiagnostic(data).code,'basic');assert.equal(sidFileDiagnostic(data).unsupported,true);
  }
});

test('speed bits repeat for v1 and PlaySID-specific files, including loop context', () => {
  for(const [version,flags,count] of [[1,4,60],[2,4,50],[2,6,60],[3,4,50],[4,4,50],[5,4,50]]) {
    const data=fixture(version,33,[0x60,0xee,0,0xd4,0x60]);word(data,12,0x1001);data[0x15]=1;
    if(version>=2)word(data,0x76,flags|0x20);
    const engine=new Engine();engine.loadSID(data);engine.initSubtune(32);
    for(let i=0;i<44100;i++)engine.playSample();
    assert.equal(engine.getChannelsData().frequencies[0],count,`v${version}, flags ${flags}`);
  }
  const data=fixture(2,33,[0x60,0xee,0,0xd4,0x60]);word(data,12,0x1001);data[0x15]=1;word(data,0x76,0x24);
  const normal=new Engine();normal.loadSID(data);normal.initSubtune(32);normal.seek(0.2);const snapshot=normal.captureLoop(0.45);
  word(data,0x76,0x26);const specific=new Engine();specific.loadSID(data);specific.initSubtune(32);assert.equal(specific.installLoop(snapshot),false);
});

test('RSID starts with CIA interrupt timing despite reserved zero speed bits', () => {
  for (const version of [2,5]) for (const flags of [0x14,0x18]) {
    const code=[0xa9,0x20,0x8d,0x14,3,0xa9,0x10,0x8d,0x15,3,0x60];
    while(code.length<0x20)code.push(0xea);
    const data=fixture(version,1,[0,0x10,...code,0xee,0,0xd4,0x40]);
    data.set(Buffer.from('RSID'));word(data,8,0);word(data,10,0x1000);word(data,12,0);word(data,0x76,flags);
    const engine=new Engine();engine.loadSID(data);engine.initSubtune(0);
    for(let i=0;i<44100;i++)engine.playSample();
    assert.equal(engine.getChannelsData().frequencies[0],60,`RSID v${version}, flags ${flags}`);
  }
});
