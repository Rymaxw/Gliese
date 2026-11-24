import Foundation
import Testing
@testable import GlieseCore

@Suite("LyricsMatcher, Cache Key & Request Generation Tests")
struct LyricsMatcherTests {

    @Test("Version hints distinguish live, remix, acoustic, remaster, and instrumental")
    func versionHintExtraction() {
        let liveHints = LyricsMatcher.extractVersionHints(title: "Creep (Live at Reading)", album: "Reading 2009")
        #expect(liveHints == [.live])

        let remixHints = LyricsMatcher.extractVersionHints(title: "Clarity - Tiesto Remix", album: nil)
        #expect(remixHints == [.remix])

        let remasterHints = LyricsMatcher.extractVersionHints(title: "Bohemian Rhapsody - 2011 Remaster", album: nil)
        #expect(remasterHints == [.remaster])
    }

    @Test("Live or remix candidate is never auto-accepted for a studio track")
    func liveOrRemixNotAutoAcceptedForStudioTrack() {
        let studioQuery = LyricsQueryTrack(
            title: "Everlong",
            artist: "Foo Fighters",
            album: "The Colour and the Shape",
            durationSeconds: 250.0
        )

        let liveCandidate = LRCLIBCandidate(
            id: 10,
            trackName: "Everlong (Live at Wembley)",
            artistName: "Foo Fighters",
            albumName: "Live at Wembley",
            durationSeconds: 251.0,
            syncedLyrics: "[00:10.00] Hello live"
        )

        let decision = LyricsMatcher.evaluateCandidates(query: studioQuery, candidates: [liveCandidate])
        #expect(decision == .ambiguous([liveCandidate]))
    }

    @Test("Exact studio match with valid duration auto-resolves synced, plain, or instrumental")
    func exactMatchResolvesProperVariant() {
        let query = LyricsQueryTrack(
            title: "One More Time",
            artist: "Daft Punk",
            album: "Discovery",
            durationSeconds: 320.0
        )

        let syncedCandidate = LRCLIBCandidate(
            id: 1,
            trackName: "One More Time",
            artistName: "Daft Punk",
            albumName: "Discovery",
            durationSeconds: 320.4,
            syncedLyrics: "[00:15.00] One more time"
        )
        #expect(LyricsMatcher.evaluateCandidates(query: query, candidates: [syncedCandidate]) == .matchedSynced(syncedCandidate))

        let instrumentalCandidate = LRCLIBCandidate(
            id: 2,
            trackName: "Veridis Quo",
            artistName: "Daft Punk",
            albumName: "Discovery",
            durationSeconds: 345.0,
            instrumental: true
        )
        let instQuery = LyricsQueryTrack(title: "Veridis Quo", artist: "Daft Punk", durationSeconds: 345.0)
        #expect(LyricsMatcher.evaluateCandidates(query: instQuery, candidates: [instrumentalCandidate]) == .matchedInstrumental(instrumentalCandidate))
    }

    @Test("Unknown duration resolves a single unambiguous exact match, but marks conflicting durations ambiguous")
    func unknownDurationBehavior() {
        let unknownDurationQuery = LyricsQueryTrack(
            title: "Starlight",
            artist: "Muse",
            durationSeconds: nil
        )
        let candidateA = LRCLIBCandidate(
            id: 42,
            trackName: "Starlight",
            artistName: "Muse",
            durationSeconds: 240.0,
            syncedLyrics: "[00:12.00] Far away"
        )
        let candidateB = LRCLIBCandidate(
            id: 43,
            trackName: "Starlight",
            artistName: "Muse",
            durationSeconds: 305.0,
            syncedLyrics: "[00:18.00] Far away extended"
        )

        #expect(LyricsMatcher.evaluateCandidates(query: unknownDurationQuery, candidates: [candidateA]) == .matchedSynced(candidateA))
        #expect(LyricsMatcher.evaluateCandidates(query: unknownDurationQuery, candidates: [candidateA, candidateB]) == .ambiguous([candidateA, candidateB]))
    }

