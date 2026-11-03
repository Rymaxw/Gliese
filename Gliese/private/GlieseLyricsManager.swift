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
        if key == currentTrackKey, state != .idle, state != .onlineConsentRequired {
            return
        }

        currentTrackKey = key
        state = .loading
        let savedOffset = savedOffsets[key] ?? 0.0
        userOffsetSeconds = savedOffset
        isFollowing = true

        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            guard let self else { return }
            await self.resolveLyrics(for: query, trackKey: key, initialOffset: savedOffset)
        }
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

    private func resolveLyrics(for query: LyricsQueryTrack, trackKey: String, initialOffset: Double) async {
        guard !Task.isCancelled, trackKey == currentTrackKey else { return }
        state = .loading

        // 1. Offline local .lrc file lookup (zero network activity)
        if let localRaw = findLocalLRCContent(title: query.title, artist: query.artist) {
            applyParsedLyrics(raw: localRaw, sourceLabel: "Local .lrc", initialOffset: initialOffset)
            return
        }

        // 2. Local cached LRCLIB response (zero network activity)
        if let cached = loadCachedEntry(forKey: trackKey) {
            applyCandidate(cached, sourceLabel: "Cached LRCLIB", initialOffset: initialOffset)
            return
        }

        // 3. Online LRCLIB lookup — strictly gated on user opt-in (A08)
        guard Defaults[.glieseAllowOnlineLyrics] else {
            state = .onlineConsentRequired
            return
        }

        guard !Task.isCancelled else { return }

        do {
            let candidates = try await fetchLRCLIBCandidates(query: query)
            guard !Task.isCancelled else { return }

            let decision = LyricsMatcher.selectBestMatch(query: query, candidates: candidates)
            switch decision {
            case .matched(let best, _):
                saveCachedEntry(best, forKey: trackKey)
                applyCandidate(best, sourceLabel: "LRCLIB", initialOffset: initialOffset)
            case .rejected(let reason):
                state = .notFound(reason: humanizeRejection(reason))
            }
        } catch {
            guard !Task.isCancelled else { return }
            state = .notFound(reason: "LRCLIB lookup failed")
        }
    }

    private func applyParsedLyrics(raw: String, sourceLabel: String, initialOffset: Double) {
        guard let outcome = try? LRCParser.parse(raw) else {
            state = .notFound(reason: "Invalid .lrc file")
            return
        }
        switch outcome {
        case .timed(let lrcFile):
            let timeline = LyricsTimeline(file: lrcFile, userOffsetSeconds: initialOffset)
            userOffsetSeconds = timeline.userOffsetSeconds
            isFollowing = timeline.isFollowing
            state = .synced(timeline, sourceLabel: sourceLabel)
            MusicManager.shared.syncedLyrics = lrcFile.linesWithFileOffsetApplied().map { ($0.timestampSeconds, $0.text) }
            MusicManager.shared.currentLyrics = lrcFile.lines.map { $0.text }.joined(separator: "\n")
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
            applyParsedLyrics(raw: synced, sourceLabel: sourceLabel, initialOffset: initialOffset)
            return
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
    }

    private func fetchLRCLIBCandidates(query: LyricsQueryTrack) async throws -> [LRCLIBCandidate] {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: query.title),
            URLQueryItem(name: "artist_name", value: query.artist),
        ]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("Gliese/1.0 (https://github.com/Rymaxw/Gliese)", forHTTPHeaderField: "User-Agent")

        onlineLookupCount += 1
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return []
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

    private func loadCachedEntry(forKey key: String) -> LRCLIBCandidate? {
        let url = cacheFileURL(forKey: key)
        guard let data = try? Data(contentsOf: url),
              let dto = try? JSONDecoder().decode(LRCLIBWireDTO.self, from: data) else {
            return nil
        }
        return LRCLIBCandidate(
            id: dto.id ?? 0,
            trackName: dto.trackName ?? "",
            artistName: dto.artistName ?? "",
            albumName: dto.albumName,
            duration: dto.duration,
            instrumental: dto.instrumental ?? false,
            plainLyrics: dto.plainLyrics,
            syncedLyrics: dto.syncedLyrics
        )
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
            syncedLyrics: candidate.syncedLyrics
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
        case .onlineConsentRequired: text = "Lyrics unavailable"
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

                    HStack(spacing: 6) {
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
                        .font(.system(size: 11, weight: .semibold))

                        Button("-0.5s") {
                            lyricsManager.adjustOffset(by: -0.5)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                        .accessibilityLabel("Delay lyrics by 0.5 seconds")

                        Button(String(format: "%+.1fs", timeline.userOffsetSeconds)) {
                            lyricsManager.resetOffset()
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .accessibilityLabel("Reset lyric timing offset")

                        Button("+0.5s") {
                            lyricsManager.adjustOffset(by: 0.5)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                        .accessibilityLabel("Advance lyrics by 0.5 seconds")
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
