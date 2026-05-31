import Foundation

public struct SidVisuals: Sendable {
    public let envelopes: (Float, Float, Float)
    public let frequencies: (Int, Int, Int)
    public let gates: (Int, Int, Int)
    public let waveforms: (Int, Int, Int)
    public let pulsewidths: (Float, Float, Float)
    public let playtime: Double
}

public final class ViciousProcessor: Sendable {
    // Engine config and sample rate
    private let samplerate: Double

    // C64 and SID Constants
    private let CLK: Int = 985248
    private let FR: Int = 50
    private let CHA: Int = 3
    private let C64_PAL_CPUCLK: Double = 985248
    private let PAL_FRAMERATE: Double = 50
    private let SID_CHANNEL_AMOUNT: Int = 3
    private let OUTPUT_SCALEDOWN: Double = 3145728 // 0x10000 * 3 * 16

    private let SIDamount_vol: [Double] = [0, 1, 0.6, 0.4]

    // Constants arrays
    private let flagsw: [UInt8] = [0x01, 0x21, 0x04, 0x24, 0x00, 0x40, 0x08, 0x28]
    private let branchflag: [UInt8] = [0x80, 0x40, 0x01, 0x02]
    private let FILTSW: [UInt8] = [1, 2, 4, 1, 2, 4, 1, 2, 4]

    // SID chip bits
    private let GATE_BITMASK: UInt8 = 0x01
    private let SYNC_BITMASK: UInt8 = 0x02
    private let RING_BITMASK: UInt8 = 0x04
    private let TEST_BITMASK: UInt8 = 0x08
    private let TRI_BITMASK: UInt8 = 0x10
    private let SAW_BITMASK: UInt8 = 0x20
    private let PULSE_BITMASK: UInt8 = 0x40
    private let NOISE_BITMASK: UInt8 = 0x80
    private let HOLDZERO_BITMASK: UInt8 = 0x10
    private let DECAYSUSTAIN_BITMASK: UInt8 = 0x40
    private let ATTACK_BITMASK: UInt8 = 0x80
    private let LOWPASS_BITMASK: UInt8 = 0x10
    private let BANDPASS_BITMASK: UInt8 = 0x20
    private let HIGHPASS_BITMASK: UInt8 = 0x40
    private let OFF3_BITMASK: UInt8 = 0x80

    // C64 RAM memory (64 KB)
    // Nonisolated unsafe fields to satisfy Swift 6 Strict Concurrency inside core DSP thread.
    // The processor will be owned and driven solely by a single real-time audio thread callback.
    nonisolated(unsafe) private var memory = SafeMemory()

    // CPU Registers
    nonisolated(unsafe) private var PC: UInt16 = 0
    nonisolated(unsafe) private var A: UInt8 = 0
    nonisolated(unsafe) private var T: Int = 0
    nonisolated(unsafe) private var X: UInt8 = 0
    nonisolated(unsafe) private var Y: UInt8 = 0
    nonisolated(unsafe) private var SP: UInt8 = 0xFF
    nonisolated(unsafe) private var IR: UInt8 = 0
    nonisolated(unsafe) private var addr: UInt32 = 0
    nonisolated(unsafe) private var ST: UInt8 = 0x00 // status flags: N V - B D I Z C
    nonisolated(unsafe) private var cycles: Int = 0
    nonisolated(unsafe) private var storadd: UInt32 = 0

    // Emulation state
    nonisolated(unsafe) private var loadaddr: UInt16 = 0x1000
    nonisolated(unsafe) private var initaddr: UInt16 = 0x1000
    nonisolated(unsafe) private var playaddf: UInt16 = 0x1003
    nonisolated(unsafe) private var playaddr: UInt16 = 0x1003
    nonisolated(unsafe) private var subtune: Int = 0
    nonisolated(unsafe) private var subtune_amount: Int = 1
    nonisolated(unsafe) private var timermode = [UInt8](repeating: 0, count: 32)
    nonisolated(unsafe) private var preferred_SID_model: [Double] = [8580.0, 8580.0, 8580.0]
    nonisolated(unsafe) private var SID_model: Double = 8580.0
    nonisolated(unsafe) private var SID_address: [UInt32] = [0xD400, 0, 0]

    nonisolated(unsafe) private var loaded: Bool = false
    nonisolated(unsafe) private var initialized: Bool = false
    nonisolated(unsafe) private var finished: Bool = false
    nonisolated(unsafe) private var playtime: Double = 0.0
    nonisolated(unsafe) private var clk_ratio: Double = 0.0
    nonisolated(unsafe) private var frame_sampleperiod: Double = 0.0
    nonisolated(unsafe) private var framecnt: Double = 1.0
    nonisolated(unsafe) private var volume: Double = 1.0
    nonisolated(unsafe) private var CPUtime: Double = 0.0
    nonisolated(unsafe) private var pPC: UInt16 = 0
    nonisolated(unsafe) private var SIDamount: Int = 1
    nonisolated(unsafe) private var mix: Double = 0.0
    private let lock = NSLock()

    // SID channels voice states
    nonisolated(unsafe) private var ADSRstate = [UInt8](repeating: 0, count: 9)
    nonisolated(unsafe) private var ratecnt = [Double](repeating: 0.0, count: 9)
    nonisolated(unsafe) private var envcnt = [Double](repeating: 0.0, count: 9)
    nonisolated(unsafe) private var expcnt = [Double](repeating: 0.0, count: 9)
    nonisolated(unsafe) private var prevSR = [UInt8](repeating: 0, count: 9)
    nonisolated(unsafe) private var phaseaccu = [Double](repeating: 0.0, count: 9)
    nonisolated(unsafe) private var prevaccu = [Double](repeating: 0.0, count: 9)
    nonisolated(unsafe) private var sourceMSBrise = [UInt8](repeating: 0, count: 3)
    nonisolated(unsafe) private var sourceMSB = [Double](repeating: 0.0, count: 3)
    nonisolated(unsafe) private var noise_LFSR = [UInt32](repeating: 0x7FFFF8, count: 9)
    nonisolated(unsafe) private var prevwfout = [Double](repeating: 0.0, count: 9)
    nonisolated(unsafe) private var prevwavdata = [Double](repeating: 0.0, count: 9)
    nonisolated(unsafe) private var combiwf: Double = 0.0
    nonisolated(unsafe) private var prevlowpass = [Double](repeating: 0.0, count: 3)
    nonisolated(unsafe) private var prevbandpass = [Double](repeating: 0.0, count: 3)

