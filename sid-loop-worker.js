// Diese Datei wird mit derselben Engine wie das Worklet in einen Blob eingebettet.
// Lange Rekonstruktion läuft hier außerhalb des Audiothreads; Abbruch beendet
// ausschließlich diesen Worker. Keine Server- oder Netzwerkabhängigkeit.
self.onmessage = event => {
  const data = event.data;
  try {
    sampleRate = data.sampleRate;
    const engine = new SidPlayerProcessor();
    engine.setClockMode(data.clockMode);
    engine.loadSID(data.data);
    engine.initSubtune(data.subtune);
    engine.setMutedChannels(data.muted);
    engine.seek(data.start);
    self.postMessage({ snapshot: engine.captureLoop(data.end) });
  } catch (_) { self.postMessage({ error: true }); }
};
