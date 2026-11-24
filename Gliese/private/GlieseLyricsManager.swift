import AppKit
import Combine
import CryptoKit
import Defaults
import Foundation
import GlieseCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class GlieseLyricsManager: ObservableObject {
    static let shared = GlieseLyricsManager()

    enum State: Equatable {
        case idle
        case loading
        case synced(LyricsTimeline, sourceLabel: String)
        case plainText(String, sourceLabel: String)
        case instrumental(sourceLabel: String)
        case onlineConsentRequired
        case notFound(reason: String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var currentTrackKey: String = ""
    @Published private(set) var userOffsetSeconds: Double = 0.0
    @Published private(set) var isFollowing: Bool = true
    @Published private(set) var onlineLookupCount: Int = 0

    let lyricsDirectoryURL: URL
    private let cacheDirectoryURL: URL
    private let offsetsFileURL: URL
    private var savedOffsets: [String: Double] = [:]
    private var fetchTask: Task<Void, Never>?
    private var requestTracker = LyricsRequestTracker()
    private var lastLookupWasTransientFailure = false

    private static let plainLyricsCacheTTLSeconds: TimeInterval = 24 * 3600

    private enum LRCLIBLookupError: Error {
        case offline
        case rateLimited(retryAfterSeconds: Int?)
        case serverError(statusCode: Int)
        case httpError(statusCode: Int)

        var isTransient: Bool {
            switch self {
            case .offline, .rateLimited, .serverError:
                return true
            case .httpError:
                return false
            }
        }

        var userMessage: String {
            switch self {
            case .offline:
                return "LRCLIB lookup failed (offline or timed out)"
            case .rateLimited:
                return "LRCLIB rate-limited — will retry"
            case .serverError:
                return "LRCLIB temporarily unavailable"
            case .httpError:
                return "LRCLIB lookup failed"
            }
        }
    }

    private init() {
        let fm = FileManager.default
        let appSupport = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.temporaryDirectory
        let baseDir = appSupport.appendingPathComponent("com.rymaxw.gliese", isDirectory: true)
        self.lyricsDirectoryURL = baseDir.appendingPathComponent("Lyrics", isDirectory: true)
        self.cacheDirectoryURL = baseDir.appendingPathComponent("LyricsCache", isDirectory: true)
        self.offsetsFileURL = baseDir.appendingPathComponent("LyricsOffsets.json")

        try? fm.createDirectory(at: lyricsDirectoryURL, withIntermediateDirectories: true)
        try? fm.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
        loadOffsets()
    }

    func loadLyrics(title: String, artist: String, album: String?, duration: Double?) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTitle.isEmpty,
              !(trimmedTitle == "I'm Handsome" && trimmedArtist == "Me") else {
            fetchTask?.cancel()
            requestTracker.cancelActiveRequest()
            lastLookupWasTransientFailure = false
            currentTrackKey = ""
            state = .idle
            return
        }

        let query = LyricsQueryTrack(
            title: trimmedTitle,
            artist: trimmedArtist,
            album: album,
            durationSeconds: duration
        )
        let key = LyricsMatcher.cacheKey(for: query)
        if key == currentTrackKey, state != .idle, state != .onlineConsentRequired, !lastLookupWasTransientFailure {
            return
        }

        currentTrackKey = key
        lastLookupWasTransientFailure = false
        state = .loading
        let savedOffset = savedOffsets[key] ?? 0.0
        userOffsetSeconds = savedOffset
        isFollowing = true

        let generation = requestTracker.beginRequest(for: query)
        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            guard let self else { return }
            await self.resolveLyrics(for: query, trackKey: key, generation: generation, initialOffset: savedOffset)
        }
    }

    func retryIfTransientFailure() {
        guard lastLookupWasTransientFailure, !currentTrackKey.isEmpty else { return }
        reloadCurrentTrack()
    }

    func reloadCurrentTrack() {
        let prevKey = currentTrackKey
        currentTrackKey = ""
        if !prevKey.isEmpty {
            loadLyrics(
                title: MusicManager.shared.songTitle,
                artist: MusicManager.shared.artistName,
                album: MusicManager.shared.album,
                duration: MusicManager.shared.songDuration
            )
        }
    }

    func adjustOffset(by delta: Double) {
        guard case .synced(var timeline, let sourceLabel) = state else { return }
        timeline.stepUserOffset(by: delta)
        userOffsetSeconds = timeline.userOffsetSeconds
        state = .synced(timeline, sourceLabel: sourceLabel)
        if !currentTrackKey.isEmpty {
            savedOffsets[currentTrackKey] = userOffsetSeconds
            saveOffsets()
        }
    }

    func resetOffset() {
        guard case .synced(var timeline, let sourceLabel) = state else { return }
        timeline.setUserOffset(0.0)
        userOffsetSeconds = 0.0
        state = .synced(timeline, sourceLabel: sourceLabel)
        if !currentTrackKey.isEmpty {
            savedOffsets.removeValue(forKey: currentTrackKey)
            saveOffsets()
        }
    }

    func applyGlobalOffset(_ seconds: Double) {
        let clamped = min(
            LyricsTimeline.maxGlobalOffsetSeconds,
            max(LyricsTimeline.minGlobalOffsetSeconds, (seconds * 1000.0).rounded() / 1000.0)
        )
        if Defaults[.glieseGlobalLyricsOffsetSeconds] != clamped {
            Defaults[.glieseGlobalLyricsOffsetSeconds] = clamped
        }
        guard case .synced(var timeline, let sourceLabel) = state else { return }
        timeline.setGlobalOffset(clamped)
        state = .synced(timeline, sourceLabel: sourceLabel)
    }

    func adjustGlobalOffset(by delta: Double) {
        applyGlobalOffset(Defaults[.glieseGlobalLyricsOffsetSeconds] + delta)
    }

    func resetGlobalOffset() {
        applyGlobalOffset(0.0)
    }

    func pauseFollowForManualScroll() {
        guard case .synced(var timeline, let sourceLabel) = state, timeline.isFollowing else { return }
        timeline.pauseFollowForManualScroll()
        isFollowing = false
        state = .synced(timeline, sourceLabel: sourceLabel)
    }

    func resumeFollow() {
        guard case .synced(var timeline, let sourceLabel) = state, !timeline.isFollowing else { return }
        timeline.resumeFollow()
        isFollowing = true
        state = .synced(timeline, sourceLabel: sourceLabel)
    }

    func activeLineSelection(at elapsedSeconds: Double) -> ActiveLyricSelection? {
        guard case .synced(let timeline, _) = state else { return nil }
        return timeline.activeLine(at: elapsedSeconds)
    }

    func importLocalLRCFile(forTitle title: String, artist: String) {
        guard !currentTrackKey.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Local .lrc File"
        panel.allowedContentTypes = [UTType(filenameExtension: "lrc") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let sourceURL = panel.url {
            let safeArtist = sanitizeFilename(artist)
            let safeTitle = sanitizeFilename(title)
            let targetName = safeArtist.isEmpty ? "\(safeTitle).lrc" : "\(safeArtist) - \(safeTitle).lrc"
            let destURL = lyricsDirectoryURL.appendingPathComponent(targetName)
            do {
                let data = try Data(contentsOf: sourceURL)
                _ = try LRCParser.parse(data)
                try data.write(to: destURL, options: .atomic)
                reloadCurrentTrack()
            } catch {
                state = .notFound(reason: "Could not import .lrc: \(error.localizedDescription)")
            }
        }
    }

    func revealLyricsFolder() {
        NSWorkspace.shared.open(lyricsDirectoryURL)
    }

    // MARK: - Resolution Pipeline

    private func resolveLyrics(
        for query: LyricsQueryTrack,
        trackKey: String,
        generation: UInt64,
        initialOffset: Double
    ) async {
        guard !Task.isCancelled,
              generation == requestTracker.currentGeneration,
              trackKey == currentTrackKey else { return }
        state = .loading

        // 1. Offline local .lrc file lookup (zero network activity)
        if let localRaw = findLocalLRCContent(title: query.title, artist: query.artist) {
            applyParsedLyrics(raw: localRaw, sourceLabel: "Local .lrc", initialOffset: initialOffset)
            return
        }

        // 2. Local cached LRCLIB response (zero network activity).
        //    Plain-only cached entries expire after 24h (or when missing cachedAt) so they can upgrade to synced lyrics.
        var stalePlainFallback: LRCLIBCandidate?
        if let cached = loadCachedEntry(forKey: trackKey) {
            if !cached.isStalePlain || !Defaults[.glieseAllowOnlineLyrics] {
                applyCandidate(cached.candidate, sourceLabel: "Cached LRCLIB", initialOffset: initialOffset)
                return
            }
            stalePlainFallback = cached.candidate
        }

        // 3. Online LRCLIB lookup — strictly gated on user opt-in (A08)
        guard Defaults[.glieseAllowOnlineLyrics] else {
            state = .onlineConsentRequired
            return
        }

        guard !Task.isCancelled else { return }

        do {
            let decision = try await searchAndMatchLRCLIB(query: query, generation: generation)
            guard !Task.isCancelled,
                  requestTracker.shouldAcceptResponse(
                      generation: generation,
                      for: query,
                      onlineConsentGranted: Defaults[.glieseAllowOnlineLyrics]
                  ) else {
                if !Defaults[.glieseAllowOnlineLyrics], generation == requestTracker.currentGeneration {
                    state = .onlineConsentRequired
                }
                return
            }

            switch decision {
            case .matched(let best, _):
                lastLookupWasTransientFailure = false
                saveCachedEntry(best, forKey: trackKey)
                applyCandidate(best, sourceLabel: "LRCLIB", initialOffset: initialOffset)
            case .rejected(let reason):
                lastLookupWasTransientFailure = false
                if let fallback = stalePlainFallback {
                    saveCachedEntry(fallback, forKey: trackKey)
                    applyCandidate(fallback, sourceLabel: "Cached LRCLIB", initialOffset: initialOffset)
                } else {
                    state = .notFound(reason: humanizeRejection(reason))
                }
            }
        } catch let lookupError as LRCLIBLookupError {
            guard !Task.isCancelled,
                  generation == requestTracker.currentGeneration,
                  trackKey == currentTrackKey else { return }
            lastLookupWasTransientFailure = lookupError.isTransient
            if let fallback = stalePlainFallback {
                applyCandidate(fallback, sourceLabel: "Cached LRCLIB", initialOffset: initialOffset)
            } else {
                state = .notFound(reason: lookupError.userMessage)
            }
        } catch {
            guard !Task.isCancelled,
                  generation == requestTracker.currentGeneration,
                  trackKey == currentTrackKey else { return }
            lastLookupWasTransientFailure = true
            if let fallback = stalePlainFallback {
                applyCandidate(fallback, sourceLabel: "Cached LRCLIB", initialOffset: initialOffset)
            } else {
                state = .notFound(reason: "LRCLIB lookup failed")
            }
        }
    }

    private func applyTimedLRC(_ lrcFile: LRCFile, sourceLabel: String, initialOffset: Double) {
        let timeline = LyricsTimeline(
            file: lrcFile,
            userOffsetSeconds: initialOffset,
            globalOffsetSeconds: Defaults[.glieseGlobalLyricsOffsetSeconds]
        )
        userOffsetSeconds = timeline.userOffsetSeconds
        isFollowing = timeline.isFollowing
        state = .synced(timeline, sourceLabel: sourceLabel)
        MusicManager.shared.syncedLyrics = lrcFile.linesWithFileOffsetApplied().map { ($0.timestampSeconds, $0.text) }
        MusicManager.shared.currentLyrics = lrcFile.lines.map { $0.text }.joined(separator: "\n")
    }

    private func applyParsedLyrics(raw: String, sourceLabel: String, initialOffset: Double) {
        guard let outcome = try? LRCParser.parse(raw) else {
            state = .notFound(reason: "Invalid .lrc file")
            return
        }
        switch outcome {
        case .timed(let lrcFile):
            applyTimedLRC(lrcFile, sourceLabel: sourceLabel, initialOffset: initialOffset)
        case .untimed(let text, _):
            state = .plainText(text, sourceLabel: sourceLabel)
            MusicManager.shared.syncedLyrics = []
            MusicManager.shared.currentLyrics = text
        case .empty:
            state = .notFound(reason: "Empty .lrc file")
        }
    }

    private func applyCandidate(_ candidate: LRCLIBCandidate, sourceLabel: String, initialOffset: Double) {
        if candidate.instrumental {
            state = .instrumental(sourceLabel: sourceLabel)
            MusicManager.shared.syncedLyrics = []
            MusicManager.shared.currentLyrics = "Instrumental"
            return
        }
        if let synced = candidate.syncedLyrics, !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let outcome = try? LRCParser.parse(synced) {
                switch outcome {
                case .timed(let lrcFile):
                    applyTimedLRC(lrcFile, sourceLabel: sourceLabel, initialOffset: initialOffset)
                    return
                case .untimed(let text, _):
                    if candidate.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                        state = .plainText(text, sourceLabel: sourceLabel)
                        MusicManager.shared.syncedLyrics = []
                        MusicManager.shared.currentLyrics = text
                        return
                    }
                case .empty:
                    break
                }
            }
            // Fall through to plainLyrics if syncedLyrics was malformed or parsed empty.
        }
        if let plain = candidate.plainLyrics, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state = .plainText(plain, sourceLabel: sourceLabel)
            MusicManager.shared.syncedLyrics = []
            MusicManager.shared.currentLyrics = plain
            return
        }
        state = .notFound(reason: "No lyrics available")
    }

    private func findLocalLRCContent(title: String, artist: String) -> String? {
        let fm = FileManager.default
        let safeArtist = sanitizeFilename(artist)
        let safeTitle = sanitizeFilename(title)

        let directCandidates = [
            "\(safeArtist) - \(safeTitle).lrc",
            "\(safeTitle).lrc",
            "\(artist) - \(title).lrc",
            "\(title).lrc",
        ]

        for name in directCandidates {
            let url = lyricsDirectoryURL.appendingPathComponent(name)
            if let data = try? Data(contentsOf: url),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
        }

        guard let files = try? fm.contentsOfDirectory(at: lyricsDirectoryURL, includingPropertiesForKeys: nil) else {
            return nil
        }
        let normTitle = LyricsMatcher.normalizeText(title)
        let normArtist = LyricsMatcher.normalizeText(artist)

        for fileURL in files where fileURL.pathExtension.lowercased() == "lrc" {
            let stem = LyricsMatcher.normalizeText(fileURL.deletingPathExtension().lastPathComponent)
            if !normTitle.isEmpty && stem.contains(normTitle) && (normArtist.isEmpty || stem.contains(normArtist)) {
                if let data = try? Data(contentsOf: fileURL),
                   let str = String(data: data, encoding: .utf8) {
                    return str
                }
            }
        }
        return nil
    }

    private struct LRCLIBWireDTO: Codable {
        let id: Int?
        let trackName: String?
        let artistName: String?
        let albumName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
        let cachedAt: TimeInterval?
    }

    private func searchAndMatchLRCLIB(query: LyricsQueryTrack, generation: UInt64) async throws -> LyricsMatchDecision {
        let sanitized = LyricsMatcher.sanitizeQuery(query)
        var searchSteps: [[URLQueryItem]] = []
        var seenSignatures = Set<String>()

        func appendStep(_ items: [URLQueryItem]) {
            let signature = items.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&").lowercased()
            if !signature.isEmpty && seenSignatures.insert(signature).inserted {
                searchSteps.append(items)
            }
        }

        // Step 1: Cleaned title + cleaned artist (handles "- Topic", "VEVO", "(Official Audio)", "Artist - Title")
        if !sanitized.cleanTitle.isEmpty {
            if !sanitized.cleanArtist.isEmpty {
                appendStep([
                    URLQueryItem(name: "track_name", value: sanitized.cleanTitle),
                    URLQueryItem(name: "artist_name", value: sanitized.cleanArtist),
                ])
            }
            if let inferred = sanitized.inferredArtist, !inferred.isEmpty, inferred.lowercased() != sanitized.cleanArtist.lowercased() {
                appendStep([
                    URLQueryItem(name: "track_name", value: sanitized.cleanTitle),
                    URLQueryItem(name: "artist_name", value: inferred),
                ])
            }
        }

        // Step 2: Stripped title + primary artist (handles multi-artist commas, "(feat. ...)", "- Remastered")
        let fallbackArtist = sanitized.inferredArtist ?? sanitized.primaryArtist
        if !sanitized.strippedTitle.isEmpty && !fallbackArtist.isEmpty {
            appendStep([
                URLQueryItem(name: "track_name", value: sanitized.strippedTitle),
                URLQueryItem(name: "artist_name", value: fallbackArtist),
            ])
        }

        // Step 3: Free-text q= fallback (handles diacritics, channel names, and minor metadata mismatches)
        let qParts = [sanitized.strippedTitle, fallbackArtist].filter { !$0.isEmpty }
        if !qParts.isEmpty {
            appendStep([URLQueryItem(name: "q", value: qParts.joined(separator: " "))])
        }

        var lastRejection: LyricsMatchDecision.RejectionReason = .noCandidates
        for items in searchSteps {
            guard !Task.isCancelled,
                  requestTracker.shouldAcceptResponse(
                      generation: generation,
                      for: query,
                      onlineConsentGranted: Defaults[.glieseAllowOnlineLyrics]
                  ) else {
                return .rejected(.noCandidates)
            }
            let candidates = try await fetchLRCLIBCandidates(queryItems: items)
            let decision = LyricsMatcher.selectBestMatch(query: query, candidates: candidates)
            switch decision {
            case .matched:
                return decision
            case .rejected(let reason):
                if !candidates.isEmpty || lastRejection == .noCandidates {
                    lastRejection = reason
                }
            }
        }
        return .rejected(lastRejection)
    }

    private func fetchLRCLIBCandidates(queryItems: [URLQueryItem]) async throws -> [LRCLIBCandidate] {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = queryItems
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("Gliese/1.0 (https://github.com/Rymaxw/Gliese)", forHTTPHeaderField: "User-Agent")

        onlineLookupCount += 1
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let urlError as URLError {
            if urlError.code == .cancelled {
                throw CancellationError()
            }
            throw LRCLIBLookupError.offline
        }

        guard let http = response as? HTTPURLResponse else {
            throw LRCLIBLookupError.offline
        }
        if http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            throw LRCLIBLookupError.rateLimited(retryAfterSeconds: retryAfter)
        }
        if (500...599).contains(http.statusCode) {
            throw LRCLIBLookupError.serverError(statusCode: http.statusCode)
        }
        guard (200...299).contains(http.statusCode) else {
            throw LRCLIBLookupError.httpError(statusCode: http.statusCode)
        }

        let wireItems = try JSONDecoder().decode([LRCLIBWireDTO].self, from: data)
        return wireItems.enumerated().map { idx, item in
            LRCLIBCandidate(
                id: item.id ?? idx,
                trackName: item.trackName ?? "",
                artistName: item.artistName ?? "",
                albumName: item.albumName,
                duration: item.duration,
                instrumental: item.instrumental ?? false,
                plainLyrics: item.plainLyrics,
                syncedLyrics: item.syncedLyrics
            )
        }
    }

    private func cacheFileURL(forKey key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectoryURL.appendingPathComponent("\(digest).json")
    }

    private func loadCachedEntry(forKey key: String) -> (candidate: LRCLIBCandidate, isStalePlain: Bool)? {
        let url = cacheFileURL(forKey: key)
        guard let data = try? Data(contentsOf: url),
              let dto = try? JSONDecoder().decode(LRCLIBWireDTO.self, from: data) else {
            return nil
        }
        let candidate = LRCLIBCandidate(
            id: dto.id ?? 0,
            trackName: dto.trackName ?? "",
            artistName: dto.artistName ?? "",
            albumName: dto.albumName,
            duration: dto.duration,
            instrumental: dto.instrumental ?? false,
            plainLyrics: dto.plainLyrics,
            syncedLyrics: dto.syncedLyrics
        )
        let hasSynced = LRCParser.hasTimedLines(candidate.syncedLyrics)
        let isPlainOnly = !candidate.instrumental && !hasSynced
        let isStalePlain: Bool
        if isPlainOnly {
            if let cachedAt = dto.cachedAt {
                isStalePlain = (Date().timeIntervalSince1970 - cachedAt) > Self.plainLyricsCacheTTLSeconds
            } else {
                // Legacy plain-only entry written before TTL/scoring fixes: allow upgrading to synced once online.
                isStalePlain = true
            }
        } else {
            isStalePlain = false
        }
        return (candidate, isStalePlain)
    }

    private func saveCachedEntry(_ candidate: LRCLIBCandidate, forKey key: String) {
        let dto = LRCLIBWireDTO(
            id: candidate.id,
            trackName: candidate.trackName,
            artistName: candidate.artistName,
            albumName: candidate.albumName,
            duration: candidate.duration,
            instrumental: candidate.instrumental,
            plainLyrics: candidate.plainLyrics,
            syncedLyrics: candidate.syncedLyrics,
            cachedAt: Date().timeIntervalSince1970
        )
        if let data = try? JSONEncoder().encode(dto) {
            try? data.write(to: cacheFileURL(forKey: key), options: .atomic)
        }
    }

    private func loadOffsets() {
        guard let data = try? Data(contentsOf: offsetsFileURL),
              let decoded = try? JSONDecoder().decode([String: Double].self, from: data) else {
            return
        }
        savedOffsets = decoded
    }

    private func saveOffsets() {
        if let data = try? JSONEncoder().encode(savedOffsets) {
            try? data.write(to: offsetsFileURL, options: .atomic)
        }
    }

    private func sanitizeFilename(_ input: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        return input
            .components(separatedBy: invalid)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func humanizeRejection(_ reason: LyricsMatchDecision.RejectionReason) -> String {
        switch reason {
        case .emptyQuery:
            return "Track info missing"
        case .noCandidates:
            return "No matching lyrics found"
        case .titleMismatch:
            return "Rejected mismatched track title"
        case .artistMismatch:
            return "Rejected mismatched artist"
        case .durationOutOfTolerance:
            return "Rejected mismatched track duration"
        case .versionMismatch:
            return "Rejected mismatched track version (live/remix)"
        case .scoreBelowThreshold:
            return "No high-confidence lyric match"
        }
    }
}

