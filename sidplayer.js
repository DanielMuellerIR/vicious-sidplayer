// Standalone C64 SID Player Wrapper
// SID-Header-Parser, abgeleitet aus einer TypeScript-Implementierung.

/**
 * Parse SID file header WITHOUT needing an AudioContext.
 * Works on the raw Uint8Array from a fetch or file upload.
 */
export function parseSidHeader(data) {
  if (data.length < 0x76) return null;
  const version = (data[4] << 8) | data[5];
  if (version < 1 || version > 4) return null;
  const headerSize = version === 1 ? 0x76 : 0x7C;
  const offset = (data[6] << 8) | data[7];
  if (data.length < headerSize || offset < headerSize || offset >= data.length) return null;
  const loadAddress = (data[8] << 8) | data[9];
  if (!loadAddress && offset + 2 >= data.length) return null;

  // Check magic: "PSID" or "RSID"
  const magic = String.fromCharCode(data[0], data[1], data[2], data[3]);
  if (magic !== 'PSID' && magic !== 'RSID') return null;
  if (magic === 'RSID' && version === 1) return null;

  const readString = (offset, len) => {
    let s = '';
    for (let i = 0; i < len; i++) {
      const ch = data[offset + i];
      if (ch === 0) break;
      s += String.fromCharCode(ch);
    }
    return s.trim();
  };

  const title = readString(0x16, 32);
  const author = readString(0x36, 32);
  const info = readString(0x56, 32);
  // PSID-songs-Feld ist 16-bit Big-Endian bei 0x0E; vorher wurde nur das untere
  // Byte (0x0F) gelesen, was bei genau 256 Subtunes 0 statt 256 ergab. Jetzt beide
  // Bytes kombinieren, damit JS mit der Swift-Seite und der PSID-Spec uebereinstimmt.
  const subtunesCount = Math.min(256, Math.max(1, (data[0x0E] << 8) | data[0x0F]));
  const prefModel = version >= 2 && (data[0x77] & 0x30) >= 0x20 ? 8580 : 6581;

  return { title, author, info, subtunesCount, prefModel };
}

export class SidPlayer {
  constructor() {
    this.audioCtx = null;
    this.workletNode = null;
    this.volume = 0.3;
    this.visualCallback = null;
    this.loadedCallback = null;
    this.loaded = false;
    this.playing = false;
    this.loadGen = 0;
    this.playGen = 0;
    this.audioGen = 0;
    this.audioSetupPromise = null;

    // Pending SID binary data (loaded without AudioContext)
    this.pendingData = null;
    this.pendingSubtune = 0;

  }

  /**
   * Initialize AudioContext and AudioWorklet.
   * MUST be called from a user gesture (click/touch) callback.
   */
  async setupAudio(workletUrl) {
    if (this.workletNode) return;
    if (!this.audioSetupPromise) {
      const pending = this.createAudio(workletUrl, this.audioGen).finally(() => {
        if (this.audioSetupPromise === pending) this.audioSetupPromise = null;
      });
      this.audioSetupPromise = pending;
    }
    return this.audioSetupPromise;
  }

  async createAudio(workletUrl, generation) {

    if (!this.audioCtx) {
      const AudioContextClass = window.AudioContext || window.webkitAudioContext;
      this.audioCtx = new AudioContextClass();

      // Bypasses iOS hardware silent switch for Web Audio API (supported on Safari 16.4+)
      if (typeof navigator !== 'undefined' && navigator.audioSession) {
        try {
          navigator.audioSession.type = 'playback';
        } catch (err) {
          console.warn('Failed to set navigator.audioSession.type to playback:', err);
        }
      }
    }

    const ctx = this.audioCtx;

    if (ctx.state === 'suspended') {
      try {
        await ctx.resume();
      } catch (err) {
        console.warn('SidPlayer: Failed to resume AudioContext:', err);
      }
    }

    if (generation !== this.audioGen) return;

    // iOS Safari unlock
    try {
      const buffer = ctx.createBuffer(1, 1, 22050);
      const source = ctx.createBufferSource();
      source.buffer = buffer;
      source.connect(ctx.destination);
      source.start(0);
      // Den Ein-Sample-Stummschuss sofort wieder vom Graphen trennen, damit der
      // Source-Knoten nach dem Auslaufen GC-faehig ist und nicht im AudioContext
      // haengen bleibt.
      source.disconnect();
    } catch (e) {
      console.warn('SidPlayer: iOS unlock buffer failed:', e);
    }

    if (!ctx.__sidWorkletAdded) {
      // Die Single-File-Ausgabe uebergibt den eingebetteten Worklet-Quelltext als Data-URL.
      await ctx.audioWorklet.addModule(workletUrl);
      ctx.__sidWorkletAdded = true;
    }

    if (generation !== this.audioGen) return;
    this.workletNode = new AudioWorkletNode(ctx, 'sid-player-worklet', {
      outputChannelCount: [2]
    });

    this.workletNode.connect(ctx.destination);
    this.workletNode.port.onmessage = (e) => {
      const data = e.data;
      if (data.type === 'visualizer') {
        if (this.visualCallback) this.visualCallback(data.data);
      } else if (data.type === 'loaded' && data.generation === this.loadGen) {
        this.loaded = true;
      }
    };

    this.workletNode.port.postMessage({ type: 'setVolume', volume: this.volume });
  }