    nonisolated(unsafe) private var cutoff_ratio_8580: Double = 0.0
    nonisolated(unsafe) private var cutoff_ratio_6581: Double = 0.0

    // Precalculated combined wave tables
    nonisolated(unsafe) private var TriSaw_8580 = [Double](repeating: 0.0, count: 4096)
    nonisolated(unsafe) private var PulseSaw_8580 = [Double](repeating: 0.0, count: 4096)
    nonisolated(unsafe) private var PulseTriSaw_8580 = [Double](repeating: 0.0, count: 4096)

    // ADSR Periods and Tables
    nonisolated(unsafe) private var ADSRperiods = [Double]()
    nonisolated(unsafe) private var ADSRstep = [Double]()
    private let ADSR_exptable: [Double] = [
      1, 30, 30, 30, 30, 30, 30, 16, 16, 16, 16, 16, 16, 16, 16, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 4, 4, 4, 4, 4,
      4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
      2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
      1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
      1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
      1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
      1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
      1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
      1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
    ]

    public init(sampleRate: Double) {
        self.samplerate = sampleRate
        self.clk_ratio = C64_PAL_CPUCLK / sampleRate
        self.frame_sampleperiod = sampleRate / PAL_FRAMERATE

        self.cutoff_ratio_8580 = -2.0 * .pi * (12500.0 / 256.0) / sampleRate
        self.cutoff_ratio_6581 = -2.0 * .pi * (20000.0 / 256.0) / sampleRate

        // Precalculate Tables
        createCombinedWF(wfarray: &TriSaw_8580, bitmul: 0.8, bitstrength: 2.4, treshold: 0.64)
        createCombinedWF(wfarray: &PulseSaw_8580, bitmul: 1.4, bitstrength: 1.9, treshold: 0.68)
        createCombinedWF(wfarray: &PulseTriSaw_8580, bitmul: 0.8, bitstrength: 2.5, treshold: 0.64)

        let period0 = max(self.clk_ratio, 9.0)
        self.ADSRperiods = [
            period0, 32.0, 63.0, 95.0, 149.0, 220.0, 267.0, 313.0,
            392.0, 977.0, 1954.0, 3126.0, 3907.0, 11720.0, 19532.0, 31251.0
        ]
        self.ADSRstep = [
            ceil(period0 / 9.0), 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
            1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0
        ]
    }

    private func createCombinedWF(wfarray: inout [Double], bitmul: Double, bitstrength: Double, treshold: Double) {
        for i in 0..<4096 {
            wfarray[i] = 0.0
            for j in 0..<12 {
                var bitlevel = 0.0
                for k in 0..<12 {
                    let term = bitmul / pow(bitstrength, Double(abs(k - j)))
                    let bit = Double(((i >> k) & 1)) - 0.5
                    bitlevel += term * bit
                }
                wfarray[i] += bitlevel >= treshold ? pow(2.0, Double(j)) : 0.0
            }
            wfarray[i] *= 12.0
        }
    }

    private func initCPU(mempos: UInt16) {
        PC = mempos
        A = 0
        X = 0
        Y = 0
        ST = 0
        SP = 0xFF
    }

    private func initSID() {
        for i in 0xD400...0xD7FF { memory[i] = 0 }
        for i in 0xDE00...0xDFFF { memory[i] = 0 }
        for i in 0..<9 {
            ADSRstate[i] = HOLDZERO_BITMASK
            ratecnt[i] = 0.0
            envcnt[i] = 0.0
            expcnt[i] = 0.0
            prevSR[i] = 0
            phaseaccu[i] = 0.0
            prevaccu[i] = 0.0
            prevwfout[i] = 0.0
            prevwavdata[i] = 0.0
        }
        prevlowpass = [0.0, 0.0, 0.0]
        prevbandpass = [0.0, 0.0, 0.0]
    }

    private func initEmulation(subt: Int) {
        if loaded {
            initialized = false
            subtune = subt
            initCPU(mempos: initaddr)
            initSID()

            A = UInt8(subtune)
            memory[1] = 0x37
            memory[0xDC05] = 0

            for _ in 0..<100000 {
                if CPU() >= 0xFE { break }
            }

            if timermode[subtune] != 0 || memory[0xDC05] != 0 {
                if memory[0xDC05] == 0 {
                    memory[0xDC04] = 0x24
                    memory[0xDC05] = 0x40
                }
                frame_sampleperiod = Double(UInt16(memory[0xDC04]) | UInt16(memory[0xDC05]) << 8) / clk_ratio
            } else {
                frame_sampleperiod = samplerate / PAL_FRAMERATE
            }

            if playaddf == 0 {
                playaddr = ((memory[1] & 3) < 2)
                    ? UInt16(memory[0xFFFE]) | UInt16(memory[0xFFFF]) << 8
                    : UInt16(memory[0x314]) | UInt16(memory[0x315]) << 8
            } else {
                playaddr = playaddf
                if playaddr >= 0xE000 && memory[1] == 0x37 { memory[1] = 0x35 }
            }

            initCPU(mempos: playaddr)
            framecnt = 1.0
            finished = false
            CPUtime = 0.0
            playtime = 0.0
            initialized = true
        }
    }