struct GlieseInlineLyricsView: View {
    @ObservedObject private var lyrics = GlieseLyricsManager.shared
    @ObservedObject private var music = MusicManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = InlineLyricMotion()
    let width: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !music.isPlaying && motion.outgoing == nil)) { context in
            let position = music.estimatedPlaybackPosition(at: context.date)
            let line = presentation(at: position)
            let progress = motion.progress * motion.progress * (3 - 2 * motion.progress)
            ZStack(alignment: .leading) {
                if let outgoing = motion.outgoing {
                    lyricText(outgoing.text, readingTime: motion.outgoingReadingTime)
                        .opacity(1 - progress)
                        .offset(y: -4 * progress)
                        .accessibilityHidden(true)
                }
                lyricText(motion.current?.text ?? line.text, readingTime: motion.readingTime)
                    .opacity(progress)
                    .offset(y: 4 * (1 - progress))
            }
            .frame(width: width, height: 22, alignment: .leading)
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Current lyric")
            .accessibilityValue(line.text)
            .onChange(of: context.date, initial: true) { _, _ in
                update(line: line, position: position)
            }
            .onChange(of: line) { _, newLine in update(line: newLine, position: position) }
            .onChange(of: music.isPlaying) { _, _ in update(line: line, position: position) }
            .onChange(of: position) { _, newPosition in update(line: line, position: newPosition) }
            .onChange(of: reduceMotion) { _, _ in update(line: line, position: position) }
        }
        .transaction { $0.animation = nil }
    }

    private func update(line: InlineLyricMotion.Line, position: Double) {
        motion.update(line: line, position: position, time: ProcessInfo.processInfo.systemUptime,
                      playing: music.isPlaying, reduceMotion: reduceMotion, playbackRate: music.playbackRate)
    }

    private func presentation(at position: Double) -> InlineLyricMotion.Line {
        let text: String
        var index: Int?
        switch lyrics.state {
        case .synced(let timeline, _):
            let active = timeline.activeLine(at: position)
            index = active?.index
            text = active.map { $0.line.text.isEmpty ? "♪" : $0.line.text } ?? "♪"
        case .loading: text = "Loading lyrics…"
        case .idle: text = "No active track"
        case .onlineConsentRequired: text = "Online lyrics off"
        case .plainText: text = "Unsynced lyrics"
        case .instrumental: text = "Instrumental"
        case .notFound: text = "Lyrics unavailable"
        }
        return .init(track: lyrics.currentTrackKey, index: index, text: text)
    }

    private func lyricText(_ text: String, readingTime: Double) -> some View {
        let baseFont = NSFont.systemFont(ofSize: 14, weight: .medium)
        let font = baseFont.fontDescriptor.withDesign(.rounded)
            .flatMap { NSFont(descriptor: $0, size: 14) } ?? baseFont
        let measuredWidth = (text as NSString).size(withAttributes: [.font: font]).width
        let overflow = measuredWidth > width
        let offset = InlineLyricMotion.scrollOffset(textWidth: measuredWidth, availableWidth: width, readingTime: readingTime)
        return Group {
            if reduceMotion || !overflow {
                Text(text).lineLimit(1).truncationMode(.tail)
                    .frame(width: width, alignment: .leading)
            } else {
                Text(text).fixedSize(horizontal: true, vertical: false)
                    .offset(x: -offset)
                    .frame(width: width, alignment: .leading)
                    .mask {
                        HStack(spacing: 0) {
                            LinearGradient(colors: [offset > 0 ? .clear : .black, .black], startPoint: .leading, endPoint: .trailing)
                                .frame(width: min(12, width / 2))
                            Rectangle()
                            LinearGradient(colors: [.black, offset < measuredWidth - width ? .clear : .black], startPoint: .leading, endPoint: .trailing)
                                .frame(width: min(12, width / 2))
                        }
                    }
            }
        }
        .font(Font(font))
        .foregroundStyle(Color(white: 0.9))
    }
}

