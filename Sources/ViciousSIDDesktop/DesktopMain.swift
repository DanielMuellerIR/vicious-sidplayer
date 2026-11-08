import Foundation
import ViciousSIDPlayerCore

// Lokale, vererbte stdin/stdout-Pipe: kein Listener, kein HTTP-Dienst und keine
// von Webseiten erreichbare Dateischnittstelle. Jede Zeile ist ein JSON-Objekt.
@main
struct DesktopMain {
  static func main() async {
    let args = CommandLine.arguments
    func argument(_ key: String) -> String? {
      args.firstIndex(of: key).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }
    let support =
      argument("--support-dir").map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? MusicLibraryLocation.support()!
    let engine = DesktopEngine(support: support, root: argument("--root"))
    await engine.start()
    while let line = await Task.detached(operation: { readLine() }).value {
      do {
        let data = Data(line.utf8)
        guard let command = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
          continue
        }
        if await engine.handle(command) { break }
      } catch { engine.emit(["event": "error", "message": error.localizedDescription]) }
    }
    await engine.shutdown()
  }
}

@MainActor
final class DesktopEngine {
  let audio: DesktopAudio
  let support: URL
  let favoritesStore: PersonalCollectionFavoritesStore
  let listening: ListeningLibraryController
  let history: ListeningHistoryController
  let playback: PlaybackOptionsController
  let metadata = LibraryMetadataController()
  let saved: SavedLibrarySearchController
  let exporter = AudioExportController()
  let lengths: SongLengthResolver
  var collection: PersonalCollectionController!
  var root: URL
  var library: MusicLibrary?
  var playlist = Playlist()
  var currentIndex = -1
  var md5: String?
  var database: SonglengthDB?
  var stil: STILDatabase?
  var stilRoot: URL?
  var favorites = PlaylistFavorites()
  var settings: [String: Any] = [:]
  var scanTask: Task<Void, Never>?
  var ticker: Task<Void, Never>?
  var estimateTask: Task<Void, Never>?
  var scanGeneration = 0
  var isScanning = false
  var revision = 0
  var playbackIntentRevision = 0
  var collectionPlaybackIntent: Int?
  var query = ""
  var favoritesOnly = false
  var folders = false
  var expanded: Set<String> = []
  var folderTree = MusicLibrary.folderTree(for: [])
  var visibleIndices: [Int] = []
  var lastLibrarySignature = ""
  var lastSessionBucket = -1
  var errorMessage: String?
  var isClosing = false
  var suppressStartupAutoplay = false
  var initialRestoreComplete = false
  var settingsWritable = true
  var pendingRemoteTrack: String?
  var publishedListening: ListeningLibraryDocument?
  var publishedHistory: ListeningHistoryDocument?
  var publishedPlayback: PlaybackSettingsDocument?
  var publishedExportItems: [AudioExportItem]?
  var publishedExportSelection: Set<Int>?
  var collectionStamp = ""
  var collectionExportNotice: String?
  var lastLibraryPublication = 0.0
  var lastLibraryRevision = -1
  var shuffle: Bool { settings["shuffle"] as? Bool ?? false }
  var autoNext: Bool { settings["autoNext"] as? Bool ?? true }
  var currentTrack: PlaylistTrack? { playlist.track(at: currentIndex) }
  var reference: ListeningPersonalReference? {
    guard let track = currentTrack, let md5 else { return nil }
    return .init(libraryID: libraryID, trackID: track.id, md5: md5, subtune: audio.subtune)
  }
  var libraryID: String { MusicLibrary.indexFileName(forRoot: root) }
  var resolution: SongLengthSelection.Resolution {
    lengths.durationResolution(
      md5: md5 ?? "", subtune: audio.subtune,
      databaseLengths: md5.flatMap { database?.lengths(forMD5: $0) },
      clockMode: audio.clockMode,
      personalDuration: playback.document.endTime(md5: md5, subtune: audio.subtune),
      embeddedLengths: audio.sid?.embeddedSongLengths)
  }