    private func CPU() -> Int {
        IR = memory[Int(PC)]
        cycles = 2
        storadd = 0

        if (IR & 1) != 0 {
            switch IR & 0x1F {
            case 1, 3:
                let base = Int(memory[Int(PC &+ 1) & 0xFFFF] &+ X)
                addr = UInt32(memory[base & 0xFFFF]) | UInt32(memory[(base &+ 1) & 0xFFFF]) << 8
                PC = PC &+ 1
                cycles = 6
            case 0x11, 0x13:
                let base = Int(memory[Int(PC &+ 1) & 0xFFFF])
                addr = (UInt32(memory[base & 0xFFFF]) | UInt32(memory[(base &+ 1) & 0xFFFF]) << 8) &+ UInt32(Y)
                PC = PC &+ 1
                cycles = 6
            case 0x19, 0x1F:
                addr = (UInt32(memory[Int(PC &+ 1) & 0xFFFF]) | UInt32(memory[Int(PC &+ 2) & 0xFFFF]) << 8) &+ UInt32(Y)
                PC = PC &+ 2
                cycles = 5
            case 0x1D:
                addr = (UInt32(memory[Int(PC &+ 1) & 0xFFFF]) | UInt32(memory[Int(PC &+ 2) & 0xFFFF]) << 8) &+ UInt32(X)
                PC = PC &+ 2
                cycles = 5
            case 0xD, 0xF:
                addr = UInt32(memory[Int(PC &+ 1) & 0xFFFF]) | UInt32(memory[Int(PC &+ 2) & 0xFFFF]) << 8
                PC = PC &+ 2
                cycles = 4
            case 0x15:
                addr = UInt32(memory[Int(PC &+ 1) & 0xFFFF] &+ X)
                PC = PC &+ 1
                cycles = 4
            case 5, 7:
                addr = UInt32(memory[Int(PC &+ 1) & 0xFFFF])
                PC = PC &+ 1
                cycles = 3
            case 0x17:
                addr = UInt32(memory[Int(PC &+ 1) & 0xFFFF] &+ Y)
                PC = PC &+ 1
                cycles = 4
            case 9, 0xB:
                PC = PC &+ 1
                addr = UInt32(PC)
                cycles = 2
            default: break
            }

            addr &= 0xFFFF
            let mVal = Int(memory[Int(addr)])
            switch IR & 0xE0 {
            case 0x60: // ADC
                let carry = Int(ST & 1)
                let tA = Int(A)
                let sum = tA + mVal + carry
                ST &= 20
                ST |= UInt8(((sum & 0xFF) & 128) | (sum > 255 ? 1 : 0))
                A = UInt8(sum & 0xFF)
                let zeroFlag: UInt8 = (A == 0) ? 2 : 0
                let overflowFlag: UInt8 = (((~(tA ^ mVal) & (tA ^ sum)) & 0x80) != 0) ? 64 : 0
                ST |= zeroFlag | overflowFlag
            case 0xE0: // SBC
                let carry = (ST & 1) == 0 ? 1 : 0
                let tA = Int(A)
                let diff = tA - mVal - carry
                ST &= 20
                ST |= UInt8(((diff & 0xFF) & 128) | (diff >= 0 ? 1 : 0))
                A = UInt8(diff & 0xFF)
                let zeroFlag: UInt8 = (A == 0) ? 2 : 0
                let overflowFlag: UInt8 = ((((tA ^ mVal) & (tA ^ diff)) & 0x80) != 0) ? 64 : 0
                ST |= zeroFlag | overflowFlag
            case 0xC0: // CMP
                let diff = Int(A) - mVal
                ST &= 124
                ST |= UInt8(((diff & 0xFF) == 0 ? 2 : 0) | ((diff & 0xFF) & 128) | (diff >= 0 ? 1 : 0))
            case 0x00: // ORA
                A |= UInt8(mVal)
                ST &= 125
                ST |= UInt8((A == 0 ? 2 : 0) | (A & 128))
            case 0x20: // AND
                A &= UInt8(mVal)
                ST &= 125
                ST |= UInt8((A == 0 ? 2 : 0) | (A & 128))
            case 0x40: // EOR
                A ^= UInt8(mVal)
                ST &= 125
                ST |= UInt8((A == 0 ? 2 : 0) | (A & 128))
            case 0xA0: // LDA
                A = UInt8(mVal)
                ST &= 125
                ST |= UInt8((A == 0 ? 2 : 0) | (A & 128))
                if (IR & 3) == 3 { X = A }
            case 0x80: // STA
                let storeVal = A & (((IR & 3) == 3) ? X : 0xFF)
                memory[Int(addr)] = storeVal
                storadd = addr
            default: break
            }
        } else if (IR & 2) != 0 {
            switch IR & 0x1F {
            case 0x1E:
                let reg = ((IR & 0xC0) != 0x80) ? X : Y
                addr = UInt32(memory[Int(PC &+ 1) & 0xFFFF]) | UInt32(memory[Int(PC &+ 2) & 0xFFFF]) << 8
                addr = addr &+ UInt32(reg)
                PC = PC &+ 2
                cycles = 5
            case 0xE:
                addr = UInt32(memory[Int(PC &+ 1) & 0xFFFF]) | UInt32(memory[Int(PC &+ 2) & 0xFFFF]) << 8
                PC = PC &+ 2
                cycles = 4
            case 0x16:
                let reg = ((IR & 0xC0) != 0x80) ? X : Y
                addr = UInt32(memory[Int(PC &+ 1) & 0xFFFF] &+ reg)
                PC = PC &+ 1
                cycles = 4
            case 6:
                addr = UInt32(memory[Int(PC &+ 1) & 0xFFFF])
                PC = PC &+ 1
                cycles = 3
            case 2:
                PC = PC &+ 1
                addr = UInt32(PC)
                cycles = 2
            default: break
            }

            addr &= 0xFFFF
            switch IR & 0xE0 {
            case 0x00: // ASL
                ST &= 0xFE
                if (IR & 0xF) == 0xA {
                    ST |= (A & 128) >> 7
                    A = A << 1
                    ST &= 125
                    ST |= UInt8((A == 0 ? 2 : 0) | (A & 128))
                } else {
                    let mVal = memory[Int(addr)]
                    ST |= (mVal & 128) >> 7
                    let res = mVal << 1
                    memory[Int(addr)] = res
                    ST &= 125
                    ST |= UInt8((res == 0 ? 2 : 0) | (res & 128))
                    cycles += 2
                }
            case 0x20: // ROL
                let carry: UInt8 = (ST & 1)
                if (IR & 0xF) == 0xA {
                    let oldA = A
                    A = (A << 1) | carry
                    ST &= 60
                    ST |= ((oldA & 128) >> 7) | (A & 128) | (A == 0 ? 2 : 0)
                } else {
                    let mVal = memory[Int(addr)]
                    let res = (mVal << 1) | carry
                    memory[Int(addr)] = res
                    ST &= 60
                    ST |= ((mVal & 128) >> 7) | (res & 128) | (res == 0 ? 2 : 0)
                    cycles += 2
                }
            case 0x40: // LSR
                ST &= 0xFE
                if (IR & 0xF) == 0xA {
                    ST |= (A & 1)
                    A = A >> 1
                    ST &= 125
                    ST |= UInt8((A == 0 ? 2 : 0) | (A & 128))
                } else {
                    let mVal = memory[Int(addr)]
                    ST |= (mVal & 1)
                    let res = mVal >> 1
                    memory[Int(addr)] = res
                    ST &= 125
                    ST |= UInt8((res == 0 ? 2 : 0) | (res & 128))
                    cycles += 2
                }
            case 0x60: // ROR
                let carry: UInt8 = (ST & 1) << 7
                if (IR & 0xF) == 0xA {
                    let oldA = A
                    A = (A >> 1) | carry
                    ST &= 60
                    ST |= (oldA & 1) | (A & 128) | (A == 0 ? 2 : 0)
                } else {
                    let mVal = memory[Int(addr)]
                    let res = (mVal >> 1) | carry
                    memory[Int(addr)] = res
                    ST &= 60
                    ST |= (mVal & 1) | (res & 128) | (res == 0 ? 2 : 0)
                    cycles += 2
                }
            case 0xC0: // DEC / DEX
                if (IR & 4) != 0 {
                    var res = memory[Int(addr)]
                    res = res &- 1
                    memory[Int(addr)] = res
                    ST &= 125
                    ST |= UInt8((res == 0 ? 2 : 0) | (res & 128))
                    cycles += 2
                } else {
                    X = X &- 1
                    ST &= 125
                    ST |= UInt8((X == 0 ? 2 : 0) | (X & 128))
                }
            case 0xA0: // LDX / TAX / TSX
                if (IR & 0xF) != 0xA {
                    X = memory[Int(addr)]
                } else if (IR & 0x10) != 0 {
                    X = SP
                    ST &= 125
                    ST |= UInt8((X == 0 ? 2 : 0) | (X & 128))
                    PC = PC &+ 1; PC &= 0xFFFF; return 0
                } else {
                    X = A
                }
                ST &= 125
                ST |= UInt8((X == 0 ? 2 : 0) | (X & 128))
            case 0x80: // STX / TXS / TXA
                if (IR & 4) != 0 {
                    memory[Int(addr)] = X
                    storadd = addr
                } else if (IR & 0x10) != 0 {
                    SP = X
                } else {
                    A = X
                    ST &= 125
                    ST |= UInt8((A == 0 ? 2 : 0) | (A & 128))
                }
            case 0xE0: // INC / NOP
                if (IR & 4) != 0 {
                    var res = memory[Int(addr)]
                    res = res &+ 1
                    memory[Int(addr)] = res
                    ST &= 125
                    ST |= UInt8((res == 0 ? 2 : 0) | (res & 128))
                    cycles += 2
                }
            default: break
            }
        } else if (IR & 0xC) == 8 {
            // Implied branch instructions, stack, flags
            switch IR & 0xF0 {
            case 0x60: // PLA
                SP = SP &+ 1
                A = memory[0x100 + Int(SP)]
                ST &= 125
                ST |= UInt8((A == 0 ? 2 : 0) | (A & 128))
                cycles = 4
            case 0xC0: // INY
                Y = Y &+ 1
                ST &= 125
                ST |= UInt8((Y == 0 ? 2 : 0) | (Y & 128))
            case 0xE0: // INX
                X = X &+ 1
                ST &= 125
                ST |= UInt8((X == 0 ? 2 : 0) | (X & 128))
            case 0x80: // DEY
                Y = Y &- 1
                ST &= 125
                ST |= UInt8((Y == 0 ? 2 : 0) | (Y & 128))
            case 0x00: // PHP
                memory[0x100 + Int(SP)] = ST
                SP = SP &- 1
                cycles = 3
            case 0x20: // PLP
                SP = SP &+ 1
                ST = memory[0x100 + Int(SP)]
                cycles = 4
            case 0x40: // PHA
                memory[0x100 + Int(SP)] = A
                SP = SP &- 1
                cycles = 3
            case 0x90: // TYA
                A = Y
                ST &= 125
                ST |= UInt8((A == 0 ? 2 : 0) | (A & 128))
            case 0xA0: // TAY
                Y = A
                ST &= 125
                ST |= UInt8((Y == 0 ? 2 : 0) | (Y & 128))
            default: // Flag set/clears
                let flagIndex = Int(IR >> 5)
                let flagVal = flagsw[flagIndex]
                if (flagVal & 0x20) != 0 {
                    ST |= (flagVal & 0xDF)
                } else {
                    ST &= ~(flagVal & 0xDF)
                }
            }
        } else {
            if (IR & 0x1F) == 0x10 { // Relative Branch
                PC = PC &+ 1
                var tOffset = Int(memory[Int(PC)])
                if (tOffset & 0x80) != 0 {
                    tOffset -= 0x100
                }
                let flagCheck = branchflag[Int(IR >> 6)]
                let condition = (ST & flagCheck) != 0
                let shouldBranch = (IR & 0x20) != 0 ? condition : !condition
                if shouldBranch {
                    PC = UInt16((Int(PC) + tOffset) & 0xFFFF)
                    cycles = 3
                }
            } else {
                switch IR & 0x1F {
                case 0:
                    PC = PC &+ 1
                    addr = UInt32(PC)
                    cycles = 2
                case 0x1C:
                    addr = (UInt32(memory[Int(PC &+ 1) & 0xFFFF]) | UInt32(memory[Int(PC &+ 2) & 0xFFFF]) << 8) &+ UInt32(X)
                    PC = PC &+ 2
                    cycles = 5
                case 0xC:
                    addr = UInt32(memory[Int(PC &+ 1) & 0xFFFF]) | UInt32(memory[Int(PC &+ 2) & 0xFFFF]) << 8
                    PC = PC &+ 2
                    cycles = 4
                case 0x14:
                    addr = UInt32(memory[Int(PC &+ 1) & 0xFFFF] &+ X)
                    PC = PC &+ 1
                    cycles = 4
                case 4:
                    addr = UInt32(memory[Int(PC &+ 1) & 0xFFFF])
                    PC = PC &+ 1
                    cycles = 3
                default: break
                }

                addr &= 0xFFFF
                switch IR & 0xE0 {
                case 0x00: // BRK
                    memory[0x100 + Int(SP)] = UInt8(PC / 256)
                    SP = SP &- 1
                    memory[0x100 + Int(SP)] = UInt8(PC % 256)
                    SP = SP &- 1
                    memory[0x100 + Int(SP)] = ST
                    SP = SP &- 1
                    PC = (UInt16(memory[0xFFFE]) | UInt16(memory[0xFFFF]) << 8) &- 1
                    cycles = 7
                case 0x20: // JSR / BIT
                    if (IR & 0xF) != 0 {
                        ST &= 0x3D
                        let mVal = memory[Int(addr)]
                        let zeroFlag: UInt8 = ((A & mVal) == 0 ? 2 : 0)
                        ST |= (mVal & 0xC0) | zeroFlag
                    } else {
                        let retPC = PC &+ 1
                        memory[0x100 + Int(SP)] = UInt8(retPC / 256)
                        SP = SP &- 1
                        memory[0x100 + Int(SP)] = UInt8(retPC % 256)
                        SP = SP &- 1
                        PC = (UInt16(memory[Int(addr)]) | UInt16(memory[Int(addr + 1) & 0xFFFF]) << 8) &- 1
                        cycles = 6
                    }
                case 0x40: // RTI / JMP
                    if (IR & 0xF) != 0 {
                        PC = UInt16(addr) &- 1
                        cycles = 3
                    } else {
                        if SP >= 0xFF { return 0xFE }
                        SP = SP &+ 1
                        ST = memory[0x100 + Int(SP)]
                        SP = SP &+ 1
                        let low = UInt16(memory[0x100 + Int(SP)])
                        SP = SP &+ 1
                        let high = UInt16(memory[0x100 + Int(SP)])
                        PC = (low | high << 8) &- 1
                        cycles = 6
                    }
                case 0x60: // RTS / JMP indirect
                    if (IR & 0xF) != 0 {
                        let low = UInt16(memory[Int(addr)])
                        let high = UInt16(memory[Int((addr & 0xFF00) | UInt32((addr + 1) & 0xFF))]) // Page boundary hardware bug emulate
                        PC = (low | high << 8) &- 1
                        cycles = 5
                    } else {
                        if SP >= 0xFF { return 0xFF }
                        SP = SP &+ 1
                        let low = UInt16(memory[0x100 + Int(SP)])
                        SP = SP &+ 1
                        let high = UInt16(memory[0x100 + Int(SP)])
                        PC = (low | high << 8)
                        cycles = 6
                    }
                case 0xC0: // CPY
                    let diff = Int(Y) - Int(memory[Int(addr)])
                    ST &= 124
                    ST |= UInt8(((diff & 0xFF) == 0 ? 2 : 0) | ((diff & 0xFF) & 128) | (diff >= 0 ? 1 : 0))
                case 0xE0: // CPX
                    let diff = Int(X) - Int(memory[Int(addr)])
                    ST &= 124
                    ST |= UInt8(((diff & 0xFF) == 0 ? 2 : 0) | ((diff & 0xFF) & 128) | (diff >= 0 ? 1 : 0))
                case 0xA0: // LDY
                    Y = memory[Int(addr)]
                    ST &= 125
                    ST |= UInt8((Y == 0 ? 2 : 0) | (Y & 128))
                case 0x80: // STY
                    memory[Int(addr)] = Y
                    storadd = addr
                default: break
                }
            }
        }

        PC = PC &+ 1
        PC &= 0xFFFF
        return 0
    }