struct GlieseMusicActionsView: View {
    @ObservedObject private var media = GlieseMultiSourceMediaManager.shared
    @State private var showLyrics = false
    @State private var showSources = false

    var body: some View {
        HStack(spacing: 8) {
            Button { showLyrics.toggle() } label: {
                Image(systemName: "text.quote").frame(width: 26, height: 26)
            }
            .help("Lyrics")
            .accessibilityLabel("Open lyrics")
            .popover(isPresented: $showLyrics, arrowEdge: .bottom) {
                GlieseLyricsDetailView()
                    .buttonStyle(.borderless)
                    .modifier(GliesePlayerPopoverInteraction())
                    .onExitCommand { showLyrics = false }
            }
            Button { showSources.toggle() } label: {
                if let descriptor = media.selectedDescriptor {
                    AppIcon(for: descriptor.bundleIdentifier)
                        .resizable().scaledToFit().frame(width: 24, height: 24)
                } else {
                    Image(systemName: "music.note").frame(width: 24, height: 24)
                }
            }
            .help(sourceDescription)
            .accessibilityLabel("Choose media source")
            .accessibilityValue(sourceDescription)
            .popover(isPresented: $showSources, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Media source").font(.headline)
                    Picker("Source", selection: Binding(
                        get: { if case .manual(let id) = media.mode { return id.provider.rawValue }; return "auto" },
                        set: { media.selectProvider(SourceProvider(rawValue: $0)) }
                    )) {
                        Text("Automatic").tag("auto")
                        ForEach(SourceProvider.allCases, id: \.rawValue) { provider in
                            Text("\(provider.rawValue.capitalized)\(media.sources[provider]?.isRunning == true ? "" : " (unavailable)")")
                                .tag(provider.rawValue)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    if case .manual = media.mode, media.selectedDescriptor?.isRunning != true {
                        Text("Selected source unavailable. Choose Automatic to follow playback.")
                            .font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                    if let message = media.lastControlStatusMessage {
                        Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16).frame(width: 280)
                .buttonStyle(.borderless)
                .modifier(GliesePlayerPopoverInteraction())
                .onExitCommand { showSources = false }
            }
        }
        .buttonStyle(GliesePlayerActionStyle())
    }

    private var sourceDescription: String {
        let name = media.selectedDescriptor?.displayName ?? "No active source"
        if case .auto = media.mode { return "Automatic: \(name)" }
        return "Manual: \(name)"
    }
}

private struct GliesePlayerActionStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        ActionBody(configuration: configuration, reduceMotion: reduceMotion)
    }

    private struct ActionBody: View {
        let configuration: ButtonStyle.Configuration
        let reduceMotion: Bool
        @State private var hovered = false

        var body: some View {
            configuration.label
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(.white.opacity(configuration.isPressed ? 0.18 : hovered ? 0.1 : 0)))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

private struct GliesePlayerPopoverInteraction: ViewModifier {
    @State private var active = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !active else { return }
                active = true
                SharingStateManager.shared.beginInteraction()
            }
            .onDisappear {
                guard active else { return }
                active = false
                SharingStateManager.shared.endInteraction()
            }
    }
}

struct GlieseLyricsDetailView: View {
    @ObservedObject var lyricsManager = GlieseLyricsManager.shared
    @ObservedObject var musicManager = MusicManager.shared
    @Default(.glieseAllowOnlineLyrics) var allowOnlineLyrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Lyrics").font(.headline)
                Spacer()
                Button("Import .lrc…") {
                    lyricsManager.importLocalLRCFile(forTitle: musicManager.songTitle, artist: musicManager.artistName)
                }
                .disabled(lyricsManager.currentTrackKey.isEmpty)
            }
            lyricsBody
            Divider()
            Toggle("Allow online lookup (LRCLIB)", isOn: $allowOnlineLyrics)
                .onChange(of: allowOnlineLyrics) { _, _ in lyricsManager.reloadCurrentTrack() }
            HStack {
                Button("Lyrics Folder") { lyricsManager.revealLyricsFolder() }
                Spacer()
                Button("Reload") { lyricsManager.reloadCurrentTrack() }
            }
        }
        .frame(width: 340, height: 340, alignment: .topLeading)
        .padding(16)
        .background(Color.black)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var lyricsBody: some View {
        switch lyricsManager.state {
        case .idle:
            VStack(alignment: .leading, spacing: 4) {
                Text("No active track")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                Text("Play Spotify or YouTube Music in Brave or Safari.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

        case .loading:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Resolving lyrics…")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

        case .onlineConsentRequired:
            VStack(alignment: .leading, spacing: 5) {
                Text("No local .lrc found for this track.")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                Text("Online LRCLIB lookup is off by default.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.55))
                HStack(spacing: 6) {
                    Button("Enable LRCLIB") {
                        allowOnlineLyrics = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)

                    Button("Import .lrc…") {
                        lyricsManager.importLocalLRCFile(
                            forTitle: musicManager.songTitle,
                            artist: musicManager.artistName
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

        case .synced(let timeline, let sourceLabel):
            TimelineView(.animation(minimumInterval: 0.1, paused: !musicManager.isPlaying)) { context in
                let elapsed = musicManager.estimatedPlaybackPosition(at: context.date)
                let active = timeline.activeLine(at: elapsed)
                let lines = timeline.file.lines

                VStack(alignment: .leading, spacing: 3) {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                                    let isCurrent = (active?.index == idx)
                                    Text(line.text.isEmpty ? "♪" : line.text)
                                        .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                                        .foregroundStyle(isCurrent ? Color.white : Color(white: 0.7))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(idx)
                                }
                            }
                        }
                        .onChange(of: active?.index, initial: true) { _, newIdx in
                            guard timeline.isFollowing, let newIdx else { return }
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                                proxy.scrollTo(newIdx, anchor: .center)
                            }
                        }
                        .onChange(of: timeline.isFollowing) { _, following in
                            if following, let index = active?.index {
                                proxy.scrollTo(index, anchor: .center)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Text(sourceLabel)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Color(white: 0.7))

                            Spacer(minLength: 0)

                            Button(timeline.isFollowing ? "Pause Sync" : "Resume Sync") {
                                if timeline.isFollowing {
                                    lyricsManager.pauseFollowForManualScroll()
                                } else {
                                    lyricsManager.resumeFollow()
                                }
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 10.5, weight: .semibold))
                        }

                        HStack(spacing: 5) {
                            Text("Track")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Color(white: 0.6))
                            Spacer(minLength: 0)

                            Button("-0.5") { lyricsManager.adjustOffset(by: -0.5) }
                                .buttonStyle(.plain)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.75))
                                .help("Delay track lyrics by 0.5s (later)")
                                .accessibilityLabel("Delay track lyrics by 0.5 seconds")

                            Button("-0.1") { lyricsManager.adjustOffset(by: -0.1) }
                                .buttonStyle(.plain)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.75))
                                .help("Delay track lyrics by 0.1s (later)")
                                .accessibilityLabel("Delay track lyrics by 0.1 seconds")

                            Button(String(format: "%+.1fs", timeline.userOffsetSeconds)) {
                                lyricsManager.resetOffset()
                            }
                            .font(.system(size: 10, design: .monospaced))
                            .help("Click to reset track offset to 0.0s")
                            .accessibilityLabel("Reset track lyric timing offset")

                            Button("+0.1") { lyricsManager.adjustOffset(by: 0.1) }
                                .buttonStyle(.plain)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.75))
                                .help("Advance track lyrics by 0.1s (earlier)")
                                .accessibilityLabel("Advance track lyrics by 0.1 seconds")

                            Button("+0.5") { lyricsManager.adjustOffset(by: 0.5) }
                                .buttonStyle(.plain)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.75))
                                .help("Advance track lyrics by 0.5s (earlier)")
                                .accessibilityLabel("Advance track lyrics by 0.5 seconds")
                        }

                        HStack(spacing: 5) {
                            Text("Global")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Color(white: 0.6))
                            Spacer(minLength: 0)

                            Button("-0.5") { lyricsManager.adjustGlobalOffset(by: -0.5) }
                                .buttonStyle(.plain)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.75))
                                .help("Delay all lyrics by 0.5s (later)")
                                .accessibilityLabel("Delay all lyrics by 0.5 seconds")

                            Button("-0.1") { lyricsManager.adjustGlobalOffset(by: -0.1) }
                                .buttonStyle(.plain)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.75))
                                .help("Delay all lyrics by 0.1s (later)")
                                .accessibilityLabel("Delay all lyrics by 0.1 seconds")

                            Button(String(format: "%+.1fs", timeline.globalOffsetSeconds)) {
                                lyricsManager.resetGlobalOffset()
                            }
                            .font(.system(size: 10, design: .monospaced))
                            .help("Click to reset global lyrics offset to 0.0s")
                            .accessibilityLabel("Reset global lyric timing offset")

                            Button("+0.1") { lyricsManager.adjustGlobalOffset(by: 0.1) }
                                .buttonStyle(.plain)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.75))
                                .help("Advance all lyrics by 0.1s (earlier)")
                                .accessibilityLabel("Advance all lyrics by 0.1 seconds")

                            Button("+0.5") { lyricsManager.adjustGlobalOffset(by: 0.5) }
                                .buttonStyle(.plain)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.75))
                                .help("Advance all lyrics by 0.5s (earlier)")
                                .accessibilityLabel("Advance all lyrics by 0.5 seconds")
                        }
                    }
                }
            }

        case .plainText(let text, let sourceLabel):
            VStack(alignment: .leading, spacing: 3) {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(text)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.82))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Text("\(sourceLabel) (Unsynced)")
                        .font(.system(size: 9))
                        .foregroundStyle(Color(white: 0.7))
                    Spacer()
                    Button("Import .lrc…") {
                        lyricsManager.importLocalLRCFile(
                            forTitle: musicManager.songTitle,
                            artist: musicManager.artistName
                        )
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                }
            }

        case .instrumental(let sourceLabel):
            VStack(alignment: .leading, spacing: 4) {
                Text("Instrumental track")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                Text("Source: \(sourceLabel)")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color(white: 0.7))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

        case .notFound(let reason):
            VStack(alignment: .leading, spacing: 5) {
                Text(reason)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                HStack(spacing: 6) {
                    Button("Import .lrc…") {
                        lyricsManager.importLocalLRCFile(
                            forTitle: musicManager.songTitle,
                            artist: musicManager.artistName
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

                    Button("Lyrics Folder") {
                        lyricsManager.revealLyricsFolder()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.65))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

}