  /**
   * Fetch SID file from URL and parse header.
   * Does NOT touch AudioContext — safe to call anytime.
   */
  async load(url, subtune = 0) {
    const myGen = ++this.loadGen;
    this.stop();
    this.loaded = false;
    this.pendingData = null;

    const res = await fetch(url);
    if (!res.ok) throw new Error(`Fetch failed: ${res.status} ${res.statusText}`);
    const buf = await res.arrayBuffer();
    const uint8 = new Uint8Array(buf);

    if (myGen !== this.loadGen) return; // stale

    const meta = parseSidHeader(uint8);
    if (!meta) throw new Error('Invalid SID file (bad header)');

    this.pendingData = uint8;
    this.pendingSubtune = subtune;
    this.loaded = true;

    // If worklet already running, send data immediately
    if (this.workletNode) {
      this.workletNode.port.postMessage({ type: 'load', data: uint8, subtune, generation: this.loadGen });
      this.pendingData = null;
    }

    if (this.loadedCallback) this.loadedCallback(meta);
  }

  /**
   * Load SID from a Uint8Array buffer (user upload).
   * Does NOT touch AudioContext — safe to call anytime.
   */
  async loadBuffer(uint8, subtune = 0) {
    // loadBuffer laeuft komplett synchron durch (kein await), daher waere ein
    // eigener Generations-Check hier wirkungslos und wurde entfernt. Der Counter
    // wird dennoch erhoeht, damit ein evtl. noch laufender asynchroner load()
    // (mit await fetch) sich anschliessend selbst als stale erkennt.
    this.loadGen++;
    this.stop();
    this.loaded = false;
    this.pendingData = null;

    const meta = parseSidHeader(uint8);
    if (!meta) throw new Error('Invalid SID file (bad header)');

    this.pendingData = uint8;
    this.pendingSubtune = subtune;
    this.loaded = true;

    // If worklet already running, send data immediately
    if (this.workletNode) {
      this.workletNode.port.postMessage({ type: 'load', data: uint8, subtune, generation: this.loadGen });
      this.pendingData = null;
    }

    if (this.loadedCallback) this.loadedCallback(meta);
  }

  /**
   * Start playback. Sets up AudioContext on first call (requires user gesture).
   * If SID data has been loaded, sends it to the worklet before playing.
   */
  async play(workletUrl) {
    const generation = ++this.playGen;
    await this.setupAudio(workletUrl);
    if (generation !== this.playGen || !this.workletNode || !this.loaded) return;
    if (this.audioCtx.state === 'suspended') await this.audioCtx.resume();
    if (generation !== this.playGen || !this.workletNode) return;
    if (this.pendingData) {
      this.workletNode.port.postMessage({
        type: 'load', data: this.pendingData, subtune: this.pendingSubtune,
        generation: this.loadGen
      });
      this.pendingData = null;
    }
    // Port-Nachrichten behalten ihre Reihenfolge: load liegt sicher vor play.
    this.workletNode.port.postMessage({ type: 'play' });
    this.playing = true;
  }

  stop() {
    this.playGen++;
    if (this.workletNode) this.workletNode.port.postMessage({ type: 'stop' });
    this.playing = false;
  }

  setSubtune(subtune) {
    this.pendingSubtune = subtune;
    if (this.workletNode) {
      this.workletNode.port.postMessage({ type: 'setSubtune', subtune });
    }
  }

  /**
   * Seek to a position in seconds. The worklet restarts the current subtune and
   * fast-forwards the emulation.
   * codereview-ok: Worklet clampt NaN->0; lastVisuals.playtime nie NaN (2026-07-01)
   */
  seek(seconds) {
    if (this.workletNode) {
      this.workletNode.port.postMessage({ type: 'seek', seconds });
    }
  }

  setVolume(volume) {
    this.volume = volume;
    if (this.workletNode) {
      this.workletNode.port.postMessage({ type: 'setVolume', volume });
    }
  }

  watchVisuals(callback) {
    this.visualCallback = callback;
  }

  watchLoaded(callback) {
    this.loadedCallback = callback;
  }

  unload() {
    this.loadGen++;
    this.audioGen++;
    this.audioSetupPromise = null;
    this.stop();
    if (this.workletNode) {
      try {
        this.workletNode.port.onmessage = null;
        this.workletNode.disconnect();
      } catch (_) {}
    }
    this.workletNode = null;
    this.loaded = false;
    this.playing = false;
    this.pendingData = null;

    this.visualCallback = null;
    this.loadedCallback = null;
  }

  resumeContext() {
    if (this.audioCtx && this.audioCtx.state === 'suspended') {
      this.audioCtx.resume().catch(() => {});
    }
  }
}