    private func combinedWF(channel: Int, wfarray: [Double], index: Int, differ6581: Bool) -> Double {
        var idx = index
        if differ6581 && SID_model == 6581.0 { idx &= 0x7FF }
        let safeIdx = max(0, min(wfarray.count - 1, idx))
        combiwf = (wfarray[safeIdx] + prevwavdata[channel]) / 2.0
        prevwavdata[channel] = wfarray[safeIdx]
        return combiwf
    }

    private func SID_core(num: Int, SIDaddr: Int) -> Double {
        SID_model = preferred_SID_model[num]
        var filtin = 0.0
        var output = 0.0

        let startChannel = num * SID_CHANNEL_AMOUNT
        for channel in startChannel..<(startChannel + SID_CHANNEL_AMOUNT) {
            let prevgate = ADSRstate[channel] & GATE_BITMASK
            let chnadd = SIDaddr + (channel - startChannel) * 7
            let ctrl = memory[chnadd + 4]
            let wf = ctrl & 0xF0
            let test = ctrl & TEST_BITMASK
            let SR = memory[chnadd + 6]
            var tmp = 0

            // ADSR Envelope
            if prevgate != (ctrl & GATE_BITMASK) {
                if prevgate != 0 {
                    ADSRstate[channel] &= UInt8(0xFF - (GATE_BITMASK | ATTACK_BITMASK | DECAYSUSTAIN_BITMASK))
                } else {
                    ADSRstate[channel] = GATE_BITMASK | ATTACK_BITMASK | DECAYSUSTAIN_BITMASK
                    if (SR & 0xF) > (prevSR[channel] & 0xF) { tmp = 1 }
                }
            }
            prevSR[channel] = SR

            ratecnt[channel] += clk_ratio
            if ratecnt[channel] >= 0x8000 { ratecnt[channel] -= 0x8000 }

            var step = 0
            var period = 0.0
            if (ADSRstate[channel] & ATTACK_BITMASK) != 0 {
                step = Int(memory[chnadd + 5] >> 4)
                period = ADSRperiods[step]
            } else if (ADSRstate[channel] & DECAYSUSTAIN_BITMASK) != 0 {
                step = Int(memory[chnadd + 5] & 0xF)
                period = ADSRperiods[step]
            } else {
                step = Int(SR & 0xF)
                period = ADSRperiods[step]
            }

            let stepRate = ADSRstep[step]

            if ratecnt[channel] >= period && ratecnt[channel] < period + clk_ratio && tmp == 0 {
                ratecnt[channel] -= period
                var expThreshold = 0.0
                let envVal = Int(envcnt[channel])
                if envVal >= 0 && envVal < ADSR_exptable.count {
                    expThreshold = ADSR_exptable[envVal]
                }
                
                expcnt[channel] += 1.0
                if (ADSRstate[channel] & ATTACK_BITMASK) != 0 || expcnt[channel] >= expThreshold {
                    if (ADSRstate[channel] & HOLDZERO_BITMASK) == 0 {
                        if (ADSRstate[channel] & ATTACK_BITMASK) != 0 {
                            envcnt[channel] += stepRate
                            if envcnt[channel] >= 0xFF {
                                envcnt[channel] = 0xFF
                                ADSRstate[channel] &= ~ATTACK_BITMASK
                            }
                        } else if (ADSRstate[channel] & DECAYSUSTAIN_BITMASK) == 0 || envcnt[channel] > Double((SR >> 4) + (SR & 0xF0)) {
                            envcnt[channel] -= stepRate
                            if envcnt[channel] <= 0.0 && envcnt[channel] + stepRate != 0.0 {
                                envcnt[channel] = 0.0
                                ADSRstate[channel] |= HOLDZERO_BITMASK
                            }
                        }
                    }
                    expcnt[channel] = 0.0
                }
            }
            envcnt[channel] = Double(Int(envcnt[channel]) & 0xFF)

            // Waveform Generator
            let accuadd = Double(UInt32(memory[chnadd]) | UInt32(memory[chnadd + 1]) << 8) * clk_ratio
            if test != 0 || ((ctrl & SYNC_BITMASK) != 0 && sourceMSBrise[num] != 0) {
                phaseaccu[channel] = 0.0
            } else {
                phaseaccu[channel] += accuadd
                if phaseaccu[channel] > 0xFFFFFF { phaseaccu[channel] -= 0x1000000 }
            }
            let MSB = Double(Int(phaseaccu[channel]) & 0x800000)
            sourceMSBrise[num] = (MSB > (prevaccu[channel].truncatingRemainder(dividingBy: 0x1000000) == 0 ? 0 : prevaccu[channel] * 0.0)) ? 1 : 0 // simplify MSB rise
            if MSB > (prevaccu[channel] - Double(Int(prevaccu[channel]) & ~0x800000)) {
                sourceMSBrise[num] = 1
            } else {
                sourceMSBrise[num] = 0
            }

            var wfout = 0.0
            if (wf & NOISE_BITMASK) != 0 {
                var lfsr = noise_LFSR[channel]
                let phaseDiff = (Int(phaseaccu[channel]) & 0x100000) != (Int(prevaccu[channel]) & 0x100000)
                if phaseDiff || accuadd >= 0x100000 {
                    let feedback = ((lfsr & 0x400000) >> 22) ^ ((lfsr & 0x20000) >> 17)
                    lfsr = ((lfsr << 1) | feedback | (test != 0 ? 1 : 0)) & 0x7FFFFF
                    noise_LFSR[channel] = lfsr
                }
                
                // Map the LFSR bits to the 12-bit noise output
                let bit0 = Double((lfsr & 0x100000) >> 5)
                let bit1 = Double((lfsr & 0x40000) >> 4)
                let bit2 = Double((lfsr & 0x4000) >> 1)
                let bit3 = Double((lfsr & 0x800) << 1)
                let bit4 = Double((lfsr & 0x200) << 2)
                let bit5 = Double((lfsr & 0x20) << 5)
                let bit6 = Double((lfsr & 0x04) << 7)
                let bit7 = Double((lfsr & 0x01) << 8)
                
                wfout = (wf & 0x70) != 0 ? 0.0 : (bit0 + bit1 + bit2 + bit3 + bit4 + bit5 + bit6 + bit7)
            } else if (wf & PULSE_BITMASK) != 0 {
                let pw = Double(UInt16(memory[chnadd + 2]) | UInt16(memory[chnadd + 3] & 0xF) << 8) * 16.0
                var tmpAcc = Double(Int(accuadd) >> 9)
                var activePw = pw
                if pw > 0.0 && pw < tmpAcc { activePw = tmpAcc }
                tmpAcc = Double(Int(accuadd) ^ 0xFFFF)
                if activePw > tmpAcc { activePw = tmpAcc }
                
                let phaseVal = Double(Int(phaseaccu[channel]) >> 8)
                if wf == PULSE_BITMASK {
                    let stepScaler = Double(Int(accuadd) >> 16)
                    let step = stepScaler > 0.0 ? 256.0 / stepScaler : 256.0
                    if test != 0 {
                        wfout = 65535.0
                    } else if phaseVal < activePw {
                        var lim = (65535.0 - activePw) * step
                        if lim > 65535.0 { lim = 65535.0 }
                        wfout = lim - (activePw - phaseVal) * step
                        if wfout < 0.0 { wfout = 0.0 }
                    } else {
                        var lim = activePw * step
                        if lim > 65535.0 { lim = 65535.0 }
                        wfout = (65535.0 - phaseVal) * step - lim
                        if wfout >= 0.0 { wfout = 65535.0 }
                        wfout = Double(Int(wfout) & 0xFFFF)
                    }
                } else {
                    wfout = (phaseVal >= activePw || test != 0) ? 65535.0 : 0.0
                    if (wf & TRI_BITMASK) != 0 {
                        if (wf & SAW_BITMASK) != 0 {
                            wfout = wfout != 0.0 ? combinedWF(channel: channel, wfarray: PulseTriSaw_8580, index: Int(phaseVal) >> 4, differ6581: true) : 0.0
                        } else {
                            let ringVal = (ctrl & RING_BITMASK) != 0 ? Int(sourceMSB[num]) : 0
                            let tmpPhase = Int(phaseaccu[channel]) ^ ringVal
                            let combinedIdx = (tmpPhase ^ ((tmpPhase & 0x800000) != 0 ? 0xFFFFFF : 0)) >> 11
                            wfout = wfout != 0.0 ? combinedWF(channel: channel, wfarray: PulseSaw_8580, index: combinedIdx, differ6581: false) : 0.0
                        }
                    } else if (wf & SAW_BITMASK) != 0 {
                        wfout = wfout != 0.0 ? combinedWF(channel: channel, wfarray: PulseSaw_8580, index: Int(phaseVal) >> 4, differ6581: true) : 0.0
                    }
                }
            } else if (wf & SAW_BITMASK) != 0 {
                wfout = Double(Int(phaseaccu[channel]) >> 8)
                if (wf & TRI_BITMASK) != 0 {
                    wfout = combinedWF(channel: channel, wfarray: TriSaw_8580, index: Int(wfout) >> 4, differ6581: true)
                } else {
                    let step = accuadd / 18874368.0 // 0x1200000
                    wfout += wfout * step
                    if wfout > 65535.0 {
                        wfout = 65535.0 - (wfout - 65536.0) / step
                    }
                }
            } else if (wf & TRI_BITMASK) != 0 {
                let ringVal = Double((ctrl & RING_BITMASK) != 0 ? Int(sourceMSB[num]) : 0)
                let combinedPhase = Double(Int(phaseaccu[channel]) ^ Int(ringVal))
                let checkVal = Int(combinedPhase) & 0x800000
                let absVal = (checkVal != 0) ? Double(0xFFFFFF - Int(combinedPhase)) : combinedPhase
                wfout = absVal / 128.0 // scale to 12-bit representation (equivalent to >> 7)
            }

            if wf != 0 { prevwfout[channel] = wfout } else { wfout = prevwfout[channel] }
            prevaccu[channel] = phaseaccu[channel]
            sourceMSB[num] = MSB

            if (memory[SIDaddr + 0x17] & FILTSW[channel]) != 0 {
                filtin += (wfout - 32768.0) * (envcnt[channel] / 256.0)
            } else if (channel % SID_CHANNEL_AMOUNT) != 2 || (memory[SIDaddr + 0x18] & OFF3_BITMASK) == 0 {
                output += (wfout - 32768.0) * (envcnt[channel] / 256.0)
            }
        }

        // Update ENV3/OSC3 read-backs
        if (memory[1] & 3) != 0 {
            memory[SIDaddr + 0x1B] = UInt8(Int(prevwfout[startChannel + 2]) >> 8)
        }
        memory[SIDaddr + 0x1C] = UInt8(envcnt[startChannel + 2])

        // Filter Math
        var cutoff = Double(memory[SIDaddr + 0x15] & 7) / 8.0 + Double(memory[SIDaddr + 0x16]) + 0.2
        var resonance = 1.0
        if SID_model == 8580.0 {
            cutoff = 1.0 - exp(cutoff * cutoff_ratio_8580)
            resonance = pow(2.0, Double(4 - (memory[SIDaddr + 0x17] >> 4)) / 8.0)
        } else {
            if cutoff < 24.0 { cutoff = 0.035 }
            else { cutoff = 1.0 - 1.263 * exp(cutoff * cutoff_ratio_6581) }
            let resNibble = memory[SIDaddr + 0x17]
            resonance = (resNibble > 0x5F) ? 8.0 / Double(resNibble >> 4) : 1.41
        }

        let bandpassVal = filtin + prevbandpass[num] * resonance + prevlowpass[num]
        var outputFiltered = output
        if (memory[SIDaddr + 0x18] & HIGHPASS_BITMASK) != 0 { outputFiltered -= bandpassVal }
        
        let nextBandpass = prevbandpass[num] - bandpassVal * cutoff
        prevbandpass[num] = nextBandpass
        if (memory[SIDaddr + 0x18] & BANDPASS_BITMASK) != 0 { outputFiltered -= nextBandpass }
        
        let nextLowpass = prevlowpass[num] + nextBandpass * cutoff
        prevlowpass[num] = nextLowpass
        if (memory[SIDaddr + 0x18] & LOWPASS_BITMASK) != 0 { outputFiltered += nextLowpass }

        let scaledVol = Double(memory[SIDaddr + 0x18] & 0xF)
        return (outputFiltered / OUTPUT_SCALEDOWN) * scaledVol
    }

