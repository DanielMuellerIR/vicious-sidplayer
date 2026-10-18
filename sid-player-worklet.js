import { inspectSIDFile } from './sid-format.js';
// C64 SID Player AudioWorkletProcessor
//
// SID emulation + 6502 CPU core adapted from jsSID 0.9.1 by Hermit
// (Mihaly Horvath), 2016 — http://hermit.sidrip.com
// jsSID is released under the WTFPL ("do what the fuck you want"); the author
// asks only that the credit be kept, which this header does.

// Pure emulation engine — NOT an AudioWorkletProcessor.
// It used to "extends AudioWorkletProcessor", but the browser only allows the
// audio system to construct AudioWorkletProcessor subclasses. Since this class
// is instantiated manually (new SidPlayerProcessor() inside SidPlayerWorklet),
// extending the base threw "an error thrown from AudioWorkletProcessor
// constructor" at construction time — the whole processor died, so there was no
// sound and no visualizer data. As a plain class it constructs fine. It still
// reads the worklet-global `sampleRate`, which is available everywhere in the
// AudioWorkletGlobalScope regardless of inheritance.
class SidPlayerProcessor {
  constructor() {
    // Instance-isolated engine state to support multiple panels or reload cycles cleanly
    let samplerate = sampleRate;
    
    let clockMode = 'auto';
    let fileClock = 0;
    let clock = 'pal';
    let cpuClock = 985248;
    let frameRate = 50;
    let defaultCIATimer = 0x4025;
    let usesCIATimer = false;
    let SID_CHANNEL_AMOUNT = 3;
    let OUTPUT_SCALEDOWN = 0x10000 * SID_CHANNEL_AMOUNT * 16;
    
    let SIDamount_vol = [0, 1, 0.6, 0.4];
    
    let timermode = new Uint8Array(0x20);
    
    let loadaddr = 0x1000;
    let initaddr = 0x1000;
    let playaddf = 0x1003;
    let playaddr = 0x1003;
    let subtune = 0;
    let subtune_amount = 1;

    let repeatedSpeedBits = false;
    // V1 und PlaySID-spezifische Dateien wiederholen die 32 Bits; die übrigen
    // PSID-Versionen verwenden Bit31 für alle weiteren Subtunes.
    function timerModeForSubtune() {
      return timermode[repeatedSpeedBits ? subtune % 32 : Math.min(subtune, 31)];
    }

    let preferred_SID_model = [8580.0, 8580.0, 8580.0];
    let SID_model = 8580.0;
    let SID_address = [0xD400, 0, 0];
    let memory = new Uint8Array(65536);
    let loadedMemory = new Uint8Array(65536);
    
    let loaded = 0;
    let initialized = 0;
    let finished = 0;
    let playtime = 0;
    let renderedSamples = 0;
    let preparedLoop = null;
    let seekRemaining = 0;

    let clk_ratio = cpuClock / samplerate;
    let frame_sampleperiod = samplerate / frameRate;
    
    let framecnt = 1;
    let volume = 1.0;
    let CPUtime = 0;
    let pPC = 0;
    let SIDamount = 1;
    const voiceMuted = Array(9).fill(false);
    let mix = 0;
    
    // CPU Registers
    let PC = 0;
    let A = 0;
    let T = 0;
    let X = 0;
    let Y = 0;
    let SP = 0xFF;
    let IR = 0;
    let addr = 0;
    let ST = 0x00; // status flags: N V - B D I Z C
    let cycles = 0;
    let storadd = 0;
    
    // CPU constants
    const flagsw = [0x01, 0x21, 0x04, 0x24, 0x00, 0x40, 0x08, 0x28];
    const branchflag = [0x80, 0x40, 0x01, 0x02];
    
    // SID constants
    const GATE_BITMASK = 0x01;
    const SYNC_BITMASK = 0x02;
    const RING_BITMASK = 0x04;
    const TEST_BITMASK = 0x08;
    const TRI_BITMASK = 0x10;
    const SAW_BITMASK = 0x20;
    const PULSE_BITMASK = 0x40;
    const NOISE_BITMASK = 0x80;
    const HOLDZERO_BITMASK = 0x10;
    const DECAYSUSTAIN_BITMASK = 0x40;
    const ATTACK_BITMASK = 0x80;
    const FILTSW = [1, 2, 4, 1, 2, 4, 1, 2, 4];
    const LOWPASS_BITMASK = 0x10;
    const BANDPASS_BITMASK = 0x20;
    const HIGHPASS_BITMASK = 0x40;
    const OFF3_BITMASK = 0x80;
    
    let ADSRstate = [0, 0, 0, 0, 0, 0, 0, 0, 0];
    let ratecnt = [0, 0, 0, 0, 0, 0, 0, 0, 0];
    let envcnt = [0, 0, 0, 0, 0, 0, 0, 0, 0];
    let expcnt = [0, 0, 0, 0, 0, 0, 0, 0, 0];
    let prevSR = [0, 0, 0, 0, 0, 0, 0, 0, 0];
    let phaseaccu = [0, 0, 0, 0, 0, 0, 0, 0, 0];
    let prevaccu = [0, 0, 0, 0, 0, 0, 0, 0, 0];
    let sourceMSBrise = [0, 0, 0];
    let sourceMSB = [0, 0, 0];
    let noise_LFSR = [0x7FFFF8, 0x7FFFF8, 0x7FFFF8, 0x7FFFF8, 0x7FFFF8, 0x7FFFF8, 0x7FFFF8, 0x7FFFF8, 0x7FFFF8];
    let prevwfout = [0, 0, 0, 0, 0, 0, 0, 0, 0];
    let prevwavdata = [0, 0, 0, 0, 0, 0, 0, 0, 0];
    let combiwf = 0;
    let prevlowpass = [0, 0, 0];
    let prevbandpass = [0, 0, 0];
    let voiceLowpass = Array(9).fill(0);
    let voiceBandpass = Array(9).fill(0);
    
    let cutoff_ratio_8580 = -2 * Math.PI * (12500 / 256) / samplerate;
    let cutoff_ratio_6581 = -2 * Math.PI * (20000 / 256) / samplerate;
    
    // Wave calculations variables
    let prevgate, chnadd, ctrl, wf, test, period, step, SR, accuadd, MSB, tmp, pw, lim, wfout, cutoff, resonance, filtin, output;
    
    // Precalculated tables
    let TriSaw_8580 = new Array(4096);
    let PulseSaw_8580 = new Array(4096);
    let PulseTriSaw_8580 = new Array(4096);
    
    let period0 = Math.max(clk_ratio, 9);
    let ADSRperiods = [
      period0, 32 * 1, 63 * 1, 95 * 1, 149 * 1, 220 * 1, 267 * 1, 313 * 1,
      392 * 1, 977 * 1, 1954 * 1, 3126 * 1, 3907 * 1, 11720 * 1, 19532 * 1, 31251 * 1
    ];
    let ADSRstep = [Math.ceil(period0 / 9), 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1];
    let ADSR_exptable = [
      1, 30, 30, 30, 30, 30, 30, 16, 16, 16, 16, 16, 16, 16, 16, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 4, 4, 4, 4, 4,
      4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
      2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
      1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
      1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
      1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
      1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
      1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
      1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
    ];

    function createCombinedWF(wfarray, bitmul, bitstrength, treshold) {
      for (let i = 0; i < 4096; i++) {
        wfarray[i] = 0;
        for (let j = 0; j < 12; j++) {
          let bitlevel = 0;
          for (let k = 0; k < 12; k++) {
            bitlevel += (bitmul / Math.pow(bitstrength, Math.abs(k - j))) * (((i >> k) & 1) - 0.5);
          }
          wfarray[i] += bitlevel >= treshold ? Math.pow(2, j) : 0;
        }
        wfarray[i] *= 12;
      }
    }
    
    // Populate combined waves tables
    createCombinedWF(TriSaw_8580, 0.8, 2.4, 0.64);
    createCombinedWF(PulseSaw_8580, 1.4, 1.9, 0.68);
    createCombinedWF(PulseTriSaw_8580, 0.8, 2.5, 0.64);

    function initCPU(mempos) {
      PC = mempos;
      A = 0;
      X = 0;
      Y = 0;
      ST = 0;
      SP = 0xFF;
    }

    function initSID() {
      for (let i = 0xD400; i <= 0xD7FF; i++) memory[i] = 0;
      for (let i = 0xDE00; i <= 0xDFFF; i++) memory[i] = 0;
      for (let i = 0; i < 9; i++) {
        ADSRstate[i] = HOLDZERO_BITMASK;
        ratecnt[i] = envcnt[i] = expcnt[i] = prevSR[i] = 0;
        phaseaccu[i] = prevaccu[i] = prevwfout[i] = prevwavdata[i] = 0;
        noise_LFSR[i] = 0x7FFFF8;
      }
      sourceMSB = [0, 0, 0];
      sourceMSBrise = [0, 0, 0];
      prevlowpass = [0, 0, 0];
      prevbandpass = [0, 0, 0];
      voiceLowpass = Array(9).fill(0);
      voiceBandpass = Array(9).fill(0);
    }

    function init(subt) {
      if (loaded) {
        initialized = 0;
        // Init kann RAM veraendern; Seek und Subtune beginnen beim Ladeabbild.
        memory.set(loadedMemory);
        subtune = subt;
        initCPU(initaddr);
        initSID();

        A = subtune;
        memory[1] = 0x37;
        memory[0x02A6] = clock === 'pal' ? 1 : 0;
        memory[0xDC04] = defaultCIATimer & 255;
        memory[0xDC05] = defaultCIATimer >> 8;
        usesCIATimer = !!timerModeForSubtune();

        for (let timeout = 100000; timeout >= 0; timeout--) {
          const result = CPU();
          if ((storadd === 0xDC04 || storadd === 0xDC05) && (memory[1] & 3)) usesCIATimer = true;
          if (result >= 0xFE) break;
        }

        if (usesCIATimer) {
          frame_sampleperiod = (memory[0xDC04] + memory[0xDC05] * 256 + 1) / clk_ratio;
        } else {
          frame_sampleperiod = samplerate / frameRate;
        }

        if (playaddf == 0) {
          playaddr = ((memory[1] & 3) < 2)
            ? memory[0xFFFE] + memory[0xFFFF] * 256
            : memory[0x314] + memory[0x315] * 256;
        } else {
          playaddr = playaddf;
          if (playaddr >= 0xE000 && memory[1] == 0x37) memory[1] = 0x35;
        }

        initCPU(playaddr);
        framecnt = 1;
        finished = 0;
        CPUtime = 0;
        playtime = 0;
        renderedSamples = 0;
        preparedLoop = null;
        initialized = 1;
      }
    }

    function CPU() {
      IR = memory[PC];
      cycles = 2;
      storadd = 0;

      if (IR & 1) {
        switch (IR & 0x1F) {
          case 1: case 3: addr = memory[(memory[++PC] + X) & 0xFF] + memory[(memory[PC] + X + 1) & 0xFF] * 256; cycles = 6; break;
          case 0x11: case 0x13: addr = memory[memory[++PC]] + memory[(memory[PC] + 1) & 0xFF] * 256 + Y; cycles = 6; break;
          case 0x19: case 0x1F: addr = memory[++PC] + memory[++PC] * 256 + Y; cycles = 5; break;
          case 0x1D: addr = memory[++PC] + memory[++PC] * 256 + X; cycles = 5; break;
          case 0xD: case 0xF: addr = memory[++PC] + memory[++PC] * 256; cycles = 4; break;
          case 0x15: addr = (memory[++PC] + X) & 0xFF; cycles = 4; break;
          case 5: case 7: addr = memory[++PC]; cycles = 3; break;
          case 0x17: addr = (memory[++PC] + Y) & 0xFF; cycles = 4; break;
          case 9: case 0xB: addr = ++PC; cycles = 2;
        }

        addr &= 0xFFFF;
        switch (IR & 0xE0) {
          case 0x60: T = A; A += memory[addr] + (ST & 1); ST &= 20; ST |= (A & 128) | (A > 255); A &= 0xFF; ST |= (!A) << 1 | (!((T ^ memory[addr]) & 0x80) && ((T ^ A) & 0x80)) >> 1; break;
          case 0xE0: T = A; A -= memory[addr] + !(ST & 1); ST &= 20; ST |= (A & 128) | (A >= 0); A &= 0xFF; ST |= (!A) << 1 | (((T ^ memory[addr]) & 0x80) && ((T ^ A) & 0x80)) >> 1; break;
          case 0xC0: T = A - memory[addr]; ST &= 124; ST |= (!(T & 0xFF)) << 1 | (T & 128) | (T >= 0); break;
          case 0x00: A |= memory[addr]; ST &= 125; ST |= (!A) << 1 | (A & 128); break;
          case 0x20: A &= memory[addr]; ST &= 125; ST |= (!A) << 1 | (A & 128); break;
          case 0x40: A ^= memory[addr]; ST &= 125; ST |= (!A) << 1 | (A & 128); break;
          case 0xA0: A = memory[addr]; ST &= 125; ST |= (!A) << 1 | (A & 128); if ((IR & 3) == 3) X = A; break;
          case 0x80: memory[addr] = A & (((IR & 3) == 3) ? X : 0xFF); storadd = addr;
        }
      } else if (IR & 2) {
        switch (IR & 0x1F) {
          case 0x1E: addr = memory[++PC] + memory[++PC] * 256 + (((IR & 0xC0) != 0x80) ? X : Y); cycles = 5; break;
          case 0xE: addr = memory[++PC] + memory[++PC] * 256; cycles = 4; break;
          case 0x16: addr = (memory[++PC] + (((IR & 0xC0) != 0x80) ? X : Y)) & 0xFF; cycles = 4; break;
          case 6: addr = memory[++PC]; cycles = 3; break;
          case 2: addr = ++PC; cycles = 2;
        }
        addr &= 0xFFFF;
        switch (IR & 0xE0) {
          case 0x00: ST &= 0xFE; case 0x20: if ((IR & 0xF) == 0xA) { A = (A << 1) + (ST & 1); ST &= 60; ST |= (A & 128) | (A > 255); A &= 0xFF; ST |= (!A) << 1; }
            else { T = (memory[addr] << 1) + (ST & 1); ST &= 60; ST |= (T & 128) | (T > 255); T &= 0xFF; ST |= (!T) << 1; memory[addr] = T; cycles += 2; } break;
          case 0x40: ST &= 0xFE; case 0x60: if ((IR & 0xF) == 0xA) { T = A; A = (A >> 1) + (ST & 1) * 128; ST &= 60; ST |= (A & 128) | (T & 1); A &= 0xFF; ST |= (!A) << 1; }
            else { T = (memory[addr] >> 1) + (ST & 1) * 128; ST &= 60; ST |= (T & 128) | (memory[addr] & 1); T &= 0xFF; ST |= (!T) << 1; memory[addr] = T; cycles += 2; } break;
          case 0xC0: if (IR & 4) { memory[addr]--; memory[addr] &= 0xFF; ST &= 125; ST |= (!memory[addr]) << 1 | (memory[addr] & 128); cycles += 2; }
            else { X--; X &= 0xFF; ST &= 125; ST |= (!X) << 1 | (X & 128); } break;
          case 0xA0: if ((IR & 0xF) != 0xA) X = memory[addr]; else if (IR & 0x10) { X = SP; break; } else X = A; ST &= 125; ST |= (!X) << 1 | (X & 128); break;
          case 0x80: if (IR & 4) { memory[addr] = X; storadd = addr; } else if (IR & 0x10) SP = X; else { A = X; ST &= 125; ST |= (!A) << 1 | (A & 128); } break;
          case 0xE0: if (IR & 4) { memory[addr]++; memory[addr] &= 0xFF; ST &= 125; ST |= (!memory[addr]) << 1 | (memory[addr] & 128); cycles += 2; }
        }
      } else if ((IR & 0xC) == 8) {
        // Single-byte "implied" instructions (column 8 of the opcode table):
        // stack ops, register transfers, register inc/dec and the flag ops.
        //
        // IMPORTANT: we MUST switch on the WHOLE high nibble (IR & 0xF0), not on
        // (IR & 0xC0). Every opcode here is uniquely identified by its high nibble
        // (e.g. INX=0xE8 -> 0xE0, TAY=0xA8 -> 0xA0). Masking with 0xC0 collapses
        // distinct opcodes onto the same case: INX (0xE8 & 0xC0 = 0xC0) lands in
        // the same bucket as INY/TAY and silently does nothing, TAY (0xA8 & 0xC0 =
        // 0x80) collides with DEY/TYA, and PHP/PLP (& 0xC0 = 0x00) fall through to
        // the flag-op default and corrupt the status register + stack. Player
        // routines lean on INX/TAY/PHP/PLP for indexed sequence reads and loop
        // counters, so getting these wrong freezes the song (constant drone or
        // silence). Switching on 0xF0 — exactly like the reference jsSID — fixes it.
        switch (IR & 0xF0) {
          case 0x60: SP++; SP &= 0xFF; A = memory[0x100 + SP]; ST &= 125; ST |= (!A) << 1 | (A & 128); cycles = 4; break; // PLA (0x68)
          case 0xC0: Y++; Y &= 0xFF; ST &= 125; ST |= (!Y) << 1 | (Y & 128); break; // INY (0xC8)
          case 0xE0: X++; X &= 0xFF; ST &= 125; ST |= (!X) << 1 | (X & 128); break; // INX (0xE8)
          case 0x80: Y--; Y &= 0xFF; ST &= 125; ST |= (!Y) << 1 | (Y & 128); break; // DEY (0x88)
          case 0x00: memory[0x100 + SP] = ST; SP--; SP &= 0xFF; cycles = 3; break; // PHP (0x08)
          case 0x20: SP++; SP &= 0xFF; ST = memory[0x100 + SP]; cycles = 4; break; // PLP (0x28)
          case 0x40: memory[0x100 + SP] = A; SP--; SP &= 0xFF; cycles = 3; break; // PHA (0x48)
          case 0x90: A = Y; ST &= 125; ST |= (!A) << 1 | (A & 128); break; // TYA (0x98)
          case 0xA0: Y = A; ST &= 125; ST |= (!Y) << 1 | (Y & 128); break; // TAY (0xA8)
          default: // flag ops: CLC/SEC/CLI/SEI/CLV/CLD/SED (0x18/0x38/0x58/0x78/0xB8/0xD8/0xF8)
            if (flagsw[IR >> 5] & 0x20) ST |= (flagsw[IR >> 5] & 0xDF);
            else ST &= 255 - (flagsw[IR >> 5] & 0xDF);
        }
      } else {
        if ((IR & 0x1F) == 0x10) {
          PC++; T = memory[PC]; if (T & 0x80) T -= 0x100;
          if (IR & 0x20) { if (ST & branchflag[IR >> 6]) { PC += T; cycles = 3; } }
          else { if (!(ST & branchflag[IR >> 6])) { PC += T; cycles = 3; } }
        } else {
          switch (IR & 0x1F) {
            case 0: addr = ++PC; cycles = 2; break;
            case 0x1C: addr = memory[++PC] + memory[++PC] * 256 + X; cycles = 5; break;
            case 0xC: addr = memory[++PC] + memory[++PC] * 256; cycles = 4; break;
            case 0x14: addr = (memory[++PC] + X) & 0xFF; cycles = 4; break;
            case 4: addr = memory[++PC]; cycles = 3;
          }
          addr &= 0xFFFF;
          switch (IR & 0xE0) {
            case 0x00: memory[0x100 + SP] = PC % 256; SP--; SP &= 0xFF; memory[0x100 + SP] = PC / 256; SP--; SP &= 0xFF; memory[0x100 + SP] = ST; SP--; SP &= 0xFF;
              PC = memory[0xFFFE] + memory[0xFFFF] * 256 - 1; cycles = 7; break;
            case 0x20: if (IR & 0xF) { ST &= 0x3D; ST |= (memory[addr] & 0xC0) | (!(A & memory[addr])) << 1; }
              else { memory[0x100 + SP] = (PC + 2) % 256; SP--; SP &= 0xFF; memory[0x100 + SP] = (PC + 2) / 256; SP--; SP &= 0xFF; PC = memory[addr] + memory[addr + 1] * 256 - 1; cycles = 6; } break;
            case 0x40: if (IR & 0xF) { PC = addr - 1; cycles = 3; }
              else { if (SP >= 0xFF) return 0xFE; SP++; SP &= 0xFF; ST = memory[0x100 + SP]; SP++; SP &= 0xFF; T = memory[0x100 + SP]; SP++; SP &= 0xFF; PC = memory[0x100 + SP] + T * 256 - 1; cycles = 6; } break;
            case 0x60: if (IR & 0xF) { PC = memory[addr] + memory[addr + 1] * 256 - 1; cycles = 5; }
              else { if (SP >= 0xFF) return 0xFF; SP++; SP &= 0xFF; T = memory[0x100 + SP]; SP++; SP &= 0xFF; PC = memory[0x100 + SP] + T * 256 - 1; cycles = 6; } break;
            case 0xC0: T = Y - memory[addr]; ST &= 124; ST |= (!(T & 0xFF)) << 1 | (T & 128) | (T >= 0); break;
            case 0xE0: T = X - memory[addr]; ST &= 124; ST |= (!(T & 0xFF)) << 1 | (T & 128) | (T >= 0); break;
            case 0xA0: Y = memory[addr]; ST &= 125; ST |= (!Y) << 1 | (Y & 128); break;
            case 0x80: memory[addr] = Y; storadd = addr;
          }
        }
      }

      PC++;
      PC &= 0xFFFF;
      return 0;
    }

    function combinedWF(channel, wfarray, index, differ6581) {
      if (differ6581 && SID_model == 6581.0) index &= 0x7FF;
      combiwf = (wfarray[index] + prevwavdata[channel]) / 2;
      prevwavdata[channel] = wfarray[index];
      return combiwf;
    }

    function SID_core(num, SIDaddr) {
      SID_model = preferred_SID_model[num];
      filtin = 0;
      output = 0;
      let mutedFilterOutput = 0, allMuted = true;

      // Gemeinsame Filterparameter aller Stimmen dieses Chips.
      cutoff = (memory[SIDaddr + 0x15] & 7) / 8 + memory[SIDaddr + 0x16] + 0.2;
      if (SID_model == 8580.0) {
        cutoff = 1 - Math.exp(cutoff * cutoff_ratio_8580);
        resonance = Math.pow(2, ((4 - (memory[SIDaddr + 0x17] >> 4)) / 8));
      } else {
        if (cutoff < 24) cutoff = 0.035;
        else cutoff = 1 - 1.263 * Math.exp(cutoff * cutoff_ratio_6581);
        resonance = (memory[SIDaddr + 0x17] > 0x5F) ? 8 / (memory[SIDaddr + 0x17] >> 4) : 1.41;
      }

      for (let channel = num * SID_CHANNEL_AMOUNT; channel < (num + 1) * SID_CHANNEL_AMOUNT; channel++) {
        prevgate = (ADSRstate[channel] & GATE_BITMASK);
        chnadd = SIDaddr + (channel - num * SID_CHANNEL_AMOUNT) * 7;
        ctrl = memory[chnadd + 4];
        wf = ctrl & 0xF0;
        test = ctrl & TEST_BITMASK;
        SR = memory[chnadd + 6];
        tmp = 0;

        // ADSR Envelope
        if (prevgate != (ctrl & GATE_BITMASK)) {
          if (prevgate) {
            ADSRstate[channel] &= 0xFF - (GATE_BITMASK | ATTACK_BITMASK | DECAYSUSTAIN_BITMASK);
          } else {
            ADSRstate[channel] = (GATE_BITMASK | ATTACK_BITMASK | DECAYSUSTAIN_BITMASK);
            if ((SR & 0xF) > (prevSR[channel] & 0xF)) tmp = 1;
          }
        }
        prevSR[channel] = SR;

        ratecnt[channel] += clk_ratio;
        if (ratecnt[channel] >= 0x8000) ratecnt[channel] -= 0x8000;

        if (ADSRstate[channel] & ATTACK_BITMASK) {
          step = memory[chnadd + 5] >> 4; period = ADSRperiods[step];
        } else if (ADSRstate[channel] & DECAYSUSTAIN_BITMASK) {
          step = memory[chnadd + 5] & 0xF; period = ADSRperiods[step];
        } else {
          step = SR & 0xF; period = ADSRperiods[step];
        }

        step = ADSRstep[step];

        if (ratecnt[channel] >= period && ratecnt[channel] < period + clk_ratio && tmp == 0) {
          ratecnt[channel] -= period;
          if ((ADSRstate[channel] & ATTACK_BITMASK) || ++expcnt[channel] == ADSR_exptable[envcnt[channel]]) {
            if (!(ADSRstate[channel] & HOLDZERO_BITMASK)) {
              if (ADSRstate[channel] & ATTACK_BITMASK) {
                envcnt[channel] += step;
                if (envcnt[channel] >= 0xFF) {
                  envcnt[channel] = 0xFF;
                  ADSRstate[channel] &= 0xFF - ATTACK_BITMASK;
                }
              } else if (!(ADSRstate[channel] & DECAYSUSTAIN_BITMASK) || envcnt[channel] > (SR >> 4) + (SR & 0xF0)) {
                envcnt[channel] -= step;
                if (envcnt[channel] <= 0 && envcnt[channel] + step != 0) {
                  envcnt[channel] = 0;
                  ADSRstate[channel] |= HOLDZERO_BITMASK;
                }
              }
            }
            expcnt[channel] = 0;
          }
        }
        envcnt[channel] &= 0xFF;

        // Waveform Generator
        accuadd = (memory[chnadd] + memory[chnadd + 1] * 256) * clk_ratio;
        if (test || ((ctrl & SYNC_BITMASK) && sourceMSBrise[num])) {
          phaseaccu[channel] = 0;
        } else {
          phaseaccu[channel] += accuadd;
          if (phaseaccu[channel] > 0xFFFFFF) phaseaccu[channel] -= 0x1000000;
        }
        MSB = phaseaccu[channel] & 0x800000;
        sourceMSBrise[num] = (MSB > (prevaccu[channel] & 0x800000)) ? 1 : 0;

        if (wf & NOISE_BITMASK) {
          tmp = noise_LFSR[channel];
          if (((phaseaccu[channel] & 0x100000) != (prevaccu[channel] & 0x100000)) || accuadd >= 0x100000) {
            step = (tmp & 0x400000) ^ ((tmp & 0x20000) << 5);
            tmp = ((tmp << 1) + (step > 0 || test)) & 0x7FFFFF;
            noise_LFSR[channel] = tmp;
          }
          // Map the LFSR bits to the 12-bit noise output. The 2nd term must be
          // ((tmp & 0x40000) >> 4): a copy-paste slip had duplicated the 0x4000
          // term and dropped the 0x40000 bit, distorting the noise timbre (drums).
          wfout = (wf & 0x70) ? 0 : ((tmp & 0x100000) >> 5) + ((tmp & 0x40000) >> 4) + ((tmp & 0x4000) >> 1) + ((tmp & 0x800) << 1) + ((tmp & 0x200) << 2) + ((tmp & 0x20) << 5) + ((tmp & 0x04) << 7) + ((tmp & 0x01) << 8);
        } else if (wf & PULSE_BITMASK) {
          pw = (memory[chnadd + 2] + (memory[chnadd + 3] & 0xF) * 256) * 16;
          tmp = accuadd >> 9;
          if (0 < pw && pw < tmp) pw = tmp;
          tmp ^= 0xFFFF;
          if (pw > tmp) pw = tmp;
          tmp = phaseaccu[channel] >> 8;
          if (wf == PULSE_BITMASK) {
            step = 256 / (accuadd >> 16);
            if (test) wfout = 0xFFFF;
            else if (tmp < pw) {
              lim = (0xFFFF - pw) * step; if (lim > 0xFFFF) lim = 0xFFFF;
              wfout = lim - (pw - tmp) * step; if (wfout < 0) wfout = 0;
            } else {
              lim = pw * step; if (lim > 0xFFFF) lim = 0xFFFF;
              wfout = (0xFFFF - tmp) * step - lim; if (wfout >= 0) wfout = 0xFFFF; wfout &= 0xFFFF;
            }
          } else {
            wfout = (tmp >= pw || test) ? 0xFFFF : 0;
            if (wf & TRI_BITMASK) {
              if (wf & SAW_BITMASK) {
                wfout = wfout ? combinedWF(channel, PulseTriSaw_8580, tmp >> 4, 1) : 0;
              } else {
                tmp = phaseaccu[channel] ^ (ctrl & RING_BITMASK ? sourceMSB[num] : 0);
                wfout = wfout ? combinedWF(channel, PulseSaw_8580, (tmp ^ (tmp & 0x800000 ? 0xFFFFFF : 0)) >> 11, 0) : 0;
              }
            } else if (wf & SAW_BITMASK) {
              wfout = wfout ? combinedWF(channel, PulseSaw_8580, tmp >> 4, 1) : 0;
            }
          }
        } else if (wf & SAW_BITMASK) {
          wfout = phaseaccu[channel] >> 8;
          if (wf & TRI_BITMASK) {
            wfout = combinedWF(channel, TriSaw_8580, wfout >> 4, 1);
          } else {
            step = accuadd / 0x1200000;
            wfout += wfout * step;
            if (wfout > 0xFFFF) wfout = 0xFFFF - (wfout - 0x10000) / step;
          }
        } else if (wf & TRI_BITMASK) {
          tmp = phaseaccu[channel] ^ (ctrl & RING_BITMASK ? sourceMSB[num] : 0);
          wfout = (tmp ^ (tmp & 0x800000 ? 0xFFFFFF : 0)) >> 7;
        }

        if (wf) prevwfout[channel] = wfout; else wfout = prevwfout[channel];
        prevaccu[channel] = phaseaccu[channel];
        sourceMSB[num] = MSB;

        const signal = (wfout - 0x8000) * (envcnt[channel] / 256);
        const routed = !!(memory[SIDaddr + 0x17] & FILTSW[channel]);
        const input = routed ? signal : 0;
        filtin += input;
        // Lineare Filterbeiträge bleiben auch bei Mute und Routingwechsel warm.
        // Der volle Chipfilter rechnet unverändert; Mute zieht erst am Ausgang ab.
        const voiceHighpass = input + voiceBandpass[channel] * resonance + voiceLowpass[channel];
        const voiceNextBandpass = voiceBandpass[channel] - voiceHighpass * cutoff;
        const voiceNextLowpass = voiceLowpass[channel] + voiceNextBandpass * cutoff;
        voiceBandpass[channel] = voiceNextBandpass;
        voiceLowpass[channel] = voiceNextLowpass;
        if (voiceMuted[channel]) {
          if (memory[SIDaddr + 0x18] & HIGHPASS_BITMASK) mutedFilterOutput -= voiceHighpass;
          if (memory[SIDaddr + 0x18] & BANDPASS_BITMASK) mutedFilterOutput -= voiceNextBandpass;
          if (memory[SIDaddr + 0x18] & LOWPASS_BITMASK) mutedFilterOutput += voiceNextLowpass;
        } else {
          allMuted = false;
          if (!routed && ((channel % SID_CHANNEL_AMOUNT) != 2 || !(memory[SIDaddr + 0x18] & OFF3_BITMASK))) output += signal;
        }
      }

      // Update the two read-only SID registers some players poll.
      // OSC3 ($D41B) only mirrors the RAM-mapped SID while it is banked in
      // (memory[1] & 3), but ENV3 ($D41C) is updated unconditionally — this
      // matches the reference jsSID, where only the OSC3 line was guarded.
      if (memory[1] & 3) memory[SIDaddr + 0x1B] = wfout >> 8;
      // ENV3 ($D41C) spiegelt die Huellkurve der dritten Stimme DIESES SIDs.
      // Frueher stand hier fest envcnt[3] — das ist Stimme 0 von SID 1 und fuer
      // Single-SID-Tunes immer 0. Korrekt ist der Voice-3-Index des aktuellen
      // SIDs: startChannel + 2 (envcnt[2]/[5]/[8]), analog zum Swift-Port.
      memory[SIDaddr + 0x1C] = envcnt[num * SID_CHANNEL_AMOUNT + 2];

      tmp = filtin + prevbandpass[num] * resonance + prevlowpass[num];
      if (memory[SIDaddr + 0x18] & HIGHPASS_BITMASK) output -= tmp;
      tmp = prevbandpass[num] - tmp * cutoff;
      prevbandpass[num] = tmp;
      if (memory[SIDaddr + 0x18] & BANDPASS_BITMASK) output -= tmp;
      tmp = prevlowpass[num] + tmp * cutoff;
      prevlowpass[num] = tmp;
      if (memory[SIDaddr + 0x18] & LOWPASS_BITMASK) output += tmp;

      output -= mutedFilterOutput;
      // Vollständiges Mute entfernt auch mögliche Rundungsreste.
      if (allMuted) output = 0;
      return (output / OUTPUT_SCALEDOWN) * (memory[SIDaddr + 0x18] & 0xF);
    }

    function play() {
      if (loaded && initialized) {
        if (preparedLoop && (renderedSamples < preparedLoop.state.renderedSamples || renderedSamples >= preparedLoop.endSample)) restoreSnapshot(preparedLoop.state);
        framecnt--;
        playtime += 1 / samplerate;
        renderedSamples++;

        if (framecnt <= 0) {
          framecnt = frame_sampleperiod;
          finished = 0;
          PC = playaddr;
          SP = 0xFF;
        }

        if (finished == 0) {
          while (CPUtime <= clk_ratio) {
            pPC = PC;
            let cpuResult = CPU();
            if (cpuResult >= 0xFE) {
              finished = 1;
              break;
            } else {
              CPUtime += cycles;
            }

            if ((memory[1] & 3) > 1 && pPC < 0xE000 && (PC == 0xEA31 || PC == 0xEA81)) {
              finished = 1;
              break;
            }
            if ((storadd == 0xDC05 || storadd == 0xDC04) && (memory[1] & 3) && usesCIATimer) {
              frame_sampleperiod = (memory[0xDC04] + memory[0xDC05] * 256 + 1) / clk_ratio;
            }
            if (storadd >= 0xD420 && storadd < 0xD800 && (memory[1] & 3)) {
              if (!(SID_address[1] <= storadd && storadd < SID_address[1] + 0x1F) &&
                  !(SID_address[2] <= storadd && storadd < SID_address[2] + 0x1F)) {
                memory[storadd & 0xD41F] = memory[storadd];
              }
            }
            // Whitaker / Whittaker workaround
            if (addr == 0xD404 && !(memory[0xD404] & 1)) ADSRstate[0] &= 0x3E;
            if (addr == 0xD40B && !(memory[0xD40B] & 1)) ADSRstate[1] &= 0x3E;
            if (addr == 0xD412 && !(memory[0xD412] & 1)) ADSRstate[2] &= 0x3E;
          }
          CPUtime -= clk_ratio;
        }
      }

      mix = SID_core(0, 0xD400);
      if (SID_address[1]) mix += SID_core(1, SID_address[1]);
      if (SID_address[2]) mix += SID_core(2, SID_address[2]);

      return mix * volume * SIDamount_vol[SIDamount];
    }

    // Expose API
    this.playSample = play;
    
    this.loadSID = function(filedata) {
      const inspection = inspectSIDFile(filedata);
      if (inspection.error) throw new Error(inspection.error.message);
      const meta = inspection.header;
      loaded = 0;
      initialized = 0;
      preparedLoop = null;
      initSID();
      loadaddr = meta.loadAddr;
      initaddr = meta.initAddr;
      playaddr = playaddf = meta.playAddr;
      subtune_amount = meta.subtunesCount;
      repeatedSpeedBits = meta.usesRepeatedSpeedBits;
      // RSID reserviert die Speed-Bits als null, startet aber mit CIA-IRQ.
      for (let i = 0; i < 32; i++) timermode[i] = meta.isRSID || meta.timermodes[i] ? 1 : 0;
      memory.fill(0);
      // Der v5-Längenanhang gehört nicht zum C64-Programm.
      for (let i = meta.binaryOffset; i < meta.binaryEnd; i++) {
        if (loadaddr + i - meta.binaryOffset < memory.length) memory[loadaddr + i - meta.binaryOffset] = filedata[i];
      }
      loadedMemory.set(memory);
      fileClock = ['unknown', 'pal', 'ntsc', 'both'].indexOf(meta.clockPreference);
      applyClock();
      preferred_SID_model = meta.chipModels.slice();
      SID_address = meta.addresses.slice();
      SIDamount = meta.activeSIDChips.length;
      loaded = 1;
      return meta;
    };
    
    this.initSubtune = function(subt) {
      init(subt);
    };

    function applyClock() {
      clock = clockMode === 'auto' ? (fileClock === 2 ? 'ntsc' : 'pal') : clockMode;
      cpuClock = clock === 'pal' ? 985248 : 1022727;
      frameRate = clock === 'pal' ? 50 : 60;
      defaultCIATimer = clock === 'pal' ? 0x4025 : 0x4295;
      clk_ratio = cpuClock / samplerate;
      ADSRperiods[0] = Math.max(clk_ratio, 9);
      ADSRstep[0] = Math.ceil(ADSRperiods[0] / 9);
    }

    this.setClockMode = function(mode) {
      clockMode = ['pal', 'ntsc'].includes(mode) ? mode : 'auto';
      applyClock();
      if (loaded) this.beginSeek(playtime + seekRemaining / samplerate);
    };
    
    this.setVolume = function(vol) {
      volume = vol;
    };

    this.setMutedChannels = function(muted) {
      if (!Array.isArray(muted) || muted.length !== 9 || !muted.every(value => typeof value === 'boolean')) return false;
      preparedLoop = null;
      for (let channel = 0; channel < 9; channel++) voiceMuted[channel] = muted[channel];
      return true;
    };

    // ENV3/OSC3 wirken auf die CPU zurueck; Seek rekonstruiert echte Samples.
    // Das Worklet arbeitet in begrenzten Portionen, damit neue Befehle auch
    // waehrend eines langen Sprungs bearbeitet werden koennen.
    this.beginSeek = function(seconds) {
      if (!loaded) return;
      const target = Number.isFinite(seconds) ? Math.min(1200, Math.max(0, seconds)) : 0;
      init(subtune);
      seekRemaining = Math.floor(target * samplerate);
    };
    this.advanceSeek = function(maxSamples, budgetMS = Infinity) {
      const count = Math.min(seekRemaining, maxSamples);
      const deadline = Number.isFinite(budgetMS) ? Date.now() + budgetMS : Infinity;
      for (let i = 0; i < count; i++) {
        this.playSample();
        seekRemaining--;
        if (deadline !== Infinity && (i & 255) === 255 && Date.now() >= deadline) break;
      }
      return seekRemaining > 0;
    };
    this.seek = function(seconds) {
      this.beginSeek(seconds);
      this.advanceSeek(Number.MAX_SAFE_INTEGER);
    };

    // Nur der vorbereitende Dedicated Worker erzeugt diese Kopie. Restore
    // benutzt vorhandene Puffer, statt im Audiocallback einen Emulator zu bauen.
    this.captureLoop = end => ({
      context: { samplerate, clock, subtune, loadaddr, initaddr, playaddf,
        timermode: timermode.slice(), repeatedSpeedBits, addresses: SID_address.slice(), models: preferred_SID_model.slice(),
        muted: voiceMuted.slice(), loadedMemory: loadedMemory.slice() },
      endSample: Math.floor(end * samplerate),
      state: {initialized, finished, playtime, renderedSamples, framecnt, CPUtime, pPC, mix, PC, A, T, X, Y, SP, IR, addr, ST, cycles, storadd, SID_model, playaddr, frame_sampleperiod, usesCIATimer, combiwf, prevgate, chnadd, ctrl, wf, test, period, step, SR, accuadd, MSB, tmp, pw, lim, wfout, cutoff, resonance, filtin, output, memory: memory.slice(), ADSRstate: ADSRstate.slice(), ratecnt: ratecnt.slice(), envcnt: envcnt.slice(), expcnt: expcnt.slice(), prevSR: prevSR.slice(), phaseaccu: phaseaccu.slice(), prevaccu: prevaccu.slice(), sourceMSBrise: sourceMSBrise.slice(), sourceMSB: sourceMSB.slice(), noise_LFSR: noise_LFSR.slice(), prevwfout: prevwfout.slice(), prevwavdata: prevwavdata.slice(), prevlowpass: prevlowpass.slice(), prevbandpass: prevbandpass.slice(), voiceLowpass: voiceLowpass.slice(), voiceBandpass: voiceBandpass.slice()}
    });
    function restoreSnapshot(state) {
      initialized = state.initialized;
      finished = state.finished;
      playtime = state.playtime;
      renderedSamples = state.renderedSamples;
      framecnt = state.framecnt;
      CPUtime = state.CPUtime;
      pPC = state.pPC;
      mix = state.mix;
      PC = state.PC;
      A = state.A;
      T = state.T;
      X = state.X;
      Y = state.Y;
      SP = state.SP;
      IR = state.IR;
      addr = state.addr;
      ST = state.ST;
      cycles = state.cycles;
      storadd = state.storadd;
      SID_model = state.SID_model;
      playaddr = state.playaddr;
      frame_sampleperiod = state.frame_sampleperiod;
      usesCIATimer = state.usesCIATimer;
      combiwf = state.combiwf;
      prevgate = state.prevgate;
      chnadd = state.chnadd;
      ctrl = state.ctrl;
      wf = state.wf;
      test = state.test;
      period = state.period;
      step = state.step;
      SR = state.SR;
      accuadd = state.accuadd;
      MSB = state.MSB;
      tmp = state.tmp;
      pw = state.pw;
      lim = state.lim;
      wfout = state.wfout;
      cutoff = state.cutoff;
      resonance = state.resonance;
      filtin = state.filtin;
      output = state.output;
      memory.set(state.memory);
      for (let i = 0; i < ADSRstate.length; i++) ADSRstate[i] = state.ADSRstate[i];
      for (let i = 0; i < ratecnt.length; i++) ratecnt[i] = state.ratecnt[i];
      for (let i = 0; i < envcnt.length; i++) envcnt[i] = state.envcnt[i];
      for (let i = 0; i < expcnt.length; i++) expcnt[i] = state.expcnt[i];
      for (let i = 0; i < prevSR.length; i++) prevSR[i] = state.prevSR[i];
      for (let i = 0; i < phaseaccu.length; i++) phaseaccu[i] = state.phaseaccu[i];
      for (let i = 0; i < prevaccu.length; i++) prevaccu[i] = state.prevaccu[i];
      for (let i = 0; i < sourceMSBrise.length; i++) sourceMSBrise[i] = state.sourceMSBrise[i];
      for (let i = 0; i < sourceMSB.length; i++) sourceMSB[i] = state.sourceMSB[i];
      for (let i = 0; i < noise_LFSR.length; i++) noise_LFSR[i] = state.noise_LFSR[i];
      for (let i = 0; i < prevwfout.length; i++) prevwfout[i] = state.prevwfout[i];
      for (let i = 0; i < prevwavdata.length; i++) prevwavdata[i] = state.prevwavdata[i];
      for (let i = 0; i < prevlowpass.length; i++) prevlowpass[i] = state.prevlowpass[i];
      for (let i = 0; i < prevbandpass.length; i++) prevbandpass[i] = state.prevbandpass[i];
      for (let i = 0; i < voiceLowpass.length; i++) voiceLowpass[i] = state.voiceLowpass[i];
      for (let i = 0; i < voiceBandpass.length; i++) voiceBandpass[i] = state.voiceBandpass[i];
    }
    this.installLoop = snapshot => {
      const equal = (a, b) => a && b && a.length === b.length && a.every((value, i) => value === b[i]);
      const c = snapshot?.context, state = snapshot?.state;
      if (!loaded || !initialized || !c || !state || c.samplerate !== samplerate || c.clock !== clock || c.subtune !== subtune
          || c.loadaddr !== loadaddr || c.initaddr !== initaddr || c.playaddf !== playaddf
          || !equal(c.timermode, timermode) || c.repeatedSpeedBits !== repeatedSpeedBits || !equal(c.addresses, SID_address)
          || !equal(c.models, preferred_SID_model) || !equal(c.muted, voiceMuted)
          || !Array.isArray(state.voiceLowpass) || state.voiceLowpass.length !== 9 || !state.voiceLowpass.every(Number.isFinite)
          || !Array.isArray(state.voiceBandpass) || state.voiceBandpass.length !== 9 || !state.voiceBandpass.every(Number.isFinite)
          || !equal(c.loadedMemory, loadedMemory) || !Number.isSafeInteger(snapshot.endSample)
          || snapshot.endSample - state.renderedSamples < Math.floor(0.25 * samplerate)) return false;
      preparedLoop = snapshot;
      return true;
    };
    this.disableLoop = () => { preparedLoop = null; };

    this.getChannelsData = function() {
      const chips = SID_address.map((base, chip) => {
        if (!base) return null;
        const channels = [0, 1, 2];
        return {
          baseAddress: base,
          registers: Array.from({ length: 32 }, (_, offset) => offset <= 0x18 || offset === 0x1b || offset === 0x1c ? memory[base + offset] : null),
          envelopes: channels.map(voice => envcnt[chip * 3 + voice] / 255),
          frequencies: channels.map(voice => memory[base + voice * 7] + memory[base + voice * 7 + 1] * 256),
          gates: channels.map(voice => memory[base + voice * 7 + 4] & 1),
          waveforms: channels.map(voice => memory[base + voice * 7 + 4] & 0xf0),
          pulsewidths: channels.map(voice => (memory[base + voice * 7 + 2] + (memory[base + voice * 7 + 3] & 0x0f) * 256) / 4096)
        };
      });
      return { ...chips[0], chips, playtime, clock };
    };

  }
}

