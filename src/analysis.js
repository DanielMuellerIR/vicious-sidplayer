class WebAnalysisMix {
  constructor() { this.channelMuted = Array(9).fill(false); this.chipMuted = Array(3).fill(false); this.soloChannels = new Set(); }
  toggleChannelMuted(channel) {
    if (Number.isInteger(channel) && channel >= 0 && channel < 9) this.channelMuted[channel] = !this.channelMuted[channel];
  }
  toggleChipMuted(chip) {
    if (Number.isInteger(chip) && chip >= 0 && chip < 3) this.chipMuted[chip] = !this.chipMuted[chip];
  }
  toggleSolo(channel) {
    if (!Number.isInteger(channel) || channel < 0 || channel >= 9) return;
    if (this.soloChannels.has(channel)) this.soloChannels.delete(channel); else this.soloChannels.add(channel);
  }
  clearSolos() { this.soloChannels.clear(); }
  effectiveMuted(activeChips) {
    const active = new Set(activeChips.filter(chip => Number.isInteger(chip) && chip >= 0 && chip < 3));
    const solos = new Set([...this.soloChannels].filter(channel => active.has(Math.floor(channel / 3))));
    return Array.from({ length: 9 }, (_, channel) => !active.has(Math.floor(channel / 3)) || this.chipMuted[Math.floor(channel / 3)]
      || this.channelMuted[channel] || solos.size > 0 && !solos.has(channel));
  }
}

class WebPlaybackLoop {
  constructor() { this.start = null; this.end = null; this.enabled = false; }
  get range() { return this.start != null && this.end != null && this.end - this.start >= 0.25 ? [this.start, this.end] : null; }
  setStart(seconds, duration) {
    if (!Number.isFinite(seconds) || !Number.isFinite(duration) || duration < 0) return;
    this.start = Math.max(0, Math.min(duration, seconds));
    if (this.end != null && this.end - this.start < 0.25) this.end = null;
    if (!this.range) this.enabled = false;
  }
  setEnd(seconds, duration) {
    if (!Number.isFinite(seconds) || !Number.isFinite(duration) || duration < 0 || this.start == null) return;
    const end = Math.max(0, Math.min(duration, seconds));
    if (end - this.start >= 0.25) this.end = end;
  }
  setEnabled(enabled) { this.enabled = Boolean(enabled && this.range); }
  clear() { this.start = this.end = null; this.enabled = false; }
}
function sidPitch(register, clock, waveform, envelope) {
  if (!Number.isInteger(register) || register < 1 || register > 65535 || ![0x10, 0x20, 0x40].includes(waveform)
      || !Number.isFinite(envelope) || envelope <= 0.001) return null;
  const hertz = register * (clock === 'ntsc' ? 1022727 : 985248) / 16777216;
  const note = 69 + 12 * Math.log2(hertz / 440), midiNote = Math.round(note);
  if (midiNote < 0 || midiNote > 127) return null;
  const names = ['C', 'C♯', 'D', 'D♯', 'E', 'F', 'F♯', 'G', 'G♯', 'A', 'A♯', 'B'];
  return { hertz, midiNote, cents: (note - midiNote) * 100, name: names[midiNote % 12] + (Math.floor(midiNote / 12) - 1) };
}
function sidRegisterLabel(offset) {
  if (offset < 21) return `V${Math.floor(offset / 7) + 1} ${['FREQ LO', 'FREQ HI', 'PULSE LO', 'PULSE HI', 'CONTROL', 'ATTACK/DECAY', 'SUSTAIN/RELEASE'][offset % 7]}`;
  return ({ 21: 'CUTOFF LO', 22: 'CUTOFF HI', 23: 'RESONANCE/ROUTING', 24: 'MODE/VOLUME', 27: 'OSC3 (emulated)', 28: 'ENV3 (emulated)' })[offset] || '—';
}
