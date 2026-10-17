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