    @Test("Duration tolerance allows <= 5s high confidence and <= 10s unambiguous YouTube Music variance")
    func relaxedDurationTolerance() {
        let query = LyricsQueryTrack(title: "Midnight City", artist: "M83", durationSeconds: 248.0)

        let withinFive = LRCLIBCandidate(
            id: 101,
            trackName: "Midnight City",
            artistName: "M83",
            durationSeconds: 243.8,
            syncedLyrics: "[00:10.00] Waiting in a car"
        )
        #expect(LyricsMatcher.evaluateCandidates(query: query, candidates: [withinFive]) == .matchedSynced(withinFive))

        let withinTen = LRCLIBCandidate(
            id: 102,
            trackName: "Midnight City",
            artistName: "M83",
            durationSeconds: 240.5,
            syncedLyrics: "[00:10.00] Waiting in a car"
        )
        #expect(LyricsMatcher.evaluateCandidates(query: query, candidates: [withinTen]) == .matchedSynced(withinTen))

        let farOff = LRCLIBCandidate(
            id: 103,
            trackName: "Midnight City",
            artistName: "M83",
            durationSeconds: 230.0,
            syncedLyrics: "[00:10.00] Waiting in a car"
        )
        #expect(LyricsMatcher.evaluateCandidates(query: query, candidates: [farOff]) == .notFound)
    }

    @Test("Diacritics fold cleanly across titles and artists")
    func diacriticFoldingMatches() {
        let query = LyricsQueryTrack(title: "Deja Vu", artist: "Beyonce", durationSeconds: 240.0)
        let candidate = LRCLIBCandidate(
            id: 201,
            trackName: "Déjà Vu",
            artistName: "Beyoncé",
            durationSeconds: 240.0,
            syncedLyrics: "[00:10.00] Bass"
        )
        #expect(LyricsMatcher.evaluateCandidates(query: query, candidates: [candidate]) == .matchedSynced(candidate))

        let sigurQuery = LyricsQueryTrack(title: "Hoppipolla", artist: "Sigur Ros", durationSeconds: 268.0)
        let sigurCand = LRCLIBCandidate(
            id: 202,
            trackName: "Hoppípolla",
            artistName: "Sigur Rós",
            durationSeconds: 268.0,
            syncedLyrics: "[00:15.00] Brosandi"
        )
        #expect(LyricsMatcher.evaluateCandidates(query: sigurQuery, candidates: [sigurCand]) == .matchedSynced(sigurCand))
    }

    @Test("Sanitizes - Topic, VEVO, multi-artist, YouTube noise, and Artist - Title without losing song title")
    func youtubeAndTopicSanitization() {
        #expect(LyricsMatcher.sanitizeArtist("NIKI - Topic") == "NIKI")
        #expect(LyricsMatcher.sanitizeArtist("ArianaGrandeVEVO") == "ArianaGrande")
        #expect(LyricsMatcher.extractPrimaryArtist("The Weeknd, Playboi Carti") == "The Weeknd")
        #expect(LyricsMatcher.extractPrimaryArtist("Daft Punk feat. Pharrell Williams") == "Daft Punk")
        #expect(LyricsMatcher.stripYouTubeNoise("Lowkey (Official Audio) [4K]") == "Lowkey")

        let topicQuery = LyricsQueryTrack(
            title: "Lowkey (Official Audio)",
            artist: "NIKI - Topic",
            durationSeconds: 171.0
        )
        let lowkeyCand = LRCLIBCandidate(
            id: 301,
            trackName: "lowkey",
            artistName: "NIKI",
            durationSeconds: 171.0,
            syncedLyrics: "[00:08.00] Wizard with words"
        )
        #expect(LyricsMatcher.evaluateCandidates(query: topicQuery, candidates: [lowkeyCand]) == .matchedSynced(lowkeyCand))

        let artistTitleEmptyArtist = LyricsQueryTrack(
            title: "NIKI - Lowkey (Official Music Video)",
            artist: "",
            durationSeconds: 173.0
        )
        let sanitizedEmpty = LyricsMatcher.sanitizeQuery(artistTitleEmptyArtist)
        #expect(sanitizedEmpty.cleanTitle == "Lowkey")
        #expect(sanitizedEmpty.cleanArtist == "NIKI")
        #expect(LyricsMatcher.evaluateCandidates(query: artistTitleEmptyArtist, candidates: [lowkeyCand]) == .matchedSynced(lowkeyCand))

        let genericChannelQuery = LyricsQueryTrack(
            title: "NIKI - Lowkey (Official Video)",
            artist: "88rising Music",
            durationSeconds: 174.0
        )
        #expect(LyricsMatcher.evaluateCandidates(query: genericChannelQuery, candidates: [lowkeyCand]) == .matchedSynced(lowkeyCand))
    }

