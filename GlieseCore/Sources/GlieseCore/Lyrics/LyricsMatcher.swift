import Foundation

public enum VersionHint: String, Codable, CaseIterable, Hashable, Sendable, Comparable {
    case live
    case remix
    case acoustic
    case remaster
    case instrumental
    case karaoke

    public static func < (lhs: VersionHint, rhs: VersionHint) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct LyricsQueryTrack: Equatable, Hashable, Sendable {
    public let title: String
    public let artist: String
    public let album: String?
    public let durationSeconds: Double?
    public let versionHints: Set<VersionHint>

    public init(
        title: String,
        artist: String,
        album: String? = nil,
        durationSeconds: Double? = nil,
        versionHints: Set<VersionHint>? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        if let d = durationSeconds, d.isFinite, d > 0 {
            self.durationSeconds = d
        } else {
            self.durationSeconds = nil
        }
        self.versionHints = versionHints ?? LyricsMatcher.extractVersionHints(title: title, album: album)
    }
}

public struct LRCLIBCandidate: Equatable, Identifiable, Sendable {
    public let id: Int
    public let trackName: String
    public let artistName: String
    public let albumName: String?
    public let durationSeconds: Double?
    public let instrumental: Bool
    public let syncedLyrics: String?
    public let plainLyrics: String?

    public var duration: Double? { durationSeconds }

    public init(
        id: Int,
        trackName: String,
        artistName: String,
        albumName: String? = nil,
        durationSeconds: Double? = nil,
        duration: Double? = nil,
        instrumental: Bool = false,
        plainLyrics: String? = nil,
        syncedLyrics: String? = nil
    ) {
        self.id = id
        self.trackName = trackName
        self.artistName = artistName
        self.albumName = albumName
        let resolvedDur = durationSeconds ?? duration
        if let d = resolvedDur, d.isFinite, d > 0 {
            self.durationSeconds = d
        } else {
            self.durationSeconds = nil
        }
        self.instrumental = instrumental
        self.syncedLyrics = syncedLyrics
        self.plainLyrics = plainLyrics
    }
}

public enum LyricsMatchDecision: Equatable, Sendable {
    public enum RejectionReason: Equatable, Sendable {
        case emptyQuery
        case noCandidates
        case titleMismatch
        case artistMismatch
        case durationOutOfTolerance
        case versionMismatch
        case scoreBelowThreshold
    }

    case matched(LRCLIBCandidate, isSynced: Bool)
    case rejected(RejectionReason)
}

public enum LyricsResolutionDecision: Equatable, Sendable {
    case matchedSynced(LRCLIBCandidate)
    case matchedPlain(LRCLIBCandidate)
    case matchedInstrumental(LRCLIBCandidate)
    case ambiguous([LRCLIBCandidate])
    case notFound
}

public enum LyricsFetchOutcome: Equatable, Sendable {
    case notFound
    case offline
    case rateLimited(retryAfterSeconds: Int?)
    case serverError(statusCode: Int)
}

public struct LyricsRequestTracker: Sendable {
    public private(set) var currentGeneration: UInt64 = 0
    public private(set) var activeQuery: LyricsQueryTrack?

    public init() {}

    public mutating func beginRequest(for query: LyricsQueryTrack) -> UInt64 {
        currentGeneration &+= 1
        activeQuery = query
        return currentGeneration
    }

    public mutating func cancelActiveRequest() {
        currentGeneration &+= 1
        activeQuery = nil
    }

    public func shouldAcceptResponse(generation: UInt64, for query: LyricsQueryTrack, onlineConsentGranted: Bool) -> Bool {
        guard onlineConsentGranted else { return false }
        return generation == currentGeneration && activeQuery == query
    }
}

public enum LyricsMatcher {
    public static let cacheSchemaVersion = 1
    public static let negativeCacheTTLSeconds: TimeInterval = 6 * 3600