class SidPlayerWorklet extends AudioWorkletProcessor {
  constructor() {
    super();
    this.engine = new SidPlayerProcessor();
    this.playing = false;
    this.loaded = false;
    this.seeking = false;
    this.seekRequest = 0;
    this.loopRequest = 0;
    
    this.visualizerTicker = 0;
    this.generation = 0;
    
    this.port.onmessage = (e) => {
      const data = e.data;
      if (data.type === 'load') {
        this.generation = data.generation;
        this.seeking = false;
        const metadata = this.engine.loadSID(data.data);
        this.engine.initSubtune(data.subtune || 0);
        this.loaded = true;
        this.port.postMessage({ type: 'loaded', metadata, generation: data.generation });
      } else if (data.type === 'prepareLoop') {
        this.loopRequest = data.request;
        this.engine.disableLoop();
      } else if (data.type === 'installLoop' && data.generation === this.generation && data.request === this.loopRequest) {
        const installed = this.engine.installLoop(data.snapshot);
        this.port.postMessage({ type: 'loopReady', installed, generation: this.generation, request: data.request });
      } else if (data.type === 'play') {
        this.playing = true;
      } else if (data.type === 'stop') {
        this.playing = false;
      } else if (data.type === 'setSubtune') {
        this.generation = data.generation;
        this.seeking = false;
        this.engine.initSubtune(data.subtune);
      } else if (data.type === 'setVolume') {
        this.engine.setVolume(data.volume);
      } else if (data.type === 'setMutedChannels') {
        this.engine.setMutedChannels(data.muted);
      } else if (data.type === 'setClockMode') {
        this.seekRequest = data.request;
        this.engine.setClockMode(data.mode);
        this.seeking = this.loaded;
      } else if (data.type === 'seek') {
        this.seekRequest = data.request;
        this.engine.beginSeek(data.seconds);
        this.seeking = true;
      }
    };
  }