    @Test("Mix playlist albums and core titles like Live Forever do not trigger false version rejections")
    func mixAlbumsAndLiveForeverNotFalsePositives() {
        #expect(LyricsMatcher.extractVersionHints(title: "Live Forever", album: "Definitely Maybe").isEmpty)
        #expect(LyricsMatcher.extractVersionHints(title: "Oasis - Live Forever", album: "My Mix").isEmpty)
        #expect(LyricsMatcher.extractVersionHints(title: "Starboy", album: "Discover Mix").isEmpty)
        #expect(LyricsMatcher.extractVersionHints(title: "Starboy", album: "Replay Mix").isEmpty)
        #expect(LyricsMatcher.extractVersionHints(title: "Hooked on a Feeling", album: "Awesome Mix Vol. 1").isEmpty)

        // Genuine live/remix qualifiers are still caught
        #expect(LyricsMatcher.extractVersionHints(title: "hate that i made you love me (live from rehearsal)", album: "") == [.live])
        #expect(LyricsMatcher.extractVersionHints(title: "One More Time (Extended Mix)", album: nil) == [.remix])
        #expect(LyricsMatcher.extractVersionHints(title: "Everlong", album: "Live at Wembley") == [.live])

        let mixPlaylistQuery = LyricsQueryTrack(
            title: "Starboy",
            artist: "The Weeknd",
            album: "Discover Mix",
            durationSeconds: 230.0
        )
        let studioCand = LRCLIBCandidate(
            id: 401,
            trackName: "Starboy",
            artistName: "The Weeknd",
            albumName: "Starboy",
            durationSeconds: 230.0,
            syncedLyrics: "[00:14.00] I'm tryna put you in the worst mood"
        )
        #expect(LyricsMatcher.evaluateCandidates(query: mixPlaylistQuery, candidates: [studioCand]) == .matchedSynced(studioCand))

        let liveForeverQuery = LyricsQueryTrack(
            title: "Live Forever",
            artist: "Oasis",
            album: "Definitely Maybe",
            durationSeconds: 276.0
        )
        let liveForeverCand = LRCLIBCandidate(
            id: 402,
            trackName: "Live Forever",
            artistName: "Oasis",
            albumName: "Definitely Maybe",
            durationSeconds: 276.0,
            syncedLyrics: "[00:20.00] Maybe I don't really wanna know"
        )
        #expect(LyricsMatcher.evaluateCandidates(query: liveForeverQuery, candidates: [liveForeverCand]) == .matchedSynced(liveForeverCand))
    }

    @Test("Empty stub candidates are filtered out and synced lyrics always beat plain-only candidates")
    func emptyStubsFilteredAndSyncedPrioritized() {
        let query = LyricsQueryTrack(title: "Blinding Lights", artist: "The Weeknd", durationSeconds: 200.0)

        let emptyStubExact = LRCLIBCandidate(
            id: 501,
            trackName: "Blinding Lights",
            artistName: "The Weeknd",
            durationSeconds: 200.0,
            instrumental: false,
            plainLyrics: nil,
            syncedLyrics: "   \n  "
        )
        let plainCloser = LRCLIBCandidate(
            id: 502,
            trackName: "Blinding Lights",
            artistName: "The Weeknd",
            durationSeconds: 200.1,
            plainLyrics: "I've been tryna call",
            syncedLyrics: nil
        )
        let syncedSlightlyOff = LRCLIBCandidate(
            id: 503,
            trackName: "Blinding Lights (Album Version)",
            artistName: "The Weeknd",
            durationSeconds: 202.2,
            plainLyrics: "I've been tryna call",
            syncedLyrics: "[00:27.00] I've been tryna call"
        )

        #expect(LyricsMatcher.evaluateCandidates(query: query, candidates: [emptyStubExact, plainCloser, syncedSlightlyOff]) == .matchedSynced(syncedSlightlyOff))
        #expect(LyricsMatcher.evaluateCandidates(query: query, candidates: [emptyStubExact, plainCloser]) == .matchedPlain(plainCloser))
        #expect(LyricsMatcher.evaluateCandidates(query: query, candidates: [emptyStubExact]) == .notFound)
    }