    public func play() -> Double {
        lock.lock()
        defer { lock.unlock() }
        
        if loaded && initialized {
            framecnt -= 1.0
            playtime += 1.0 / samplerate

            if framecnt <= 0.0 {
                framecnt = frame_sampleperiod
                finished = false
                PC = playaddr
                SP = 0xFF
            }

            if !finished {
                let budget = clk_ratio
                var budgetRemaining = budget
                while CPUtime <= budgetRemaining {
                    pPC = PC
                    let res = CPU()
                    if res >= 0xFE {
                        finished = true
                        break
                    } else {
                        CPUtime += Double(cycles)
                    }

                    if (memory[1] & 3) > 1 && pPC < 0xE000 && (PC == 0xEA31 || PC == 0xEA81) {
                        finished = true
                        break
                    }
                    if (addr == 0xDC05 || addr == 0xDC04) && (memory[1] & 3) != 0 && timermode[subtune] != 0 {
                        frame_sampleperiod = Double(UInt16(memory[0xDC04]) | UInt16(memory[0xDC05]) << 8) / clk_ratio
                        budgetRemaining = clk_ratio
                    }
                    if storadd >= 0xD420 && storadd < 0xD800 && (memory[1] & 3) != 0 {
                        let isSec = SID_address[1] <= storadd && storadd < (SID_address[1] &+ 0x1F)
                        let isThird = SID_address[2] <= storadd && storadd < (SID_address[2] &+ 0x1F)
                        if !isSec && !isThird {
                            memory[Int(storadd & 0xD41F)] = memory[Int(storadd)]
                        }
                    }
                    // Whittaker workaround
                    if addr == 0xD404 && (memory[0xD404] & 1) == 0 { ADSRstate[0] &= 0x3E }
                    if addr == 0xD40B && (memory[0xD40B] & 1) == 0 { ADSRstate[1] &= 0x3E }
                    if addr == 0xD412 && (memory[0xD412] & 1) == 0 { ADSRstate[2] &= 0x3E }
                }
                CPUtime -= clk_ratio
            }
        }

        mix = SID_core(num: 0, SIDaddr: 0xD400)
        if SID_address[1] != 0 { mix += SID_core(num: 1, SIDaddr: Int(SID_address[1])) }
        if SID_address[2] != 0 { mix += SID_core(num: 2, SIDaddr: Int(SID_address[2])) }

        let activeVol = SIDamount_vol[min(3, max(1, SIDamount))]
        return mix * volume * activeVol
    }

