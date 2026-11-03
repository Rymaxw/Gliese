// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import GlieseCore

@Suite("Lyrics timeline")
struct LyricsTimelineTests {
    private func makeFile(_ rawLRC: String) throws -> LRCFile {
        let outcome = try LRCParser.parse(Data(rawLRC.utf8))
        guard case .timed(let file) = outcome else {
            throw LRCParseError.invalidUTF8
        }
        return file
    }

    @Test("before first line returns nil; exact boundary and after last line select expected line")
    func boundariesAndAfterLast() throws {
        let file = try makeFile("""
        [00:05.00] First line
        [00:10.50] Second line
        [00:20.00] Third line
        """)
        let timeline = LyricsTimeline(file: file)

        #expect(timeline.activeLine(at: 0.0) == nil)
        #expect(timeline.activeLine(at: 4.999) == nil)

        let exactFirst = timeline.activeLine(at: 5.0)
        #expect(exactFirst?.index == 0)
        #expect(exactFirst?.line.text == "First line")

        let midSecond = timeline.activeLine(at: 10.5)
        #expect(midSecond?.index == 1)
        #expect(midSecond?.line.text == "Second line")

        let afterLast = timeline.activeLine(at: 999.0)
        #expect(afterLast?.index == 2)
        #expect(afterLast?.line.text == "Third line")
    }

    @Test("duplicate timestamps pick last stable ordinal at that timestamp")
    func duplicateTimestampLastWins() throws {
        let file = try makeFile("""
        [00:10.00] Line A
        [00:10.00] Line B
        [00:15.00] Line C
        """)
        let timeline = LyricsTimeline(file: file)
        let active = timeline.activeLine(at: 10.0)
        #expect(active?.index == 1)
        #expect(active?.line.text == "Line B")
    }

    @Test("pause and backward seek select matching earlier line or nil")
    func pauseAndSeekBackward() throws {
        let file = try makeFile("""
        [00:04.00] Intro
        [00:12.00] Verse
        [00:24.00] Chorus
        """)
        var fakeNow = 0.0
        let clock = PlaybackClock(now: { fakeNow })
        let timeline = LyricsTimeline(file: file)

        #expect(clock.apply(PlaybackSnapshot(positionSeconds: 12.0, durationSeconds: 60.0, playing: true)))
        #expect(timeline.activeLine(at: clock.position())?.line.text == "Verse")

        fakeNow = 5.0
        clock.pause()
        #expect(timeline.activeLine(at: clock.position())?.line.text == "Verse")

        // Seek backward before Verse
        #expect(clock.apply(PlaybackSnapshot(positionSeconds: 6.0, durationSeconds: 60.0, playing: true)))
        #expect(timeline.activeLine(at: clock.position())?.line.text == "Intro")

        // Seek backward before first line
        #expect(clock.apply(PlaybackSnapshot(positionSeconds: 1.0, durationSeconds: 60.0, playing: false)))
        #expect(timeline.activeLine(at: clock.position()) == nil)
    }

    @Test("file offset and user offset are separated and never double-counted")
    func fileAndUserOffsetSeparated() throws {
        // [offset:+1000] shifts lines 1.0s earlier (10.0 -> 9.0)
        let file = try makeFile("""
        [offset:+1000]
        [00:10.00] Ten seconds raw
        [00:20.00] Twenty seconds raw
        """)
        var timeline = LyricsTimeline(file: file)
        #expect(timeline.activeLine(at: 8.9) == nil)
        #expect(timeline.activeLine(at: 9.0)?.line.text == "Ten seconds raw")

        // User negative offset -2.0s shifts lyrics 2.0s later (9.0 -> 11.0)
        timeline.setUserOffset(-2.0)
        #expect(timeline.activeLine(at: 10.5) == nil)
        #expect(timeline.activeLine(at: 11.0)?.line.text == "Ten seconds raw")
        #expect(timeline.activeLine(at: 11.0)?.effectiveTimestamp == 11.0)

        // Reset user offset returns to file offset only (9.0), never double-applying file offset
        timeline.resetUserOffset()
        #expect(timeline.userOffsetSeconds == 0.0)
        #expect(timeline.activeLine(at: 9.0)?.effectiveTimestamp == 9.0)
    }

    @Test("user offset clamps to [-10, +10] and steps by 0.5s")
    func userOffsetClampAndStep() throws {
        let file = try makeFile("[00:05.00] Hello")
        var timeline = LyricsTimeline(file: file, userOffsetSeconds: 99.0)
        #expect(timeline.userOffsetSeconds == 10.0)

        timeline.setUserOffset(-25.0)
        #expect(timeline.userOffsetSeconds == -10.0)

        timeline.resetUserOffset()
        timeline.stepUserOffset(steps: -3)
        #expect(timeline.userOffsetSeconds == -1.5)
        timeline.stepUserOffset(steps: 5)
        #expect(timeline.userOffsetSeconds == 1.0)
    }

    @Test("rejects nil, negative, NaN, and infinite playback times")
    func nonFiniteAndNegativeRejected() throws {
        let file = try makeFile("[00:00.00] Zero line")
        let timeline = LyricsTimeline(file: file)
        #expect(timeline.activeLine(at: nil) == nil)
        #expect(timeline.activeLine(at: -0.01) == nil)
        #expect(timeline.activeLine(at: .nan) == nil)
        #expect(timeline.activeLine(at: .infinity) == nil)
        #expect(timeline.activeLine(at: -.infinity) == nil)
        #expect(timeline.activeLine(at: 0.0)?.line.text == "Zero line")
    }

    @Test("manual scroll pauses auto-follow until Follow is resumed")
    func manualScrollAndFollow() throws {
        let file = try makeFile("[00:01.00] Line")
        var timeline = LyricsTimeline(file: file)
        #expect(timeline.isFollowing)
        timeline.userScrolled()
        #expect(!timeline.isFollowing)
        timeline.resumeFollow()
        #expect(timeline.isFollowing)
    }
}