    @Test("Genuine timed LRC beats lower-ID poisoned fake-synced candidate (Berubah - Tenxi & Jemsii repro)")
    func genuineTimedBeatsFakeSyncedCandidate() {
        let query = LyricsQueryTrack(
            title: "Berubah",
            artist: "Tenxi & Jemsii",
            album: "",
            durationSeconds: 200.501
        )
        let untimedBody = "Jangan nyesel semua problem kamu yang start\nJangan minta rewind aku kamu udah finish"
        let fakeSyncedLowerID = LRCLIBCandidate(
            id: 24620315,
            trackName: "Berubah",
            artistName: "Tenxi, Jemsii",
            albumName: "null",
            durationSeconds: 201.0,
            plainLyrics: untimedBody,
            syncedLyrics: untimedBody
        )
        let realSyncedHigherID = LRCLIBCandidate(
            id: 38624267,
            trackName: "Berubah",
            artistName: "Tenxi, Jemsii",
            albumName: "REBEL HEART - Single",
            durationSeconds: 201.0,
            plainLyrics: untimedBody,
            syncedLyrics: "[00:15.10]Jangan nyesel semua problem kamu yang start\n[00:18.30]Jangan minta rewind aku kamu udah finish"
        )

        #expect(!LRCParser.hasTimedLines(fakeSyncedLowerID.syncedLyrics))
        #expect(LRCParser.hasTimedLines(realSyncedHigherID.syncedLyrics))
        #expect(LyricsMatcher.evaluateCandidates(query: query, candidates: [fakeSyncedLowerID, realSyncedHigherID]) == .matchedSynced(realSyncedHigherID))
    }

    @Test("Fake-synced candidate falls back cleanly to plain lyrics when no timed candidate exists")
    func fakeSyncedFallsBackToPlainWhenAlone() {
        let query = LyricsQueryTrack(
            title: "Berubah",
            artist: "Tenxi & Jemsii",
            durationSeconds: 200.5
        )
        let fakeSyncedOnly = LRCLIBCandidate(
            id: 24620315,
            trackName: "Berubah",
            artistName: "Tenxi, Jemsii",
            durationSeconds: 201.0,
            plainLyrics: nil,
            syncedLyrics: "Jangan nyesel semua problem kamu yang start\nJangan minta rewind aku kamu udah finish"
        )

        #expect(LyricsMatcher.evaluateCandidates(query: query, candidates: [fakeSyncedOnly]) == .matchedPlain(fakeSyncedOnly))
    }

    @Test("Monotonic request generation rejects stale A -> B -> A responses and revoked consent")
    func monotonicGenerationAndConsentGuard() {
        var tracker = LyricsRequestTracker()
        let trackA = LyricsQueryTrack(title: "Track A", artist: "Artist 1", durationSeconds: 200)
        let trackB = LyricsQueryTrack(title: "Track B", artist: "Artist 2", durationSeconds: 180)

        let genA1 = tracker.beginRequest(for: trackA)
        let genB = tracker.beginRequest(for: trackB)
        let genA2 = tracker.beginRequest(for: trackA)

        #expect(genA1 == 1)
        #expect(genB == 2)
        #expect(genA2 == 3)

        // Stale response from first play of Track A must be rejected even though Track A is active again
        #expect(!tracker.shouldAcceptResponse(generation: genA1, for: trackA, onlineConsentGranted: true))
        #expect(tracker.shouldAcceptResponse(generation: genA2, for: trackA, onlineConsentGranted: true))
        #expect(!tracker.shouldAcceptResponse(generation: genA2, for: trackA, onlineConsentGranted: false))
    }

    @Test("Negative cache policy only caches true notFound and never offline/429/5xx")
    func negativeCachePolicy() {
        #expect(LyricsMatcher.shouldWriteNegativeCache(for: .notFound))
        #expect(!LyricsMatcher.shouldWriteNegativeCache(for: .offline))
        #expect(!LyricsMatcher.shouldWriteNegativeCache(for: .rateLimited(retryAfterSeconds: 30)))
        #expect(!LyricsMatcher.shouldWriteNegativeCache(for: .serverError(statusCode: 503)))
    }
}