    public static func extractVersionHints(title: String, album: String? = nil) -> Set<VersionHint> {
        let combined = "\(title) \(album ?? "")".lowercased()
        let tokens = Set(
            combined
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
        var hints = Set<VersionHint>()
        if tokens.contains("live") { hints.insert(.live) }
        if tokens.contains("remix") || tokens.contains("mix") { hints.insert(.remix) }
        if tokens.contains("acoustic") || tokens.contains("unplugged") { hints.insert(.acoustic) }
        if tokens.contains("remaster") || tokens.contains("remastered") { hints.insert(.remaster) }
        if tokens.contains("instrumental") { hints.insert(.instrumental) }
        if tokens.contains("karaoke") { hints.insert(.karaoke) }
        return hints
    }

    public static func normalizeTokenString(_ raw: String) -> String {
        raw.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public static func normalizeText(_ raw: String) -> String {
        normalizeTokenString(raw)
    }

    public static func selectBestMatch(query: LyricsQueryTrack, candidates: [LRCLIBCandidate]) -> LyricsMatchDecision {
        guard !query.title.isEmpty else { return .rejected(.emptyQuery) }
        guard !candidates.isEmpty else { return .rejected(.noCandidates) }

        let decision = evaluateCandidates(query: query, candidates: candidates)
        switch decision {
        case .matchedSynced(let cand):
            return .matched(cand, isSynced: true)
        case .matchedPlain(let cand):
            return .matched(cand, isSynced: false)
        case .matchedInstrumental(let cand):
            return .matched(cand, isSynced: false)
        case .ambiguous:
            return .rejected(.scoreBelowThreshold)
        case .notFound:
            return .rejected(.noCandidates)
        }
    }

    public static func stripParentheticalAndVersionSuffixes(_ raw: String) -> String {
        var result = ""
        var depth = 0
        for ch in raw {
            if ch == "(" || ch == "[" {
                depth += 1
            } else if ch == ")" || ch == "]" {
                if depth > 0 { depth -= 1 }
            } else if depth == 0 {
                result.append(ch)
            }
        }
        if let dashRange = result.range(of: " - ") {
            result = String(result[..<dashRange.lowerBound])
        }
        return normalizeTokenString(result)
    }

    public static func cacheKey(for query: LyricsQueryTrack) -> String {
        let normTitle = normalizeTokenString(query.title)
        let normArtist = normalizeTokenString(query.artist)
        let normAlbum = normalizeTokenString(query.album ?? "")
        let durBucket = query.durationSeconds.map { String(Int($0.rounded())) } ?? "unknown"
        let hints = query.versionHints.sorted().map(\.rawValue).joined(separator: ",")
        return "v\(cacheSchemaVersion)|t:\(normTitle)|a:\(normArtist)|al:\(normAlbum)|d:\(durBucket)|h:\(hints)"
    }

    public static func shouldWriteNegativeCache(for outcome: LyricsFetchOutcome) -> Bool {
        switch outcome {
        case .notFound:
            return true
        case .offline, .rateLimited, .serverError:
            return false
        }
    }

    public static func evaluateCandidates(
        query: LyricsQueryTrack,
        candidates: [LRCLIBCandidate]
    ) -> LyricsResolutionDecision {
        guard !candidates.isEmpty else { return .notFound }

        let queryCoreTitle = stripParentheticalAndVersionSuffixes(query.title)
        let queryNormTitle = normalizeTokenString(query.title)
        let queryNormArtist = normalizeTokenString(query.artist)
        // Distinguishers that change vocal timing/lyrics content (remaster does not change vocal structure by itself)
        let criticalHints: Set<VersionHint> = [.live, .remix, .acoustic, .instrumental, .karaoke]
        let queryCritical = query.versionHints.intersection(criticalHints)

        var autoMatches: [(candidate: LRCLIBCandidate, score: Int)] = []
        var plausibleAmbiguous: [LRCLIBCandidate] = []

        for candidate in candidates {
            let candCoreTitle = stripParentheticalAndVersionSuffixes(candidate.trackName)
            let candNormTitle = normalizeTokenString(candidate.trackName)
            let candNormArtist = normalizeTokenString(candidate.artistName)

            let titleExact = (candNormTitle == queryNormTitle)
            let titleCoreMatch = !queryCoreTitle.isEmpty && (candCoreTitle == queryCoreTitle)
            guard titleExact || titleCoreMatch else { continue }

            let artistMatches = !queryNormArtist.isEmpty && (
                candNormArtist == queryNormArtist ||
                candNormArtist.contains(queryNormArtist) ||
                queryNormArtist.contains(candNormArtist)
            )
            guard artistMatches else { continue }

            let candHints = extractVersionHints(title: candidate.trackName, album: candidate.albumName)
            let candCritical = candHints.intersection(criticalHints)
            let versionMatches = (candCritical == queryCritical)

            let durationDelta: Double? = {
                guard let qd = query.durationSeconds, let cd = candidate.durationSeconds else { return nil }
                return abs(qd - cd)
            }()

            let durationAcceptable: Bool = {
                guard let delta = durationDelta else { return false }
                return delta <= 3.0
            }()

            if versionMatches && durationAcceptable {
                var score = 100
                if titleExact { score += 20 }
                if let delta = durationDelta, delta <= 1.0 { score += 15 }
                if (candidate.syncedLyrics?.isEmpty == false) { score += 10 }
                autoMatches.append((candidate, score))
            } else if durationDelta == nil || (durationDelta ?? 999) <= 12.0 || !versionMatches {
                plausibleAmbiguous.append(candidate)
            }
        }

        if let best = autoMatches.max(by: { $0.score < $1.score }) {
            let chosen = best.candidate
            if chosen.instrumental {
                return .matchedInstrumental(chosen)
            }
            if let synced = chosen.syncedLyrics, !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .matchedSynced(chosen)
            }
            if let plain = chosen.plainLyrics, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .matchedPlain(chosen)
            }
        }

        if !plausibleAmbiguous.isEmpty {
            return .ambiguous(plausibleAmbiguous)
        }

        return .notFound
    }
}