  init(support: URL, root: String?, audio: DesktopAudio = DesktopAudio()) {
    self.audio = audio
    self.support = support
    lengths = SongLengthResolver(
      cache: SongLengthCache(fileURL: support.appendingPathComponent("song-length-cache.json")))
    favoritesStore = PersonalCollectionFavoritesStore(
      fileURL: support.appendingPathComponent("favorites.json"))
    let startup = PersonalCollectionStartup(supportURL: support, favorites: favoritesStore)
    listening = ListeningLibraryController(
      fileURL: support.appendingPathComponent(ListeningLibraryStore.fileName), startup: startup)
    history = ListeningHistoryController(
      fileURL: support.appendingPathComponent(ListeningHistoryStore.fileName), startup: startup)
    playback = PlaybackOptionsController(
      fileURL: support.appendingPathComponent(PlaybackSettingsStore.fileName), startup: startup)
    saved = SavedLibrarySearchController(
      fileURL: support.appendingPathComponent("saved-searches.json"))
    let settingsURL = support.appendingPathComponent("desktop-settings.json")
    if FileManager.default.fileExists(atPath: settingsURL.path) {
      do {
        let data = try Data(contentsOf: settingsURL)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          (value["version"] as? Int ?? 1) == 1
        else { throw CocoaError(.fileReadCorruptFile) }
        settings = value
      } catch {
        settingsWritable = false
        errorMessage =
          "Die Desktop-Einstellungen sind nicht lesbar. Die vorhandene Datei bleibt erhalten."
      }
    }
    self.root = URL(
      fileURLWithPath: root ?? (settings["root"] as? String)
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
          AutoplayFolder.defaultRelativePath
        ).path,
      isDirectory: true)
    favorites = PlaylistFavorites(storedValues: favoritesStore.read().sorted(), root: self.root)
    folders = settings["folders"] as? Bool ?? false
    expanded = Set(settings["expanded"] as? [String] ?? [])
    settings.removeValue(forKey: "volume")
    settings.removeValue(forKey: "autoNext")
  }
  func start() async {
    audio.onFailure = { [weak self] message in
      self?.errorMessage = message
      self?.emit(["event": "error", "message": message])
    }
    await listening.ready()
    await history.ready()
    await playback.ready()
    playback.onStopRequested = { [weak self] in
      self?.observe(force: true, playing: false)
      self?.audio.stop()
    }
    collection = PersonalCollectionController(
      listening: listening, history: history, playback: playback, favorites: favoritesStore,
      supportURL: support,
      context: { [unowned self] in
        .init(
          libraryID: libraryID, name: root.lastPathComponent,
          library: library ?? MusicLibrary(root: root, supportDirectory: support),
          openedFiles: playlist.tracks.filter(\.isExternal))
      },
      pause: { [unowned self] in pauseForCollection() },
      resume: { [unowned self] in resumeAfterCollection() },
      didApply: { [unowned self] in
        favorites = PlaylistFavorites(ids: favoritesStore.read())
        revision += 1
      },
      auditMetadata: { [unowned self] in
        .init(
          stil: stil, stilRoot: stilRoot, lengths: database, resolver: lengths,
          clockMode: audio.clockMode)
      })
    rescan(initial: true)
    ticker = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(100))
        guard !Task.isCancelled, let self, !self.isClosing else { return }
        await self.tick()
      }
    }
    emit(["event": "ready", "settings": settings, "root": root.path])
  }
  func emit(_ object: [String: Any]) {
    guard JSONSerialization.isValidJSONObject(object),
      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
  }
  func pauseForCollection() -> Bool {
    collectionPlaybackIntent = playbackIntentRevision
    let playing = audio.state == "Playing"
    try? audio.pause()
    return playing
  }
  func resumeAfterCollection() {
    guard collectionPlaybackIntent == playbackIntentRevision else { return }
    try? audio.play()
  }
  func encoded<T: Encodable>(_ value: T) -> Any {
    (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value))) ?? NSNull()
  }
  func saveSettings() throws {
    guard settingsWritable else { throw CocoaError(.fileWriteNoPermission) }
    settings["version"] = 1
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    settings["root"] = root.path
    settings["folders"] = folders
    settings["expanded"] = expanded.sorted()
    var persisted = settings
    persisted.removeValue(forKey: "autoNext")
    try JSONSerialization.data(withJSONObject: persisted, options: [.sortedKeys]).write(
      to: support.appendingPathComponent("desktop-settings.json"), options: .atomic)
  }
  func observe(force: Bool = false, playing: Bool? = nil) {
    history.observe(
      reference: reference, title: audio.sid?.metadata.title ?? currentTrack?.name ?? "",
      position: audio.elapsed,
      knownDuration: resolution.source == .fallback ? nil : resolution.seconds,
      isPlaying: playing ?? (audio.state == "Playing"), force: force)
  }
  func tick() async {
    playback.refreshSleepTimer()
    guard !audio.isSeeking else { return }
    observe()
    let duration = resolution
    let previousLoop = audio.loop
    audio.loop.constrain(to: duration.seconds)
    if audio.loop != previousLoop { refreshLoop() }
    let envelope = playback.fadeEnvelope(
      duration: duration.seconds, elapsed: audio.elapsed, autoNext: autoNext,
      hasPersonalEnd: duration.source == .personal)
    audio.processor?.setFadeEnvelope(
      audio.loop.isEnabled
        ? PlaybackFadeEnvelope(timerEnd: envelope.timerEnd, seconds: envelope.seconds) : envelope)
    if let action = PlaybackCompletionPolicy.action(
      isPlaying: audio.state == "Playing", elapsed: audio.elapsed, duration: duration.seconds,
      currentSubtune: audio.subtune, subtuneCount: audio.sid?.subtuneAmount ?? 0,
      entry: listening.queue?.current, autoNext: autoNext,
      repeatMode: playback.document.repeatMode, hasExplicitEnd: duration.source == .personal,
      stopAfterSubtune: playback.stopAfterSubtune, loopEnabled: audio.loop.isEnabled)
    {
      do {
        switch action {
        case .stop:
          observe(force: true, playing: false)
          audio.stop()
          playback.finishSubtuneStop()
        case .subtune(let sub):
          try setSubtune(sub)
          try audio.play()
        case .advanceEntry(let repeats): try next(previous: false, allowCycle: repeats)
        }
      } catch { report(error) }
    }
    let bucket = Int(audio.elapsed / 5)
    if bucket != lastSessionBucket {
      lastSessionBucket = bucket
      persistSession()
    }
  }
  func persistSession() {
    guard !shuffle, initialRestoreComplete else { return }
    settings["lastTrack"] = currentTrack?.id
    settings["lastSubtune"] = audio.subtune
    settings["lastPosition"] = audio.elapsed
    do { try saveSettings() } catch { report(error) }
  }
  func refreshLoop() {
    Task {
      do { try await audio.installLoop() } catch is CancellationError {} catch { report(error) }
    }
  }
  func report(_ error: Error) {
    errorMessage = error.localizedDescription
    emit(["event": "error", "message": error.localizedDescription])
  }
  func rescan(initial: Bool = false) {
    scanGeneration += 1
    let generation = scanGeneration
    scanTask?.cancel()
    metadata.cancel(clear: true)
    lengths.cancel()
    estimateTask?.cancel()
    let root = root
    let support = support
    let restoredID = settings["lastTrack"] as? String
    let restoredSubtune = settings["lastSubtune"] as? Int ?? 0
    let restoredPosition = settings["lastPosition"] as? Double ?? 0
    isScanning = true
    scanTask = Task { [weak self] in
      let library = await Task.detached {
        MusicLibrary(
          root: root, supportDirectory: support,
          indexFileName: MusicLibrary.indexFileName(forRoot: root))
      }.value
      guard let self, generation == scanGeneration, !Task.isCancelled else { return }
      self.library = library
      await acceptLibrary(library)
      if initial, !playlist.isEmpty, currentIndex < 0 {
        await startInitialTrack(
          id: restoredID, subtune: restoredSubtune, position: restoredPosition)
      }
      let result = await Task.detached { Result { try library.refresh() } }.value
      guard generation == scanGeneration, !Task.isCancelled else { return }
      switch result {
      case .success: await acceptLibrary(library)
      case .failure(let error): report(error)
      }
      isScanning = false
      revision += 1
      await loadDatabases()
      if let id = pendingRemoteTrack {
        pendingRemoteTrack = nil
        if let index = playlist.index(forID: id) {
          do { try load(index, autoplay: true) } catch { report(error) }
        }
      }
      if initial, currentIndex < 0, !playlist.isEmpty {
        await startInitialTrack(
          id: restoredID, subtune: restoredSubtune, position: restoredPosition)
      }
      if initial { initialRestoreComplete = true }
      scanTask = nil
    }
  }
  func startInitialTrack(id: String?, subtune: Int, position: Double) async {
    do {
      if let entry = listening.queue?.current, let index = playlist.index(forID: entry.trackID) {
        try load(index, autoplay: false, updateQueue: false)
        try setSubtune(entry.subtune ?? (entry.trackID == id ? subtune : 0))
        if entry.trackID == id { try await audio.seek(position) }
      } else if !shuffle, let id, let index = playlist.index(forID: id) {
        try load(index, autoplay: false)
        try setSubtune(subtune)
        try await audio.seek(position)
      } else {
        try load(shuffle ? Int.random(in: 0..<playlist.count) : 0, autoplay: false)
      }
      initialRestoreComplete = true
      if !suppressStartupAutoplay { try audio.play() }
    } catch { report(error) }
  }
  func acceptLibrary(_ library: MusicLibrary) async {
    currentIndex = playlist.setLibrary(library.entries, root: root, keepingTrackAt: currentIndex)
    let entries = library.entries
    folderTree = await Task.detached { MusicLibrary.folderTree(for: entries) }.value
    metadata.refresh(library: library)
    listening.activateLibrary(
      libraryID, tracks: playlist.tracks.map { ListeningEntry(trackID: $0.id) })
    revision += 1
  }
  func loadDatabases() async {
    let root = root
    let songPath = settings["songlengths"] as? String ?? ""
    let stilPath = settings["stil"] as? String ?? ""
    let data = await Task.detached {
      let dbURL =
        songPath.isEmpty
        ? SonglengthDB.autodetect(nearFolder: root) : URL(fileURLWithPath: songPath)
      let stilURL =
        stilPath.isEmpty
        ? STILDatabase.autodetect(nearFolder: root) : URL(fileURLWithPath: stilPath)
      return (
        dbURL.flatMap { try? SonglengthDB.load(url: $0) },
        stilURL.flatMap { try? STILDatabase.load(url: $0) }, stilURL.map(STILDatabase.hvscRoot)
      )
    }.value
    database = data.0
    stil = data.1
    stilRoot = data.2
    planLength()
    revision += 1
  }
  func planLength() {
    let plan = lengths.plan(
      md5: md5, subtune: audio.subtune,
      databaseLengths: md5.flatMap { database?.lengths(forMD5: $0) }, fileURL: currentTrack?.url,
      clockMode: audio.clockMode,
      personalDuration: playback.document.endTime(md5: md5, subtune: audio.subtune),
      embeddedLengths: audio.sid?.embeddedSongLengths)
    guard case .estimate(let ticket) = plan else { return }
    estimateTask?.cancel()
    let resolver = lengths
    estimateTask = Task { [weak self] in
      let result = await Task.detached(priority: .utility) {
        Result { try resolver.runEstimate(ticket: ticket) }
      }.value
      guard let self, !Task.isCancelled else { return }
      switch result {
      case .success(let seconds):
        if lengths.accept(seconds, ticket: ticket, currentMD5: md5, currentSubtune: audio.subtune) != nil { revision += 1 }
      case .failure: lengths.fail(ticket: ticket)
      }
    }
  }
  func load(_ index: Int, autoplay: Bool, updateQueue: Bool = true) throws {
    playbackIntentRevision += 1
    guard let track = playlist.track(at: index) else { return }
    let bytes = try Data(contentsOf: track.url)
    let file = try SidParser.parse(data: bytes)
    observe(force: true, playing: false)
    audio.load(file)
    currentIndex = index
    md5 = SonglengthDB.md5Hex(of: bytes)
    if updateQueue { makeDefaultQueue(at: index) }
    errorMessage = nil
    planLength()
    if autoplay {
      playback.acknowledgeManualPlayback()
      try audio.play()
    }
    revision += 1
  }
  func makeDefaultQueue(at index: Int) {
    listening.setQueue(
      ListeningQueue(
        libraryID: libraryID, name: "Bibliothek", kind: .library,
        entries: playlist.tracks.map { ListeningEntry(trackID: $0.id) }, startingAt: index,
        shuffled: shuffle, wraps: playlist.count > 1))
  }
  func setSubtune(_ sub: Int) throws {
    observe(force: true, playing: false)
    try audio.setSubtune(sub)
    if let track = currentTrack, var queue = listening.queue {
      queue.updateExplicitSubtune(sub, trackID: track.id)
      listening.setQueue(queue)
    }
    planLength()
    revision += 1
  }
  func playEntry(_ entry: ListeningEntry) throws {
    guard let index = playlist.index(forID: entry.trackID) else {
      throw CocoaError(.fileNoSuchFile)
    }
    try load(index, autoplay: false, updateQueue: false)
    try setSubtune(entry.subtune ?? 0)
    try audio.play()
  }
  func next(previous: Bool, allowCycle: Bool = true) throws {
    if var queue = listening.queue {
      let entry =
        previous ? queue.previous(allowCycle: allowCycle) : queue.next(allowCycle: allowCycle)
      listening.setQueue(queue)
      if let entry { try playEntry(entry) } else { audio.stop() }
    } else if !playlist.isEmpty {
      let index =
        previous
        ? playlist.previousIndex(before: currentIndex)
        : playlist.nextIndex(after: currentIndex, shuffle: shuffle)
      try load(index, autoplay: true)
    }
  }
  func librarySnapshot() -> [String: Any] {
    let parsed = LibrarySearchQuery(query)
    visibleIndices = LibrarySearchSelection.indices(
      in: playlist, query: parsed, records: metadata.records, favoritesOnly: favoritesOnly,
      favorites: favorites,
      duration: { value in
        lengths.knownDuration(
          md5: value.md5, subtune: 0, databaseLengths: database?.lengths(forMD5: value.md5),
          clockMode: audio.clockMode,
          personalDuration: playback.document.endTime(md5: value.md5, subtune: 0),
          embeddedLengths: value.embeddedSongLengths)
      },
      heard: { history.hasHeard(md5: $0.md5) })
    func row(_ index: Int, depth: Int = 0) -> [String: Any] {
      let track = playlist.tracks[index]
      let m = metadata.records[track.id]?.metadata
      return [
        "id": track.id, "name": track.name, "title": m?.title ?? track.name,
        "folder": track.folderPath, "index": index, "depth": depth,
        "favorite": favorites.contains(track.id),
        "detail": track.name + " · " + (m?.author ?? "Autor unbekannt"),
      ]
    }
    let rows: [[String: Any]]
    if folders, parsed.isEmpty, !favoritesOnly {
      let lookup = Dictionary(
        uniqueKeysWithValues: playlist.tracks.enumerated().map { ($1.id, $0) })
      rows =
        LibraryOutline.rows(of: folderTree, expanded: expanded).compactMap { item in
          switch item {
          case .folder(let folder):
            return [
              "id": folder.path, "name": folder.name, "folderRow": true, "depth": folder.depth,
              "expanded": folder.isExpanded, "count": folder.trackCount,
            ]
          case .track(let track):
            return lookup[track.relativePath].map { row($0, depth: track.depth) }
          }
        } + playlist.externalIndices.map { row($0) }
    } else {
      rows = visibleIndices.map { row($0) }
    }
    return [
      "event": "library", "rows": rows, "folders": folders, "count": playlist.count,
      "visible": visibleIndices.count,
      "queryError": parsed.error ?? "", "revision": revision,
      "tunes": PlaylistMenuWindow.indices(count: playlist.count, anchor: currentIndex).map {
        index in ["index": index, "name": playlist.tracks[index].name] as [String: Any]
      },
      "saved": encoded(saved.document), "indexing": metadata.isIndexing,
      "indexed": metadata.indexedCount, "total": metadata.totalCount,
    ]
  }
  func collectionSnapshot() -> [String: Any] {
    guard let collection else { return [:] }
    let preview = collection.preview
    return [
      "canApply": collection.canApply, "busy": collection.isBusy, "error": collection.error ?? "",
      "completion": collection.completion ?? collectionExportNotice ?? "",
      "canRepair": !collection.auditSelection.isEmpty && !collection.isBusy,
      "areas": collection.areas.map(\.rawValue),
      "auditing": collection.isAuditing,
      "skipped": preview?.skippedPathEntries ?? 0,
      "summary": preview.map {
        "\($0.additions) neu · \($0.updates) aktualisiert · \($0.duplicates) unverändert · \($0.skippedPathEntries) nicht zugeordnet"
      }
        ?? (collection.isAuditing
          ? "Sammlung wird geprüft … \(collection.auditProgress)/\(collection.auditTotal)" : ""),
      "conflicts": preview?.conflicts.map {
        [
          "id": $0.id, "label": $0.label, "canUseImported": $0.canUseImported,
          "existing": $0.existingValue, "imported": $0.importedValue,
        ] as [String: Any]
      } ?? [],
      "issues":
        (collection.auditReport?.issues.map {
          [
            "kind": "repair", "id": $0.id,
            "detail": $0.detail + " · " + $0.paths.joined(separator: ", "),
            "checkable": $0.canRepair, "selected": collection.auditSelection.contains($0.id),
          ] as [String: Any]
        } ?? [])
        + (preview?.unresolved.map { item in
          let unverified: Bool
          if case .unverified = item.resolution { unverified = true } else { unverified = false }
          return [
            "kind": "path", "reference": encoded(item.reference),
            "detail": item.reference.path + " · "
              + (unverified
                ? "Pfadzuordnung ohne bestätigte Prüfsumme" : "Nicht eindeutig zugeordnet"),
            "checkable": unverified, "selected": collection.acceptedPaths.contains(item.reference),
          ] as [String: Any]
        } ?? []),
    ]
  }
  func snapshot(includeVisuals: Bool = true) -> [String: Any] {
    let sub = audio.subtune
    let title = audio.sid?.metadata.title ?? "—"
    var info: [[String: String]] = []
    if let track = currentTrack,
      let path = stil?.resolvedPath(
        forFileURL: track.url, hvscRoot: stilRoot, relativePath: track.id)
    {
      info =
        stil?.info(forHVSCPath: path, subtune: sub).orderedFields.map {
          ["label": $0.label, "value": $0.value]
        } ?? []
    }
    let duration = resolution
    let export: [String: Any] = [
      "state": String(describing: exporter.state),
      "error": exporter.error ?? exporter.formatError ?? "", "canExport": exporter.canExport,

      "progress": exporter.progress.map {
        [
          "fraction": $0.fraction, "fileName": $0.fileName, "completed": $0.completedFiles,
          "total": $0.totalFiles,
        ] as [String: Any]
      } ?? NSNull(),
    ]
    var result: [String: Any] = [
      "event": "state", "activeLibraryID": libraryID, "state": audio.state,
      "elapsed": audio.elapsed,
      "duration": duration.seconds, "durationSource": duration.source.rawValue,
      "title": title.isEmpty ? currentTrack?.name ?? "—" : title,
      "composer": audio.sid?.metadata.author ?? "—", "info": audio.sid?.metadata.info ?? "—",
      "personalReference": reference.map { encoded($0) } ?? NSNull(),
      "trackID": currentTrack?.id ?? "", "filename": currentTrack?.name ?? "— Auswählen —",
      "path": currentTrack?.url.path ?? "", "subtune": sub,
      "subtunes": audio.sid?.subtuneAmount ?? 1,
      "volume": audio.volume, "model": audio.model ?? 0, "clock": audio.clockMode.rawValue,
      "clockLabel": audio.effectiveClock.label,
      "mixMuted": audio.mix.channelMuted,
      "chipMuted": audio.mix.chipMuted, "solos": audio.mix.soloChannels.sorted(),
      "effectiveMuted": audio.mix.effectiveMuted(activeChips: audio.chips),
      "filter": audio.filterEnabled, "seeking": audio.isSeeking,
      "loopA": audio.loop.start as Any? ?? NSNull(), "loopB": audio.loop.end as Any? ?? NSNull(),
      "loopEnabled": audio.loop.isEnabled, "loopPreparing": audio.isPreparingLoop,
      "revision": revision, "scanning": isScanning, "indexing": metadata.isIndexing,
      "indexed": metadata.indexedCount, "total": metadata.totalCount,
      "stil": info,
      "subtuneFavorite": currentTrack.map {
        listening.isSubtuneFavorite(trackID: $0.id, subtune: sub)
      } ?? false,
      "remainingSleep": playback.remainingSleepSeconds, "sleepActive": playback.hasSleepTimer,
      "stopAfter": playback.stopAfterSubtune, "expired": playback.didExpire,
      "error": errorMessage ?? favoritesStore.storageError ?? listening.storageError ?? history
        .storageError ?? playback.storageError ?? saved.error ?? "", "export": export,
    ]
    if includeVisuals { result["chips"] = audio.visualSnapshot() }
    // Große persönliche Dokumente werden nur nach Änderungen übertragen.
    // Ein Oszilloskop-Tick darf weder 2.000 Verlaufseinträge noch die gesamte
    // Exportauswahl neu kodieren und über die Pipe schicken.
    if publishedListening != listening.document {
      publishedListening = listening.document
      result["listening"] = encoded(listening.document)
    }
    if publishedHistory != history.document {
      publishedHistory = history.document
      result["history"] = encoded(history.document)
    }
    if publishedPlayback != playback.document {
      publishedPlayback = playback.document
      result["playback"] = encoded(playback.document)
    }
    if publishedExportItems != exporter.items {
      publishedExportItems = exporter.items
      result["exportItems"] = exporter.items.map {
        [
          "id": $0.id, "title": $0.title, "duration": $0.durationDescription,
          "channels": $0.channels, "filename": $0.fileName,
        ] as [String: Any]
      }
    }
    if publishedExportSelection != exporter.selectedIDs {
      publishedExportSelection = exporter.selectedIDs
      result["exportSelected"] = exporter.selectedIDs.sorted()
    }
    let stamp =
      "\(collection.isBusy):\(collection.isApplying):\(collection.canApply):\(collection.error ?? ""):\(collection.completion ?? ""):\(collection.auditProgress):\(collection.isAuditing):\(collection.auditReport?.issues.count ?? -1):\(collection.preview?.additions ?? -1):\(collection.preview?.updates ?? -1):\(collection.preview?.conflicts.count ?? -1):\(collection.preview?.skippedPathEntries ?? -1):\(collection.auditSelection.sorted()):\(collection.areas.map(\.rawValue).sorted()):\(collectionExportNotice ?? "")"
    if stamp != collectionStamp {
      collectionStamp = stamp
      result["collection"] = collectionSnapshot()
    }
    return result
  }

  func handle(_ c: [String: Any]) async -> Bool {
    let op = c["op"] as? String ?? ""
    if ["play", "pause", "toggle", "stop", "next", "previous", "seek", "subtune", "queueEnd", "quit"].contains(op) {
      playbackIntentRevision += 1
    }
    func personalTarget() -> ListeningPersonalReference? {
      if c["reference"] == nil { return reference }
      guard let value = c["reference"] as? [String: Any] else { return nil }
      return try? JSONDecoder().decode(ListeningPersonalReference.self,
        from: JSONSerialization.data(withJSONObject: value))
    }
    func int(_ key: String) -> Int { c[key] as? Int ?? 0 }
    func number(_ key: String) -> Double {
      let n = c[key] as? Double ?? 0
      return n.isFinite ? n : 0
    }
    func string(_ key: String) -> String { c[key] as? String ?? "" }
    func uuid(_ key: String) -> UUID? { UUID(uuidString: string(key)) }
    do {
      if ["pause", "stop", "seek", "clear", "open"].contains(op)
        || op == "toggle" && audio.state == "Playing"
      {
        suppressStartupAutoplay = true
      }
      switch op {
      case "remote":
        guard let url = URL(string: string("url")), let command = RemoteCommand.parse(url) else {
          return false
        }
        switch command {
        case .play: _ = await handle(["op": "play"])
        case .pause: _ = await handle(["op": "pause"])
        case .playPause: _ = await handle(["op": "toggle"])
        case .stop: _ = await handle(["op": "stop"])
        case .next: _ = await handle(["op": "next"])
        case .previous: _ = await handle(["op": "previous"])
        case .seek(let seconds): _ = await handle(["op": "seek", "seconds": seconds])
        case .subtune(let index): _ = await handle(["op": "subtune", "value": index])
        case .track(let id):
          if let index = playlist.index(forID: id) {
            try load(index, autoplay: true)
          } else if isScanning {
            pendingRemoteTrack = id
          }
        }
      case "snapshot":
        emit(snapshot(includeVisuals: c["visuals"] as? Bool ?? true))
        let signature =
          "\(revision):\(metadata.revision):\(metadata.indexedCount):\(metadata.isIndexing):\(saved.isLoaded):\(history.document.heardMD5s.count)"
        let now = ProcessInfo.processInfo.systemUptime
        if signature != lastLibrarySignature
          && (revision != lastLibraryRevision || now - lastLibraryPublication >= 0.5)
        {
          lastLibrarySignature = signature
          lastLibraryRevision = revision
          lastLibraryPublication = now
          emit(librarySnapshot())
        }
      case "library":
        query = string("query")
        favoritesOnly = c["favoritesOnly"] as? Bool ?? false
        emit(librarySnapshot())
      case "open":
        let paths = c["paths"] as? [String] ?? []
        var urls: [URL] = []
        for path in paths {
          let url = URL(fileURLWithPath: path)
          let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
          if isDir {
            let entries = await Task.detached { (try? MusicLibrary.scanFolder(url)) ?? [] }.value
            urls += entries.map { $0.url(relativeTo: url) }
          } else if url.pathExtension.lowercased() == "sid" {
            urls.append(url)
          }
        }
        let additions = playlist.append(urls, root: root)
        metadata.refreshOpenedFiles(playlist.tracks.filter(\.isExternal))
        revision += 1
        if let index = additions.firstIndex { try load(index, autoplay: true) }
      case "select": try load(int("index"), autoplay: audio.state == "Playing")
      case "play":
        playback.acknowledgeManualPlayback()
        if listening.queue == nil, currentIndex >= 0 { makeDefaultQueue(at: currentIndex) }
        if currentTrack == nil, !playlist.isEmpty { try load(0, autoplay: false) }
        try audio.play()
      case "pause":
        observe(force: true, playing: false)
        try audio.pause()
      case "toggle":
        if audio.state == "Playing" {
          observe(force: true, playing: false)
          try audio.pause()
        } else {
          playback.acknowledgeManualPlayback()
          try audio.play()
        }
      case "stop":
        observe(force: true, playing: false)
        audio.stop()
      case "next": try next(previous: false)
      case "previous": try next(previous: true)
      case "subtune": try setSubtune(int("value"))
      case "seek":
        observe(force: true, playing: false)
        let position = min(resolution.seconds, max(0, number("seconds")))
        Task {
          do { try await audio.seek(position) } catch is CancellationError {} catch {
            report(error)
          }
        }
      case "volume":
        audio.volume = min(1, max(0, number("value")))
      case "model":
        observe(force: true, playing: false)
        let m = int("value")
        audio.model = [6581, 8580].contains(m) ? m : nil
        if audio.loop.isEnabled { refreshLoop() }
      case "clock":
        observe(force: true, playing: false)
        try await audio.changeClock(SidClockMode(rawValue: string("value")) ?? .auto)
        planLength()
        if audio.loop.isEnabled { refreshLoop() }
      case "mute":
        audio.mix.toggleChannelMuted(int("channel"))
        if audio.loop.isEnabled { refreshLoop() }
      case "chipMute":
        audio.mix.toggleChipMuted(int("chip"))
        if audio.loop.isEnabled { refreshLoop() }
      case "solo":
        audio.mix.toggleSolo(int("channel"))
        if audio.loop.isEnabled { refreshLoop() }
      case "clearSolos":
        audio.mix.clearSolos()
        if audio.loop.isEnabled { refreshLoop() }
      case "filter":
        audio.filterEnabled.toggle()
        if audio.loop.isEnabled { refreshLoop() }
      case "loopA":
        audio.loop.setStart(audio.elapsed, duration: resolution.seconds)
        refreshLoop()
      case "loopB":
        audio.loop.setEnd(audio.elapsed, duration: resolution.seconds)
        refreshLoop()
      case "loopToggle":
        audio.loop.setEnabled(!audio.loop.isEnabled)
        refreshLoop()
      case "loopClear":
        audio.clearLoop()
      case "favorite":
        var updated = favorites
        updated.toggle(string("id"))
        try favoritesStore.persist(updated.ids)
        favorites = updated
        revision += 1
      case "subtuneFavorite":
        if let track = currentTrack {
          listening.toggleSubtuneFavorite(trackID: track.id, subtune: audio.subtune)
        }
      case "folders":
        folders.toggle()
        try saveSettings()
        revision += 1
      case "expand":
        if !expanded.insert(string("id")).inserted { expanded.remove(string("id")) }
        try saveSettings()
        revision += 1
      case "expandAll":
        expanded = LibraryOutline.allFolderPaths(of: folderTree)
        try saveSettings()
        revision += 1
      case "collapseAll":
        expanded = []
        try saveSettings()
        revision += 1
      case "clear":
        scanGeneration += 1
        scanTask?.cancel()
        metadata.cancel(clear: true)
        lengths.cancel()
        estimateTask?.cancel()
        audio.unload()
        md5 = nil
        currentIndex = -1
        playlist.removeAll()
        listening.setQueue(nil)
        isScanning = false
        revision += 1
      case "settings":
        let values = c["values"] as? [String: Any] ?? [:]
        settings.merge(values, uniquingKeysWith: { _, new in new })
        if let value = values["root"] as? String, value != root.path {
          audio.unload()
          md5 = nil
          currentIndex = -1
          playlist.removeAll()
          listening.setQueue(nil)
          root = URL(fileURLWithPath: value, isDirectory: true)
          rescan()
        }
        if values["shuffle"] != nil { listening.setShuffle(shuffle) }
        try saveSettings()
        if values["songlengths"] != nil || values["stil"] != nil { await loadDatabases() }
      case "rescan": rescan()
      case "repeat": playback.setRepeatMode(PlaybackRepeatMode(rawValue: string("value")) ?? .off)
      case "fade": playback.setFadeOutSeconds(number("value"))
      case "endTime":
        if let target = personalTarget(), !target.md5.isEmpty, let subtune = target.subtune {
          try playback.setEndTime(
            string("value"),
            target: .init(md5: target.md5, subtune: subtune, title: string("title")))
          planLength()
          revision += 1
        }
      case "sleep":
        playback.setSleepMinutes(int("minutes"))
        try playback.startSleepTimer(seconds: Double(int("minutes")) * 60)
      case "sleepCancel": playback.cancelSleepTimer()
      case "stopAfter": playback.stopAtSubtuneEnd()
      case "queueScope":
        let scope: ListeningScope
        switch string("scope") {
        case "favorites": scope = .favorites
        case "folder": scope = .folder(currentTrack?.folderPath ?? "")
        default: scope = .library
        }
        let entries = ListeningSelection.entries(in: playlist, scope: scope, favorites: favorites)
        let queue = ListeningQueue(
          libraryID: libraryID, name: string("scope"), entries: entries, shuffled: shuffle)
        listening.setQueue(queue)
        if let entry = queue.current { try playEntry(entry) }
      case "queueSelection":
        let entries = visibleIndices.map { ListeningEntry(trackID: playlist.tracks[$0].id) }
        let queue = ListeningQueue(
          libraryID: libraryID, name: query.isEmpty ? "Bibliothek" : query, kind: .selection,
          entries: entries, shuffled: shuffle)
        listening.setQueue(queue)
        if let entry = queue.current { try playEntry(entry) }
      case "createList":
        let entries: [ListeningEntry]
        if let id = c["trackID"] as? String {
          entries = [.init(trackID: id)]
        } else if c["empty"] as? Bool == true {
          entries = []
        } else {
          entries = visibleIndices.map { ListeningEntry(trackID: playlist.tracks[$0].id) }
        }
        _ = listening.createList(name: string("name"), entries: entries)
      case "saveQueue":
        _ = listening.createList(name: string("name"), entries: listening.queue?.items ?? [])
      case "listMove":
        if let id = uuid("id"), let listID = uuid("listID") {
          listening.moveListEntry(id, in: listID, by: int("offset"))
        }
      case "listRemove":
        if let id = uuid("id"), let listID = uuid("listID") {
          listening.removeListEntry(id, from: listID)
        }
      case "listSubtune":
        if let id = uuid("id"), let listID = uuid("listID") {
          listening.setSubtune(c["value"] as? Int, entryID: id, listID: listID)
        }
      case "enqueueNext":
        if let id = c["trackID"] as? String { listening.enqueueNext(.init(trackID: id)) }
      case "appendTrack":
        if let id = uuid("id") { listening.append(.init(trackID: string("trackID")), to: id) }
      case "renameList": if let id = uuid("id") { listening.renameList(id, to: string("name")) }
      case "deleteList": if let id = uuid("id") { listening.deleteList(id) }
      case "appendCurrent":
        if let id = uuid("id"), let track = currentTrack {
          listening.append(.init(trackID: track.id, subtune: audio.subtune), to: id)
        }
      case "playList":
        if let id = uuid("id"), let list = listening.activeLists.first(where: { $0.id == id }) {
          let start = uuid("entryID").flatMap { id in list.entries.firstIndex { $0.id == id } } ?? 0
          let queue = ListeningQueue(
            libraryID: libraryID, name: list.name, kind: .savedList, entries: list.entries,
            startingAt: start, shuffled: shuffle)
          listening.setQueue(queue)
          if let entry = queue.current { try playEntry(entry) }
        }
      case "queuePlay":
        if var queue = listening.queue, let id = uuid("id") {
          queue.select(id)
          listening.setQueue(queue)
          if let entry = queue.current { try playEntry(entry) }
        }
      case "queueMove": if let id = uuid("id") { listening.moveQueueEntry(id, by: int("offset")) }
      case "queueRemove": if let id = uuid("id") { listening.removeQueueEntry(id) }
      case "queueEnd":
        audio.stop()
        listening.setQueue(nil)
      case "bookmark":
        if let target = personalTarget() {
          history.saveBookmark(reference: target, title: string("name"),
            position: c["position"] == nil ? audio.elapsed : number("position"))
        }
      case "note":
        if let reference {
          let target =
            c["file"] as? Bool == true
            ? ListeningPersonalReference(
              libraryID: reference.libraryID, trackID: reference.trackID, md5: reference.md5)
            : reference
          history.setNote(string("text"), for: target)
        }
      case "noteReference":
        if let value = c["reference"] as? [String: Any],
          let reference = try? JSONDecoder().decode(
            ListeningPersonalReference.self, from: JSONSerialization.data(withJSONObject: value))
        {
          history.setNote(string("text"), for: reference)
        }
      case "removeBookmark": if let id = uuid("id") { history.removeBookmark(id) }
      case "clearHistory": history.clearHistory()
      case "playReference":
        if let index = playlist.index(forID: string("trackID")) {
          try load(index, autoplay: false)
          try setSubtune(int("subtune"))
          try await audio.seek(number("position"))
          try audio.play()
        } else {
          throw CocoaError(.fileNoSuchFile)
        }
      case "saveSearch":
        saved.save(name: string("name"), query: query, favoritesOnly: favoritesOnly)
        revision += 1
      case "renameSearch":
        if let id = uuid("id") {
          saved.rename(id, to: string("name"))
          revision += 1
        }
      case "deleteSearch":
        if let id = uuid("id") {
          saved.remove(id)
          revision += 1
        }
      case "exportPrepare":
        let sources: [AudioExportSource]
        if string("scope") == "selection" {
          sources = visibleIndices.map { .init(url: playlist.tracks[$0].url) }
        } else if let track = currentTrack {
          sources = [
            .init(url: track.url, subtune: string("scope") == "file" ? nil : audio.subtune)
          ]
        } else {
          sources = []
        }
        exporter.prepare(
          sources: sources,
          durations: .init(
            resolver: lengths, database: database, settings: playback.document,
            clockMode: audio.clockMode))
      case "exportSelect": exporter.toggleSelection(int("id"))
      case "exportDuration": exporter.setDuration(string("value"))
      case "exportSlice": if let range = audio.loop.range { exporter.setSlice(range) }
      case "export":
        let directory = URL(fileURLWithPath: string("directory"))
        exporter.renameForDirectory(directory)
        await exporter.waitForPreparation()
        guard exporter.error == nil else { throw CocoaError(.fileWriteFileExists) }
        exporter.export(
          directory: directory,
          options: .init(
            modelOverride: audio.model, clockMode: audio.clockMode, mix: .current(audio.mix),
            filterEnabled: audio.filterEnabled, fadeOutSeconds: playback.document.fadeOutSeconds))
      case "exportCancel": exporter.cancel()
      case "collectionReset":
        collection.reset()
        collectionExportNotice = nil
      case "collectionArea":
        if let area = PersonalCollectionArea(rawValue: string("area")) {
          await collection.select(area, enabled: c["enabled"] as? Bool ?? false)
        }
      case "collectionExport":
        let destination = URL(fileURLWithPath: string("path"))
        Task {
          await collection.prepareExport()
          if let data = collection.exportData {
            do {
              try data.write(to: destination, options: .atomic)
              collectionExportNotice = "Sammlungsdaten exportiert."
            } catch { report(error) }
          }
        }
      case "collectionImport":
        let source = URL(fileURLWithPath: string("path"))
        collectionExportNotice = nil
        Task { await collection.readImport(from: source) }
      case "collectionChoice":
        if let choice = PersonalCollectionMergeChoice(rawValue: string("value")) {
          await collection.choose(choice, for: string("id"))
        }
      case "collectionSkipped": collection.confirmedSkippedEntries = c["enabled"] as? Bool ?? false
      case "collectionApply":
        Task {
          await collection.apply()
          revision += 1
        }
      case "collectionAcceptPath":
        if let value = c["reference"] as? [String: Any],
          let reference = try? JSONDecoder().decode(
            PersonalCollectionReference.self, from: JSONSerialization.data(withJSONObject: value))
        {
          await collection.acceptPath(reference, enabled: c["enabled"] as? Bool ?? false)
        }
      case "audit": collection.startAudit()
      case "auditCancel": collection.cancelAudit()
      case "auditSelect":
        collection.selectAuditRepair(string("id"), enabled: c["enabled"] as? Bool ?? false)
      case "auditRepair":
        Task {
          await collection.applyAuditRepairs()
          revision += 1
        }
      case "quit": return true
      default: throw CocoaError(.featureUnsupported)
      }
    } catch { report(error) }
    return false
  }
  func shutdown() async {
    isClosing = true
    ticker?.cancel()
    scanTask?.cancel()
    estimateTask?.cancel()
    lengths.cancel()
    exporter.cancel()
    observe(force: true, playing: false)
    persistSession()
    audio.stop()
    listening.flush()
    saved.flush()
    _ = playback.flush()
    _ = await history.flush()
  }
}
