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

public struct SanitizedLyricsQuery: Equatable, Sendable {
    public let cleanTitle: String
    public let strippedTitle: String
    public let cleanArtist: String
    public let primaryArtist: String
    public let inferredArtist: String?

    public init(
        cleanTitle: String,
        strippedTitle: String,
        cleanArtist: String,
        primaryArtist: String,
        inferredArtist: String?
    ) {
        self.cleanTitle = cleanTitle
        self.strippedTitle = strippedTitle
        self.cleanArtist = cleanArtist
        self.primaryArtist = primaryArtist
        self.inferredArtist = inferredArtist
    }
}

public enum LyricsMatcher {
    public static let cacheSchemaVersion = 1
    public static let negativeCacheTTLSeconds: TimeInterval = 6 * 3600
    public static let highConfidenceDurationToleranceSeconds: Double = 5.0
    public static let relaxedDurationToleranceSeconds: Double = 10.0

    private static let versionSuffixKeywords: Set<String> = [
        "live", "remix", "mix", "acoustic", "unplugged", "remaster", "remastered",
        "instrumental", "karaoke", "version", "edit", "radio", "single", "demo",
        "bonus", "deluxe", "mono", "stereo", "explicit", "clean", "from", "feat", "ft", "featuring"
    ]

    private static let youtubeNoiseKeywords: Set<String> = [
        "official", "audio", "video", "music", "lyric", "lyrics", "visualizer",
        "visualiser", "mv", "hd", "hq", "4k", "explicit", "clean", "topic",
        "color", "coded", "sub", "indo", "eng", "cc"
    ]

    private static let genericChannelKeywords: [String] = [
        "vevo", "topic", "records", "music", "entertainment", "official", "channel", "label", "media", "tv", "sounds"
    ]

    public static func extractVersionHints(title: String, album: String? = nil) -> Set<VersionHint> {
        var hints = Set<VersionHint>()

        // 1. Inspect qualifier segments of the title: (...), [...], and suffix after " - "/" – "/" — "
        let qualifierText = extractTitleQualifierSegments(title)
        let qualifierTokens = tokenize(qualifierText)
        if qualifierTokens.contains("live") { hints.insert(.live) }
        if qualifierTokens.contains("remix") || qualifierTokens.contains("mix") { hints.insert(.remix) }
        if qualifierTokens.contains("acoustic") || qualifierTokens.contains("unplugged") { hints.insert(.acoustic) }
        if qualifierTokens.contains("remaster") || qualifierTokens.contains("remastered") { hints.insert(.remaster) }
        if qualifierTokens.contains("instrumental") { hints.insert(.instrumental) }
        if qualifierTokens.contains("karaoke") { hints.insert(.karaoke) }

        // 2. Unambiguous version words anywhere in the title (excludes "live"/"mix" so core titles like "Live Forever" stay studio)
        let titleTokens = tokenize(title)
        if titleTokens.contains("remix") { hints.insert(.remix) }
        if titleTokens.contains("unplugged") { hints.insert(.acoustic) }
        if titleTokens.contains("remaster") || titleTokens.contains("remastered") { hints.insert(.remaster) }
        if titleTokens.contains("instrumental") { hints.insert(.instrumental) }
        if titleTokens.contains("karaoke") { hints.insert(.karaoke) }

        // 3. Album hints: never classify playlist/mix album names ("My Mix", "Discover Mix", "Awesome Mix") as .remix,
        //    and only tag .live on explicit live-album phrasing or parenthetical qualifiers.
        if let album, !album.isEmpty {
            let albumQualifierTokens = tokenize(extractTitleQualifierSegments(album))
            let albumTokens = tokenize(album)
            let normalizedAlbum = normalizeTokenString(album)

            if albumQualifierTokens.contains("live")
                || normalizedAlbum.hasPrefix("live at ")
                || normalizedAlbum.hasPrefix("live in ")
                || normalizedAlbum.hasPrefix("live from ")
                || normalizedAlbum.hasPrefix("live on ")
                || normalizedAlbum.contains(" live at ")
                || normalizedAlbum.contains(" live in ")
                || normalizedAlbum.contains(" live from ")
            {
                hints.insert(.live)
            }
            if albumTokens.contains("remix") || albumTokens.contains("remixes") { hints.insert(.remix) }
            if albumQualifierTokens.contains("acoustic") || albumTokens.contains("unplugged") { hints.insert(.acoustic) }
            if albumTokens.contains("remaster") || albumTokens.contains("remastered") { hints.insert(.remaster) }
            if albumTokens.contains("instrumental") { hints.insert(.instrumental) }
            if albumTokens.contains("karaoke") { hints.insert(.karaoke) }
        }

        return hints
    }

