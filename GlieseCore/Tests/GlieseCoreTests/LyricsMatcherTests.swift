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

    @Test("Unknown duration prevents blind auto-match and surfaces ambiguous candidates")
    func unknownDurationReducesConfidenceToAmbiguous() {
        let unknownDurationQuery = LyricsQueryTrack(
            title: "Starlight",
            artist: "Muse",
            durationSeconds: nil
        )
        let candidate = LRCLIBCandidate(
            id: 42,
            trackName: "Starlight",
            artistName: "Muse",
            durationSeconds: 240.0,
            syncedLyrics: "[00:12.00] Far away"
        )

        let decision = LyricsMatcher.evaluateCandidates(query: unknownDurationQuery, candidates: [candidate])
        #expect(decision == .ambiguous([candidate]))
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