  process(inputs, outputs, parameters) {
    const output = outputs[0];
    const channelLeft = output[0];
    const channelRight = output[1];
    
    if (this.seeking) {
      this.seeking = this.engine.advanceSeek(32768, 1);
      if (!this.seeking) {
        this.port.postMessage({ type: 'seekComplete', generation: this.generation, request: this.seekRequest });
        this.port.postMessage({ type: 'visualizer', generation: this.generation, data: this.engine.getChannelsData() });
      }
      channelLeft.fill(0);
      if (channelRight) channelRight.fill(0);
      return true;
    }
    if (!this.loaded || !this.playing) {
      for (let i = 0; i < channelLeft.length; i++) {
        channelLeft[i] = 0;
        if (channelRight) channelRight[i] = 0;
      }
      return true;
    }
    
    for (let i = 0; i < channelLeft.length; i++) {
      const sample = this.engine.playSample();
      channelLeft[i] = sample;
      if (channelRight) channelRight[i] = sample;
    }
    
    // Post visualizer info approximately 43 times per second (every 1024 samples)
    this.visualizerTicker += channelLeft.length;
    if (this.visualizerTicker >= 1024) {
      this.visualizerTicker = 0;
      this.port.postMessage({
        type: 'visualizer',
        generation: this.generation,
        data: this.engine.getChannelsData()
      });
    }
    
    return true;
  }
}

registerProcessor('sid-player-worklet', SidPlayerWorklet);