    public func loadSID(sidFile: SidFileData) -> SidMetadata {
        lock.lock()
        defer { lock.unlock() }
        
        loaded = false
        initialized = false
        initSID()

        loadaddr = sidFile.loadAddr
        initaddr = sidFile.initAddr
        playaddf = sidFile.playAddr
        playaddr = sidFile.playAddr
        subtune_amount = sidFile.subtuneAmount

        for i in 0..<32 {
            timermode[i] = sidFile.timermodes[i] ? 1 : 0
        }

        // Copy C64 binary code into memory buffer
        for i in 0..<memory.count { memory[i] = 0 }
        let binary = sidFile.binaryData
        let count = binary.count
        for i in 0..<count {
            let targetIdx = Int(loadaddr) + i
            if targetIdx < memory.count {
                memory[targetIdx] = binary[i]
            }
        }

        preferred_SID_model[0] = Double(sidFile.prefModel)
        preferred_SID_model[1] = Double(sidFile.prefModel)
        preferred_SID_model[2] = Double(sidFile.prefModel)

        SID_address[1] = sidFile.secondSidAddress
        SID_address[2] = sidFile.thirdSidAddress

        SIDamount = 1 + (SID_address[1] > 0 ? 1 : 0) + (SID_address[2] > 0 ? 1 : 0)
        loaded = true

        return sidFile.metadata
    }

