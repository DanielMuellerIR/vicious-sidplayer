import { inspectSIDFile } from './sid-format.js';
// Standalone C64 SID Player Wrapper
// SID-Header-Parser, abgeleitet aus einer TypeScript-Implementierung.

/**
 * Parse SID file header WITHOUT needing an AudioContext.
 * Works on the raw Uint8Array from a fetch or file upload.
 */
export function parseSidHeader(data) { return inspectSIDFile(data).header; }
export function sidFileDiagnostic(data) { return inspectSIDFile(data).error; }

export class SidPlayer {
  constructor() {
    this.audioCtx = null;
    this.workletNode = null;
    this.volume = 0.3;
    this.clockMode = 'auto';
    this.mutedChannels = Array(9).fill(false);
    this.visualCallback = null;
    this.loadedCallback = null;
    this.loaded = false;
    this.playing = false;
    this.seeking = false;
    this.seekRequest = 0;
    this.loadGen = 0;
    this.playGen = 0;
    this.audioGen = 0;
    this.audioSetupPromise = null;
    this.loopData = null;
    this.loopRange = null;
    this.loopRequest = 0;
    this.loopWorker = null;
    this.loopReady = false;
    this.loopWorkerSource = null;
    this.loopStateCallback = null;

    // Pending SID binary data (loaded without AudioContext)
    this.pendingData = null;
    this.pendingSubtune = 0;
    this.pendingSeekSeconds = null;

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
      if (data.type === 'visualizer' && data.generation === this.loadGen) {
        if (this.visualCallback) this.visualCallback(data.data);
      } else if (data.type === 'seekComplete' && data.generation === this.loadGen && data.request === this.seekRequest) {
        this.seeking = false;
      } else if (data.type === 'loopReady' && data.generation === this.loadGen && data.request === this.loopRequest) {
        this.loopReady = data.installed;
        if (!data.installed) this.setLoopRange(null);
        this.loopStateCallback?.(data.installed ? 'ready' : 'error');
      } else if (data.type === 'loaded' && data.generation === this.loadGen) {
        this.loaded = true;
      }
    };

