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
    
    let C64_PAL_CPUCLK = 985248;
    let PAL_FRAMERATE = 50;
    let SID_CHANNEL_AMOUNT = 3;
    let OUTPUT_SCALEDOWN = 0x10000 * SID_CHANNEL_AMOUNT * 16;
    
    let SIDamount_vol = [0, 1, 0.6, 0.4];
    
    let SIDtitle = new Uint8Array(0x20);
    let SIDauthor = new Uint8Array(0x20);
    let SIDinfo = new Uint8Array(0x20);
    let timermode = new Uint8Array(0x20);
    
    let loadaddr = 0x1000;
    let initaddr = 0x1000;
    let playaddf = 0x1003;
    let playaddr = 0x1003;
    let subtune = 0;
    let subtune_amount = 1;

    // Liest den Timer-Modus des aktuellen Subtunes. timermode hat nur 32 Eintraege,
    // PSID erlaubt aber mehr Subtunes — fuer subtune >= 32 waere timermode[subtune]
    // sonst undefined (und "undefined && true" === false), was das CIA-Timer-Pacing
    // stilllegen wuerde. Daher den Index clampen, analog zum Swift-Port
    // (timerModeForCurrentSubtune, min(subtune, count-1)).
    function timerModeForSubtune() {
      return timermode[Math.min(subtune, timermode.length - 1)];
    }
    
    let preferred_SID_model = [8580.0, 8580.0, 8580.0];
    let SID_model = 8580.0;
    let SID_address = [0xD400, 0, 0];
    let memory = new Uint8Array(65536);
    
    let loaded = 0;
    let initialized = 0;
    let finished = 0;
    let playtime = 0;

    let clk_ratio = C64_PAL_CPUCLK / samplerate;
    let frame_sampleperiod = samplerate / PAL_FRAMERATE;
    
    let framecnt = 1;
    let volume = 1.0;
    let CPUtime = 0;
    let pPC = 0;
    let SIDamount = 1;
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
      }
      prevlowpass = [0, 0, 0];
      prevbandpass = [0, 0, 0];
    }

    function init(subt) {
      if (loaded) {
        initialized = 0;
        subtune = subt;
        initCPU(initaddr);
        initSID();

        A = subtune;
        memory[1] = 0x37;
        memory[0xDC05] = 0;

        for (let timeout = 100000; timeout >= 0; timeout--) {
          if (CPU()) break;
        }

        if (timerModeForSubtune() || memory[0xDC05]) {
          if (!memory[0xDC05]) {
            memory[0xDC04] = 0x24;
            memory[0xDC05] = 0x40;
          }
          frame_sampleperiod = (memory[0xDC04] + memory[0xDC05] * 256) / clk_ratio;
        } else {
          frame_sampleperiod = samplerate / PAL_FRAMERATE;
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
        initialized = 1;
      }
    }

    function CPU() {
      IR = memory[PC];
      cycles = 2;
      storadd = 0;

      if (IR & 1) {
        switch (IR & 0x1F) {
          case 1: case 3: addr = memory[memory[++PC] + X] + memory[memory[PC] + X + 1] * 256; cycles = 6; break;
          case 0x11: case 0x13: addr = memory[memory[++PC]] + memory[memory[PC] + 1] * 256 + Y; cycles = 6; break;
          case 0x19: case 0x1F: addr = memory[++PC] + memory[++PC] * 256 + Y; cycles = 5; break;
          case 0x1D: addr = memory[++PC] + memory[++PC] * 256 + X; cycles = 5; break;
          case 0xD: case 0xF: addr = memory[++PC] + memory[++PC] * 256; cycles = 4; break;
          case 0x15: addr = memory[++PC] + X; cycles = 4; break;
          case 5: case 7: addr = memory[++PC]; cycles = 3; break;
          case 0x17: addr = memory[++PC] + Y; cycles = 4; break;
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
          case 0x16: addr = memory[++PC] + (((IR & 0xC0) != 0x80) ? X : Y); cycles = 4; break;
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
            case 0x14: addr = memory[++PC] + X; cycles = 4; break;
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
      filtin = 0;
      output = 0;

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

        if (memory[SIDaddr + 0x17] & FILTSW[channel]) {
          filtin += (wfout - 0x8000) * (envcnt[channel] / 256);
        } else if ((channel % SID_CHANNEL_AMOUNT) != 2 || !(memory[SIDaddr + 0x18] & OFF3_BITMASK)) {
          output += (wfout - 0x8000) * (envcnt[channel] / 256);
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

      // Filter processing
      cutoff = (memory[SIDaddr + 0x15] & 7) / 8 + memory[SIDaddr + 0x16] + 0.2;
      if (SID_model == 8580.0) {
        cutoff = 1 - Math.exp(cutoff * cutoff_ratio_8580);
        resonance = Math.pow(2, ((4 - (memory[SIDaddr + 0x17] >> 4)) / 8));
      } else {
        if (cutoff < 24) cutoff = 0.035;
        else cutoff = 1 - 1.263 * Math.exp(cutoff * cutoff_ratio_6581);
        resonance = (memory[SIDaddr + 0x17] > 0x5F) ? 8 / (memory[SIDaddr + 0x17] >> 4) : 1.41;
      }

      tmp = filtin + prevbandpass[num] * resonance + prevlowpass[num];
      if (memory[SIDaddr + 0x18] & HIGHPASS_BITMASK) output -= tmp;
      tmp = prevbandpass[num] - tmp * cutoff;
      prevbandpass[num] = tmp;
      if (memory[SIDaddr + 0x18] & BANDPASS_BITMASK) output -= tmp;
      tmp = prevlowpass[num] + tmp * cutoff;
      prevlowpass[num] = tmp;
      if (memory[SIDaddr + 0x18] & LOWPASS_BITMASK) output += tmp;

      return (output / OUTPUT_SCALEDOWN) * (memory[SIDaddr + 0x18] & 0xF);
    }

    function play() {
      if (loaded && initialized) {
        framecnt--;
        playtime += 1 / samplerate;

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
            if ((addr == 0xDC05 || addr == 0xDC04) && (memory[1] & 3) && timerModeForSubtune()) {
              frame_sampleperiod = (memory[0xDC04] + memory[0xDC05] * 256) / clk_ratio;
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
      loaded = 0;
      initialized = 0;
      initSID();
      
      // dataOffset ist ein 16-Bit-Big-Endian-Feld an Header-Position 6-7.
      // Frueher wurde nur das Low-Byte (filedata[7]) gelesen; bei Headern mit
      // dataOffset > 0xFF haette das die PRG-Bytes falsch positioniert.
      let offs = filedata[6] * 256 + filedata[7];
      loadaddr = filedata[8] * 256 + filedata[9];
      if (loadaddr === 0) {
        loadaddr = filedata[offs] + filedata[offs + 1] * 256;
      }
      
      for (let i = 0; i < 32; i++) {
        timermode[31 - i] = filedata[0x12 + (i >> 3)] & Math.pow(2, 7 - (i % 8));
      }
      
      // Clear memory
      for (let i = 0; i < memory.length; i++) memory[i] = 0;
      
      for (let i = offs + 2; i < filedata.byteLength; i++) {
        if (loadaddr + i - (offs + 2) < memory.length) {
          memory[loadaddr + i - (offs + 2)] = filedata[i];
        }
      }
      
      let strend = 1;
      for (let i = 0; i < 32; i++) {
        if (strend !== 0) strend = SIDtitle[i] = filedata[0x16 + i];
        else SIDtitle[i] = 0;
      }
      strend = 1;
      for (let i = 0; i < 32; i++) {
        if (strend !== 0) strend = SIDauthor[i] = filedata[0x36 + i];
        else SIDauthor[i] = 0;
      }
      strend = 1;
      for (let i = 0; i < 32; i++) {
        if (strend !== 0) strend = SIDinfo[i] = filedata[0x56 + i];
        else SIDinfo[i] = 0;
      }
      
      initaddr = filedata[0xA] * 256 + filedata[0xB];
      if (initaddr === 0) initaddr = loadaddr;
      
      playaddr = playaddf = filedata[0xC] * 256 + filedata[0xD];
      // PSID-songs-Feld ist 16-bit Big-Endian bei 0x0E; vorher wurde nur das untere
      // Byte (0x0F) gelesen -> bei 256 Subtunes 0 statt 256. Beide Bytes kombinieren,
      // damit die Anzahl mit Swift-Seite und PSID-Spec uebereinstimmt.
      subtune_amount = (filedata[0x0E] << 8) | filedata[0x0F];
      
      preferred_SID_model[0] = (filedata[0x77] & 0x30) >= 0x20 ? 8580 : 6581;
      preferred_SID_model[1] = (filedata[0x77] & 0xC0) >= 0x80 ? 8580 : 6581;
      preferred_SID_model[2] = (filedata[0x76] & 3) >= 3 ? 8580 : 6581;
      
      SID_address[1] = filedata[0x7A] >= 0x42 && (filedata[0x7A] < 0x80 || filedata[0x7A] >= 0xE0) ? 0xD000 + filedata[0x7A] * 16 : 0;
      SID_address[2] = filedata[0x7B] >= 0x42 && (filedata[0x7B] < 0x80 || filedata[0x7B] >= 0xE0) ? 0xD000 + filedata[0x7B] * 16 : 0;
      
      SIDamount = 1 + (SID_address[1] > 0) + (SID_address[2] > 0);
      loaded = 1;
      
      return {
        title: String.fromCharCode.apply(null, Array.from(SIDtitle)).replace(/\0/g, '').trim(),
        author: String.fromCharCode.apply(null, Array.from(SIDauthor)).replace(/\0/g, '').trim(),
        info: String.fromCharCode.apply(null, Array.from(SIDinfo)).replace(/\0/g, '').trim(),
        subtunesCount: subtune_amount,
        prefModel: preferred_SID_model[0]
      };
    };
    
    this.initSubtune = function(subt) {
      init(subt);
    };
    
    this.setVolume = function(vol) {
      volume = vol;
    };

    // Run the player routine for exactly one frame WITHOUT rendering audio.
    // This is the cheap core of seeking: it advances the CPU + SID registers
    // (i.e. the song position) but skips the per-sample waveform/filter math,
    // which is the bulk of playSample()'s cost. Mirrors play()'s inner CPU loop.
    function runFrameCPU() {
      finished = 0;
      PC = playaddr;
      SP = 0xFF;
      const budget = clk_ratio * frame_sampleperiod; // C64 cycles in one frame
      let t = 0;
      while (t <= budget) {
        pPC = PC;
        const r = CPU();
        if (r >= 0xFE) { finished = 1; break; }
        t += cycles;
        if ((memory[1] & 3) > 1 && pPC < 0xE000 && (PC == 0xEA31 || PC == 0xEA81)) { finished = 1; break; }
        if ((addr == 0xDC05 || addr == 0xDC04) && (memory[1] & 3) && timerModeForSubtune()) {
          frame_sampleperiod = (memory[0xDC04] + memory[0xDC05] * 256) / clk_ratio;
        }
        if (storadd >= 0xD420 && storadd < 0xD800 && (memory[1] & 3)) {
          if (!(SID_address[1] <= storadd && storadd < SID_address[1] + 0x1F) &&
              !(SID_address[2] <= storadd && storadd < SID_address[2] + 0x1F)) {
            memory[storadd & 0xD41F] = memory[storadd];
          }
        }
        if (addr == 0xD404 && !(memory[0xD404] & 1)) ADSRstate[0] &= 0x3E;
        if (addr == 0xD40B && !(memory[0xD40B] & 1)) ADSRstate[1] &= 0x3E;
        if (addr == 0xD412 && !(memory[0xD412] & 1)) ADSRstate[2] &= 0x3E;
      }
    }

    // Seek to a position in seconds. A SID tune has NO random access — the only
    // way to reach a position is to restart the current subtune and fast-forward.
    // We advance whole FRAMES via runFrameCPU() (CPU + registers only, no audio
    // rendering), which is far faster than running play() for every sample. The
    // envelope phase isn't reproduced exactly, but the player re-gates within a
    // frame or two, so it's inaudible in practice.
    this.seek = function(seconds) {
      if (!loaded) return;
      let target = seconds > 0 ? seconds : 0;
      const MAX_SEEK = 1200; // 20 min hard cap on fast-forward work
      if (target > MAX_SEEK) target = MAX_SEEK;
      init(subtune); // restart tune (resets playtime to 0, re-runs init routine)
      const frames = Math.floor(target * samplerate / frame_sampleperiod);
      for (let f = 0; f < frames; f++) runFrameCPU();
      // Resume cleanly: the next play() sample starts a fresh frame and renders.
      framecnt = 1;
      CPUtime = 0;
      finished = 0;
      playtime = target;
    };

    this.getChannelsData = function() {
      // Returns current envelope levels, frequencies, gate signals, the selected
      // waveform + pulse-width per voice, and elapsed playtime (seconds) so the
      // UI can draw the real waveform shapes on the scope and drive the scrubber.
      // waveform = the upper nibble of each voice's control register (bit 4 TRI,
      // 5 SAW, 6 PULSE, 7 NOISE). pulsewidth is the 12-bit duty cycle as 0..1.
      return {
        envelopes: [envcnt[0] / 255.0, envcnt[1] / 255.0, envcnt[2] / 255.0],
        frequencies: [
          (memory[0xD400] + memory[0xD401] * 256),
          (memory[0xD407] + memory[0xD408] * 256),
          (memory[0xD40E] + memory[0xD40F] * 256)
        ],
        gates: [
          memory[0xD404] & 1,
          memory[0xD40B] & 1,
          memory[0xD412] & 1
        ],
        waveforms: [
          memory[0xD404] & 0xF0,
          memory[0xD40B] & 0xF0,
          memory[0xD412] & 0xF0
        ],
        pulsewidths: [
          (memory[0xD402] + (memory[0xD403] & 0x0F) * 256) / 4096,
          (memory[0xD409] + (memory[0xD40A] & 0x0F) * 256) / 4096,
          (memory[0xD410] + (memory[0xD411] & 0x0F) * 256) / 4096
        ],
        playtime: playtime
      };
    };
  }
}

class SidPlayerWorklet extends AudioWorkletProcessor {
  constructor() {
    super();
    this.engine = new SidPlayerProcessor();
    this.playing = false;
    this.loaded = false;
    
    this.visualizerTicker = 0;
    
    this.port.onmessage = (e) => {
      const data = e.data;
      if (data.type === 'load') {
        const metadata = this.engine.loadSID(data.data);
        this.engine.initSubtune(data.subtune || 0);
        this.loaded = true;
        this.port.postMessage({ type: 'loaded', metadata });
      } else if (data.type === 'play') {
        this.playing = true;
      } else if (data.type === 'stop') {
        this.playing = false;
      } else if (data.type === 'setSubtune') {
        this.engine.initSubtune(data.subtune);
      } else if (data.type === 'setVolume') {
        this.engine.setVolume(data.volume);
      } else if (data.type === 'seek') {
        this.engine.seek(data.seconds);
      }
    };
  }

  process(inputs, outputs, parameters) {
    const output = outputs[0];
    const channelLeft = output[0];
    const channelRight = output[1];
    
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
        data: this.engine.getChannelsData()
      });
    }
    
    return true;
  }
}

registerProcessor('sid-player-worklet', SidPlayerWorklet);