    public static func normalizeTokenString(_ raw: String) -> String {
        raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public static func normalizeText(_ raw: String) -> String {
        normalizeTokenString(raw)
    }

    public static func sanitizeArtist(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }

        // Strip YouTube auto-generated channel suffix: " - Topic", " – Topic", " — Topic"
        for sep in [" - Topic", " – Topic", " — Topic", " - topic", " – topic", " — topic"] {
            if let range = s.range(of: sep, options: [.caseInsensitive, .anchored, .backwards]) {
                s = String(s[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Strip trailing "VEVO" suffix (e.g. "TaylorSwiftVEVO", "Artist - VEVO", "Artist VEVO")
        if let range = s.range(of: " - vevo", options: [.caseInsensitive, .anchored, .backwards]) {
            s = String(s[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let range = s.range(of: " vevo", options: [.caseInsensitive, .anchored, .backwards]) {
            s = String(s[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if s.count > 4, s.lowercased().hasSuffix("vevo") {
            let trimmed = String(s.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                s = trimmed
            }
        }

        return s
    }

    public static func extractPrimaryArtist(_ raw: String) -> String {
        let clean = sanitizeArtist(raw)
        guard !clean.isEmpty else { return "" }

        let separators = [
            ", ", ",", "; ", ";", " · ", " / ",
            " feat. ", " feat ", " ft. ", " ft ", " featuring ",
            " with ", " & ", " x ", " × "
        ]
        var earliest: Range<String.Index>?
        for sep in separators {
            if let range = clean.range(of: sep, options: .caseInsensitive) {
                if earliest == nil || range.lowerBound < earliest!.lowerBound {
                    earliest = range
                }
            }
        }
        guard let cut = earliest else { return clean }
        let primary = String(clean[..<cut.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return primary.isEmpty ? clean : primary
    }

    public static func stripYouTubeNoise(_ raw: String) -> String {
        var result = ""
        var i = raw.startIndex
        while i < raw.endIndex {
            let ch = raw[i]
            if ch == "(" || ch == "[" {
                let closer: Character = (ch == "(") ? ")" : "]"
                if let closeIdx = raw[raw.index(after: i)...].firstIndex(of: closer) {
                    let inside = String(raw[raw.index(after: i)..<closeIdx])
                    if isYouTubeNoiseSegment(inside) {
                        i = raw.index(after: closeIdx)
                        continue
                    }
                }
            }
            result.append(ch)
            i = raw.index(after: i)
        }

        // Strip trailing pipe/double-slash YouTube suffixes like " | Official Audio"
        for sep in [" | ", " // "] {
            if let range = result.range(of: sep) {
                let tail = String(result[range.upperBound...])
                if isYouTubeNoiseSegment(tail) {
                    result = String(result[..<range.lowerBound])
                }
            }
        }

        return collapseWhitespace(result)
    }

    public static func sanitizeQuery(_ query: LyricsQueryTrack) -> SanitizedLyricsQuery {
        let rawTitle = query.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let hadYouTubeNoise = stripYouTubeNoise(rawTitle) != collapseWhitespace(rawTitle)
        var cleanTitle = stripYouTubeNoise(rawTitle)
        var cleanArtist = sanitizeArtist(query.artist)
        var inferredArtist: String?

        // Handle "Artist - Song Title" format commonly emitted by YouTube / browser players
        if let (lhs, rhs) = splitDashPair(cleanTitle),
           !lhs.isEmpty, !rhs.isEmpty,
           !looksLikeVersionSuffix(rhs) {
            let normLHS = normalizeTokenString(lhs)
            let normArtist = normalizeTokenString(cleanArtist)
            let normPrimaryArtist = normalizeTokenString(extractPrimaryArtist(cleanArtist))

            let artistMatchesLHS = !normArtist.isEmpty && (
                normArtist == normLHS ||
                normPrimaryArtist == normLHS ||
                normArtist.contains(normLHS) ||
                normLHS.contains(normPrimaryArtist)
            )
            let artistLooksGeneric = cleanArtist.isEmpty || isGenericChannelName(cleanArtist)

            if artistMatchesLHS {
                cleanTitle = rhs
                if cleanArtist.isEmpty { cleanArtist = lhs }
            } else if artistLooksGeneric || (hadYouTubeNoise && !normalizeTokenString(rhs).contains(normArtist)) {
                cleanTitle = rhs
                inferredArtist = lhs
                if cleanArtist.isEmpty {
                    cleanArtist = lhs
                }
            }
        }

        let primaryArtist = extractPrimaryArtist(cleanArtist)
        let strippedTitle = stripTitleDisplayQualifiers(cleanTitle)
        return SanitizedLyricsQuery(
            cleanTitle: cleanTitle,
            strippedTitle: strippedTitle.isEmpty ? cleanTitle : strippedTitle,
            cleanArtist: cleanArtist,
            primaryArtist: primaryArtist,
            inferredArtist: inferredArtist
        )
    }

    public static func selectBestMatch(query: LyricsQueryTrack, candidates: [LRCLIBCandidate]) -> LyricsMatchDecision {
        guard !query.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .rejected(.emptyQuery) }
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
        normalizeTokenString(stripTitleDisplayQualifiers(raw))
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

    private struct ScoredCandidate {
        let candidate: LRCLIBCandidate
        let hasSynced: Bool
        let hasPlain: Bool
        let titleExact: Bool
        let artistExact: Bool
        let durationDelta: Double?
        let score: Int
    }

    public static func evaluateCandidates(
        query: LyricsQueryTrack,
        candidates: [LRCLIBCandidate]
    ) -> LyricsResolutionDecision {
        guard !candidates.isEmpty else { return .notFound }

        let sanitized = sanitizeQuery(query)
        let queryNormTitle = normalizeTokenString(query.title)
        let cleanNormTitle = normalizeTokenString(sanitized.cleanTitle)
        let queryCoreTitle = stripParentheticalAndVersionSuffixes(sanitized.cleanTitle)

        var queryArtistTargets: [String] = []
        for raw in [sanitized.cleanArtist, sanitized.primaryArtist, sanitized.inferredArtist, query.artist].compactMap({ $0 }) {
            let norm = normalizeTokenString(raw)
            if !norm.isEmpty && !queryArtistTargets.contains(norm) {
                queryArtistTargets.append(norm)
            }
        }

        // Distinguishers that change vocal timing/lyrics content (remaster does not change vocal structure by itself)
        let criticalHints: Set<VersionHint> = [.live, .remix, .acoustic, .instrumental, .karaoke]
        let queryCritical = query.versionHints.intersection(criticalHints)

        var autoMatches: [ScoredCandidate] = []
        var relaxedMatches: [ScoredCandidate] = []
        var plausibleAmbiguous: [LRCLIBCandidate] = []

        for candidate in candidates {
            let hasSynced = LRCParser.hasTimedLines(candidate.syncedLyrics)
            let hasNonEmptySyncedField = !(candidate.syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let hasPlain = !(candidate.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                || (!hasSynced && hasNonEmptySyncedField)
            // Never let empty stub entries enter scoring or displace valid matches
            guard candidate.instrumental || hasSynced || hasPlain else { continue }

            let candCoreTitle = stripParentheticalAndVersionSuffixes(candidate.trackName)
            let candNormTitle = normalizeTokenString(candidate.trackName)
            let candNormArtist = normalizeTokenString(candidate.artistName)
            let candPrimaryArtist = normalizeTokenString(extractPrimaryArtist(candidate.artistName))

            let titleExact = (candNormTitle == queryNormTitle) || (!cleanNormTitle.isEmpty && candNormTitle == cleanNormTitle)
            let titleCoreMatch = !queryCoreTitle.isEmpty && (candCoreTitle == queryCoreTitle)
            guard titleExact || titleCoreMatch else { continue }

            var artistMatched = false
            var artistExact = false
            for target in queryArtistTargets {
                if candNormArtist == target || (!candPrimaryArtist.isEmpty && candPrimaryArtist == target) {
                    artistMatched = true
                    artistExact = true
                    break
                }
                if target.count >= 2 && candNormArtist.count >= 2 &&
                    (candNormArtist.contains(target) || target.contains(candNormArtist)) {
                    artistMatched = true
                } else if target.count >= 2 && candPrimaryArtist.count >= 2 &&
                    (candPrimaryArtist.contains(target) || target.contains(candPrimaryArtist)) {
                    artistMatched = true
                }
            }
            guard artistMatched else { continue }

            let candHints = extractVersionHints(title: candidate.trackName, album: candidate.albumName)
            let candCritical = candHints.intersection(criticalHints)
            let versionMatches = (candCritical == queryCritical)

            let durationDelta: Double? = {
                guard let qd = query.durationSeconds, let cd = candidate.durationSeconds else { return nil }
                return abs(qd - cd)
            }()

            func computeScore() -> Int {
                var score = 100
                // Synced lyrics strongly outrank plain-only lyrics within valid matches
                if hasSynced { score += 1000 }
                else if candidate.instrumental { score += 500 }
                if titleExact { score += 20 }
                if artistExact { score += 10 }
                if let delta = durationDelta {
                    if delta <= 1.0 { score += 15 }
                    else if delta <= 3.0 { score += 10 }
                    else if delta <= 5.0 { score += 5 }
                }
                return score
            }

            if versionMatches, let delta = durationDelta, delta <= highConfidenceDurationToleranceSeconds {
                autoMatches.append(ScoredCandidate(
                    candidate: candidate,
                    hasSynced: hasSynced,
                    hasPlain: hasPlain,
                    titleExact: titleExact,
                    artistExact: artistExact,
                    durationDelta: durationDelta,
                    score: computeScore()
                ))
            } else if versionMatches, (durationDelta == nil || (durationDelta ?? 999) <= relaxedDurationToleranceSeconds) {
                relaxedMatches.append(ScoredCandidate(
                    candidate: candidate,
                    hasSynced: hasSynced,
                    hasPlain: hasPlain,
                    titleExact: titleExact,
                    artistExact: artistExact,
                    durationDelta: durationDelta,
                    score: computeScore()
                ))
            } else if durationDelta == nil || (durationDelta ?? 999) <= 12.0 || !versionMatches {
                plausibleAmbiguous.append(candidate)
            }
        }

        func resolution(for chosen: LRCLIBCandidate) -> LyricsResolutionDecision {
            if chosen.instrumental {
                return .matchedInstrumental(chosen)
            }
            if LRCParser.hasTimedLines(chosen.syncedLyrics) {
                return .matchedSynced(chosen)
            }
            let hasPlainText = !(chosen.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                || !(chosen.syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            if hasPlainText {
                return .matchedPlain(chosen)
            }
            return .notFound
        }

        if let best = bestScoredCandidate(from: autoMatches) {
            return resolution(for: best.candidate)
        }

        // Relaxed tier: allow unambiguous exact title+artist match up to 10s or when query duration is nil.
        if !relaxedMatches.isEmpty {
            let exactRelaxed = relaxedMatches.filter { $0.titleExact && $0.artistExact }
            let pool = exactRelaxed.isEmpty ? relaxedMatches : exactRelaxed

            let durations = pool.compactMap { $0.candidate.durationSeconds }
            let durationSpread: Double = {
                guard let minD = durations.min(), let maxD = durations.max() else { return 0 }
                return maxD - minD
            }()

            let isUnambiguous: Bool
            if query.durationSeconds == nil {
                // Unknown query duration: require exact title+artist and either a single candidate or consistent recording duration (<= 3s spread)
                isUnambiguous = !exactRelaxed.isEmpty && (pool.count == 1 || durationSpread <= 3.0)
            } else {
                // Known duration within (5s, 10s]: allow when single candidate or consistent recording duration (<= 5s spread)
                isUnambiguous = pool.count == 1 || durationSpread <= 5.0
            }

            if isUnambiguous, let best = bestScoredCandidate(from: pool) {
                return resolution(for: best.candidate)
            }
            return .ambiguous(relaxedMatches.map(\.candidate))
        }

        if !plausibleAmbiguous.isEmpty {
            return .ambiguous(plausibleAmbiguous)
        }

        return .notFound
    }

    // MARK: - Private Normalization Helpers

    private static func bestScoredCandidate(from items: [ScoredCandidate]) -> ScoredCandidate? {
        items.max { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score < rhs.score
            }
            let lhsDelta = lhs.durationDelta ?? Double.infinity
            let rhsDelta = rhs.durationDelta ?? Double.infinity
            if lhsDelta != rhsDelta {
                return lhsDelta > rhsDelta
            }
            return lhs.candidate.id > rhs.candidate.id
        }
    }

    private static func tokenize(_ raw: String) -> Set<String> {
        Set(
            raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
    }

    private static func extractTitleQualifierSegments(_ raw: String) -> String {
        var segments: [String] = []
        var depth = 0
        var current = ""
        for ch in raw {
            if ch == "(" || ch == "[" {
                depth += 1
                if depth == 1 { current = "" }
            } else if ch == ")" || ch == "]" {
                if depth == 1, !current.isEmpty {
                    segments.append(current)
                    current = ""
                }
                if depth > 0 { depth -= 1 }
            } else if depth > 0 {
                current.append(ch)
            }
        }
        // Only treat the suffix after " - "/" – "/" — " as a version qualifier when it actually looks like one,
        // avoiding false positives on "Artist - Live Forever" where the RHS is the song title.
        if let (_, rhs) = splitDashPair(raw) {
            let normRHS = normalizeTokenString(rhs)
            let rhsTokens = tokenize(rhs)
            let explicitDashLive = normRHS == "live"
                || normRHS.hasPrefix("live at ")
                || normRHS.hasPrefix("live in ")
                || normRHS.hasPrefix("live from ")
                || normRHS.hasPrefix("live on ")
                || normRHS.hasPrefix("live version")
                || normRHS.hasPrefix("live acoustic")
                || normRHS.hasPrefix("live session")
                || normRHS.hasSuffix(" live")
            let explicitDashMix = normRHS == "mix"
                || normRHS.hasSuffix(" mix")
                || rhsTokens.contains("remix")
            let otherDashQualifier = !rhsTokens.isDisjoint(with: ["acoustic", "unplugged", "remaster", "remastered", "instrumental", "karaoke"])
            if explicitDashLive || explicitDashMix || otherDashQualifier {
                segments.append(rhs)
            }
        }
        return segments.joined(separator: " ")
    }

    private static func stripTitleDisplayQualifiers(_ raw: String) -> String {
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
        if let (lhs, rhs) = splitDashPair(result), looksLikeVersionSuffix(rhs) {
            result = lhs
        }
        // Strip trailing unparenthesized "feat. ..." / "ft. ..." / "featuring ..."
        for featSep in [" feat. ", " feat ", " ft. ", " ft ", " featuring "] {
            if let range = result.range(of: featSep, options: .caseInsensitive) {
                result = String(result[..<range.lowerBound])
            }
        }
        return collapseWhitespace(result)
    }

    private static func splitDashPair(_ raw: String) -> (String, String)? {
        for sep in [" - ", " – ", " — "] {
            if let range = raw.range(of: sep) {
                let lhs = String(raw[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let rhs = String(raw[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return (lhs, rhs)
            }
        }
        return nil
    }

    private static func looksLikeVersionSuffix(_ segment: String) -> Bool {
        let tokens = tokenize(segment)
        return !tokens.isDisjoint(with: versionSuffixKeywords)
    }

    private static func isYouTubeNoiseSegment(_ segment: String) -> Bool {
        let tokens = tokenize(segment)
        guard !tokens.isEmpty else { return false }
        // Must contain a YouTube noise keyword and not be a critical version qualifier like (Live) or (Remix)
        let hasNoise = !tokens.isDisjoint(with: youtubeNoiseKeywords)
        let critical: Set<String> = ["live", "remix", "acoustic", "unplugged", "instrumental", "karaoke"]
        let hasCritical = !tokens.isDisjoint(with: critical)
        return hasNoise && !hasCritical
    }

    private static func isGenericChannelName(_ artist: String) -> Bool {
        let lower = artist.lowercased()
        return genericChannelKeywords.contains { lower.contains($0) }
    }

    private static func collapseWhitespace(_ raw: String) -> String {
        raw.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