    this.workletNode.port.postMessage({ type: 'setVolume', volume: this.volume });
    this.workletNode.port.postMessage({ type: 'setClockMode', mode: this.clockMode });
    this.workletNode.port.postMessage({ type: 'setMutedChannels', muted: this.mutedChannels });
  }

  /**
   * Fetch SID file from URL and parse header.
   * Does NOT touch AudioContext — safe to call anytime.
   */
  async load(url, subtune = 0) {
    const myGen = ++this.loadGen;
    this.setLoopRange(null);
    this.pendingSeekSeconds = null;
    this.seeking = false;
    this.stop();
    this.loaded = false;
    this.pendingData = null;

    const res = await fetch(url);
    if (!res.ok) throw new Error(`Fetch failed: ${res.status} ${res.statusText}`);
    const buf = await res.arrayBuffer();
    const uint8 = new Uint8Array(buf);

    if (myGen !== this.loadGen) return; // stale

    const meta = parseSidHeader(uint8);
    if (!meta) throw new Error(sidFileDiagnostic(uint8)?.message || 'Invalid SID file (bad header)');

    this.setLoopRange(null);
    this.loopData = uint8.slice();
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
    this.setLoopRange(null);
    this.pendingSeekSeconds = null;
    this.seeking = false;
    this.stop();
    this.loaded = false;
    this.pendingData = null;

    const meta = parseSidHeader(uint8);
    if (!meta) throw new Error(sidFileDiagnostic(uint8)?.message || 'Invalid SID file (bad header)');

    this.setLoopRange(null);
    this.loopData = uint8.slice();
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
    // Port-Nachrichten behalten ihre Reihenfolge: load und vorbereiteter Seek
    // liegen vor play, auch bei Wiederherstellung vor dem ersten Audiostart.
    if (this.pendingSeekSeconds != null) {
      this.seeking = true;
      this.workletNode.port.postMessage({ type: 'seek', seconds: this.pendingSeekSeconds, request: ++this.seekRequest });
      this.pendingSeekSeconds = null;
    }
    this.workletNode.port.postMessage({ type: 'play' });
    this.playing = true;
    if (this.loopRange && !this.loopWorker && !this.loopReady) this.refreshLoop();
  }

  stop() {
    this.playGen++;
    if (this.workletNode) this.workletNode.port.postMessage({ type: 'stop' });
    this.playing = false;
  }

  setMutedChannels(muted) {
    if (!Array.isArray(muted) || muted.length !== 9 || !muted.every(value => typeof value === 'boolean')) return false;
    this.mutedChannels = [...muted];
    this.workletNode?.port.postMessage({ type: 'setMutedChannels', muted: this.mutedChannels });
    this.refreshLoop();
    return true;
  }

  setSubtune(subtune) {
    this.setLoopRange(null);
    this.pendingSubtune = subtune;
    this.pendingSeekSeconds = null;
    this.seeking = false;
    this.loadGen++;
    if (this.workletNode) {
      this.workletNode.port.postMessage({ type: 'setSubtune', subtune, generation: this.loadGen });
    }
  }

  /**
   * Seek to a position in seconds. The worklet restarts the current subtune and
   * fast-forwards the emulation.
   * codereview-ok: Worklet clampt NaN->0; lastVisuals.playtime nie NaN (2026-07-01)
   */
  seek(seconds) {
    const target = Number.isFinite(seconds) ? Math.max(0, seconds) : 0;
    if (this.loopRange && (target < this.loopRange[0] || target > this.loopRange[1])) this.setLoopRange(null);
    if (this.workletNode) {
      this.seeking = true;
      this.workletNode.port.postMessage({ type: 'seek', seconds: target, request: ++this.seekRequest });
    } else { this.pendingSeekSeconds = target; }
    this.refreshLoop();
  }

  setVolume(volume) {
    this.volume = volume;
    if (this.workletNode) {
      this.workletNode.port.postMessage({ type: 'setVolume', volume });
    }
  }

  setClockMode(mode) {
    this.clockMode = ['pal', 'ntsc'].includes(mode) ? mode : 'auto';
    if (this.workletNode) {
      this.seeking = this.loaded;
      this.workletNode.port.postMessage({ type: 'setClockMode', mode: this.clockMode, request: ++this.seekRequest });
    }
    this.refreshLoop();
  }

  setLoopRange(range, workerSource = this.loopWorkerSource) {
    if (range && (!Array.isArray(range) || range.length !== 2 || !range.every(Number.isFinite)
        || range[0] < 0 || range[0] > 1200 || range[1] - range[0] < 0.25)) return false;
    this.loopRange = range ? [...range] : null;
    this.loopWorkerSource = workerSource;
    this.refreshLoop();
    return true;
  }

  refreshLoop() {
    this.loopReady = false;
    const request = ++this.loopRequest, generation = this.loadGen;
    this.loopWorker?.terminate(); this.loopWorker = null;
    this.workletNode?.port.postMessage({ type: 'prepareLoop', request });
    if (!this.loopRange) { this.loopStateCallback?.('off'); return; }
    if (!this.workletNode || !this.loopData) { this.loopStateCallback?.('waiting'); return; }
    this.loopStateCallback?.('preparing');
    try {
      if (typeof this.loopWorkerSource !== 'string' || !this.loopWorkerSource.trim()) throw new Error('Loop worker source unavailable');
      const url = URL.createObjectURL(new Blob([this.loopWorkerSource], { type: 'application/javascript' }));
      let worker;
      try { worker = new Worker(url); } finally { URL.revokeObjectURL(url); }
      this.loopWorker = worker;
      const fail = () => {
        if (request !== this.loopRequest || generation !== this.loadGen) return;
        this.setLoopRange(null); this.loopStateCallback?.('error');
      };
      worker.onerror = fail;
      worker.onmessage = event => {
        if (request !== this.loopRequest || generation !== this.loadGen) return;
        if (event.data.error) { fail(); return; }
        worker.terminate(); this.loopWorker = null;
        this.workletNode?.port.postMessage({ type: 'installLoop', snapshot: event.data.snapshot, request, generation });
      };
      worker.postMessage({ sampleRate: this.audioCtx.sampleRate, data: this.loopData,
        subtune: this.pendingSubtune, clockMode: this.clockMode, muted: this.mutedChannels,
        start: this.loopRange[0], end: this.loopRange[1] });
    } catch (_) { this.setLoopRange(null); this.loopStateCallback?.('error'); }
  }

  watchVisuals(callback) {
    this.visualCallback = callback;
  }

  watchLoaded(callback) {
    this.loadedCallback = callback;
  }

  unload() {
    this.setLoopRange(null);
    this.loopData = null;
    this.loadGen++;
    this.audioGen++;
    this.seeking = false;
    this.pendingSeekSeconds = null;
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
