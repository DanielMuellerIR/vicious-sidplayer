// Gemeinsame Headerauswertung für Oberfläche, AudioWorklet und Loop-Worker.
export function inspectSIDFile(data) {
  const failure = (code, message, unsupported = false) => ({ header: null, error: { code, message, unsupported } });
  if (!data || typeof data.subarray !== 'function' || data.length < 0x76) return failure('size', 'The SID header is incomplete.');
  const word = offset => (data[offset] << 8) | data[offset + 1];
  const magic = String.fromCharCode(...data.subarray(0, 4));
  if (magic !== 'PSID' && magic !== 'RSID') return failure('magic', 'The file has no PSID or RSID signature.');
  const isRSID = magic === 'RSID', version = word(4);
  if (version < 1 || version > 5 || isRSID && version === 1) return failure('version', 'Supported versions are PSID v1–v5 and RSID v2–v5.', true);
  const headerSize = version === 1 ? 0x76 : 0x7c, offset = word(6);
  if (data.length < headerSize) return failure('size', 'The SID header is incomplete.');
  if (offset < headerSize || offset > data.length || version === 5 && offset !== headerSize) return failure('offset', 'The SID data offset is invalid.');
  const flags = version >= 2 ? word(0x76) : 0;
  if (flags & 1) return failure('mus', 'MUS data requires an external player and is unsupported.', true);
  if (isRSID && (word(8) !== 0 || word(12) !== 0 || word(18) !== 0 || word(20) !== 0)) return failure('rsid', 'The RSID header has invalid load, play or timer fields.');
  if (isRSID && flags & 2) return failure('basic', 'RSID with a BASIC start requires a C64 BASIC ROM and is unsupported.', true);
  const declaredSongs = word(14), subtunesCount = Math.min(256, Math.max(1, declaredSongs));
  if (version === 5 && (declaredSongs < 1 || declaredSongs > 256)) return failure('songs', 'SID v5 requires 1 to 256 subtunes.');
  const mapping = [0x20ac,0xfffd,0x201a,0x0192,0x201e,0x2026,0x2020,0x2021,0x02c6,0x2030,0x0160,0x2039,0x0152,0xfffd,0x017d,0xfffd,0xfffd,0x2018,0x2019,0x201c,0x201d,0x2022,0x2013,0x2014,0x02dc,0x2122,0x0161,0x203a,0x0153,0xfffd,0x017e,0x0178];
  const decode = bytes => String.fromCodePoint(...Array.from(bytes, byte => byte >= 0x80 && byte <= 0x9f ? mapping[byte - 0x80] : byte)).trim();
  const metadata = data.subarray(0x16, 0x76);
  let fields = [];
  if (version === 5) {
    let position = 0;
    for (let field = 0; field < 3; field++) {
      const start = position;
      while (position < metadata.length && metadata[position] !== 0) position++;
      if (position === start || field < 2 && position === metadata.length) break;
      fields.push(decode(metadata.subarray(start, position)));
      while (position < metadata.length && metadata[position] === 0) position++;
    }
  }
  // Nichtleere Bytefelder dürfen nach dem Trimmen leer angezeigt werden.
  if (fields.length !== 3) fields = [0, 1, 2].map(index => {
    const bytes = metadata.subarray(index * 32, (index + 1) * 32), end = bytes.indexOf(0);
    return decode(end < 0 ? bytes : bytes.subarray(0, end));
  });
  const sidAddress = byte => !(byte & 1) && (byte >= 0x42 && byte <= 0x7e || byte >= 0xe0 && byte <= 0xfe) ? 0xd000 + byte * 16 : 0;
  let addresses = [0xd400, 0, 0];
  if (version === 5) {
    const configuration = data[0x7a], customStart = data[0x7b];
    if (!configuration) {
      if (customStart) return failure('addresses', 'The SID address configuration is invalid.');
    } else {
      const count = configuration & 15, layout = configuration >> 4;
      if (count < 2 || layout > 6) return failure('addresses', 'The SID address configuration is invalid.');
      if (count > 3) return failure('chips', `This file requires ${count} SID chips; the player supports at most 3.`, true);
      const steps = [[0x20], [0x40], [0x80], [0x100], [0x20, 0x60], [0x20, 0xe0], [0x100, 0x300]];
      addresses = [0xd400];
      const start = sidAddress(customStart);
      if (start) addresses.push(start);
      let index = 0;
      while (addresses.length < count) {
        let next = addresses.at(-1) + steps[layout][index++ % steps[layout].length];
        if (next >= 0xd800 && next < 0xde00) next += 0x600;
        if (next > 0xdfe0) return failure('addresses', 'The SID address configuration is invalid.');
        addresses.push(next);
      }
      while (addresses.length < 3) addresses.push(0);
    }
  } else {
    addresses[1] = version >= 3 ? sidAddress(data[0x7a]) : 0;
    addresses[2] = version >= 4 ? sidAddress(data[0x7b]) : 0;
    if (addresses[2] && addresses[1] === addresses[2]) return failure('addresses', 'The SID address configuration is invalid.');
  }
  if (version === 5 && flags & 0x800) {
    if (addresses.some(address => address >= 0xdf00)) return failure('addresses', 'SID addresses overlap the FM OPL range.');
    return failure('opl', 'FM OPL chips are unsupported.', true);
  }
  let binaryEnd = data.length, embeddedSongLengths = null;
  if (version === 5 && flags & 0x400) {
    binaryEnd -= subtunesCount * 4;
    if (binaryEnd <= offset) return failure('lengths', 'Embedded SID lengths are incomplete or invalid.');
    const bcd = value => {
      let result = 0;
      for (const shift of [12, 8, 4, 0]) { const digit = (value >> shift) & 15; if (digit > 9) return null; result = result * 10 + digit; }
      return result;
    };
    embeddedSongLengths = [];
    for (let index = 0; index < subtunesCount; index++) {
      const location = binaryEnd + index * 4, minutesSeconds = bcd(word(location)), milliseconds = bcd(word(location + 2));
      if (minutesSeconds === null || milliseconds === null || minutesSeconds % 100 >= 60 || milliseconds >= 1000) return failure('lengths', 'Embedded SID lengths are incomplete or invalid.');
      embeddedSongLengths.push(Math.floor(minutesSeconds / 100) * 60 + minutesSeconds % 100 + milliseconds / 1000);
    }
  }
  let loadAddr = word(8), binaryOffset = offset;
  if (!loadAddr) {
    if (binaryEnd < offset + 2) return failure('offset', 'The SID data offset is invalid.');
    loadAddr = data[offset] | (data[offset + 1] << 8); binaryOffset += 2;
  }
  if (binaryEnd <= binaryOffset) return failure('empty', 'The SID file contains no C64 program.');
  const initAddr = word(10) || loadAddr;
  if (isRSID && (loadAddr < 0x07e8 || initAddr < 0x07e8 || initAddr >= 0xa000 && (initAddr < 0xc000 || initAddr > 0xcfff))) return failure('rsid', 'The RSID header has invalid load or initialization fields.');
  if ((isRSID || version === 5) && (initAddr < loadAddr || initAddr >= loadAddr + binaryEnd - binaryOffset)) return failure('init', 'The SID initialization address is outside the loaded C64 program.');
  const common = (flags >> 4) & 3, prefModel = common >= 2 ? 8580 : 6581;
  const model = bits => bits >= 2 ? 8580 : bits === 1 ? 6581 : prefModel;
  const chipModels = [prefModel, version >= 3 && version <= 4 ? model((flags >> 6) & 3) : prefModel,
    version === 4 ? model((flags >> 8) & 3) : prefModel];
  const timermodes = Array.from({ length: 32 }, (_, index) => !!(data[18 + (3 - Math.floor(index / 8))] & (1 << (index % 8))));
  return { error: null, header: { title: fields[0], author: fields[1], info: fields[2], subtunesCount, prefModel,
    formatVersion: version, isRSID, addresses, chipModels, clockPreference: ['unknown', 'pal', 'ntsc', 'both'][(flags >> 2) & 3],
    activeSIDChips: [0, 1, 2].filter(chip => addresses[chip] !== 0), embeddedSongLengths, loadAddr, initAddr, playAddr: word(12),
    binaryOffset, binaryEnd, timermodes, usesRepeatedSpeedBits: !isRSID && (version === 1 || !!(flags & 2)) } };
}