    public func initSubtune(sub: Int) {
        lock.lock()
        defer { lock.unlock() }
        initEmulation(subt: sub)
    }

    public func setVolume(vol: Double) {
        lock.lock()
        defer { lock.unlock() }
        self.volume = vol
    }

    private func runFrameCPU() {
        finished = false
        PC = playaddr
        SP = 0xFF
        let budget = clk_ratio * frame_sampleperiod
        var t = 0.0
        while t <= budget {
            pPC = PC
            let res = CPU()
            if res >= 0xFE { finished = true; break }
            t += Double(cycles)
            if (memory[1] & 3) > 1 && pPC < 0xE000 && (PC == 0xEA31 || PC == 0xEA81) {
                finished = true
                break
            }
            if (addr == 0xDC05 || addr == 0xDC04) && (memory[1] & 3) != 0 && timermode[subtune] != 0 {
                frame_sampleperiod = Double(UInt16(memory[0xDC04]) | UInt16(memory[0xDC05]) << 8) / clk_ratio
            }
            if storadd >= 0xD420 && storadd < 0xD800 && (memory[1] & 3) != 0 {
                let isSec = SID_address[1] <= storadd && storadd < (SID_address[1] &+ 0x1F)
                let isThird = SID_address[2] <= storadd && storadd < (SID_address[2] &+ 0x1F)
                if !isSec && !isThird {
                    memory[Int(storadd & 0xD41F)] = memory[Int(storadd)]
                }
            }
            if addr == 0xD404 && (memory[0xD404] & 1) == 0 { ADSRstate[0] &= 0x3E }
            if addr == 0xD40B && (memory[0xD40B] & 1) == 0 { ADSRstate[1] &= 0x3E }
            if addr == 0xD412 && (memory[0xD412] & 1) == 0 { ADSRstate[2] &= 0x3E }
        }
    }

    public func seek(seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        
        guard loaded else { return }
        var target = seconds > 0.0 ? seconds : 0.0
        let maxSeek = 1200.0 // 20 min hard cap
        if target > maxSeek { target = maxSeek }
        
        initEmulation(subt: subtune)
        let frames = Int(floor(target * samplerate / frame_sampleperiod))
        for _ in 0..<frames {
            runFrameCPU()
        }
        framecnt = 1.0
        CPUtime = 0.0
        finished = false
        playtime = target
    }

    public func getChannelsData() -> SidVisuals {
        lock.lock()
        defer { lock.unlock() }
        
        let envs = (
            Float(envcnt[0] / 255.0),
            Float(envcnt[1] / 255.0),
            Float(envcnt[2] / 255.0)
        )
        
        let freqs = (
            Int(UInt16(memory[0xD400]) | UInt16(memory[0xD401]) << 8),
            Int(UInt16(memory[0xD407]) | UInt16(memory[0xD408]) << 8),
            Int(UInt16(memory[0xD40E]) | UInt16(memory[0xD40F]) << 8)
        )

        let gts = (
            Int(memory[0xD404] & 1),
            Int(memory[0xD40B] & 1),
            Int(memory[0xD412] & 1)
        )

        let wfs = (
            Int(memory[0xD404] & 0xF0),
            Int(memory[0xD40B] & 0xF0),
            Int(memory[0xD412] & 0xF0)
        )

        let pws = (
            Float(Double(UInt16(memory[0xD402]) | UInt16(memory[0xD403] & 0x0F) << 8) / 4096.0),
            Float(Double(UInt16(memory[0xD409]) | UInt16(memory[0xD40A] & 0x0F) << 8) / 4096.0),
            Float(Double(UInt16(memory[0xD410]) | UInt16(memory[0xD411] & 0x0F) << 8) / 4096.0)
        )

        return SidVisuals(
            envelopes: envs,
            frequencies: freqs,
            gates: gts,
            waveforms: wfs,
            pulsewidths: pws,
            playtime: playtime
        )
    }
}

struct SafeMemory: Sendable {
    private var data = [UInt8](repeating: 0, count: 65536)
    
    subscript(index: Int) -> UInt8 {
        get {
            data[index & 0xFFFF]
        }
        set {
            data[index & 0xFFFF] = newValue
        }
    }
    
    subscript(index: UInt16) -> UInt8 {
        get {
            data[Int(index)]
        }
        set {
            data[Int(index)] = newValue
        }
    }
    
    subscript(index: UInt32) -> UInt8 {
        get {
            data[Int(index & 0xFFFF)]
        }
        set {
            data[Int(index & 0xFFFF)] = newValue
        }
    }

    var count: Int {
        return 65536
    }
}
