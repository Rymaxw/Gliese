// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import GlieseCore

@Suite("Playback clock")
struct PlaybackClockTests {
    @Test("unknown state has no position before first snapshot")
    func initialState() {
        let fake = 0.0
        let clock = PlaybackClock(now: { fake })
        #expect(clock.position() == nil)
        #expect(!clock.isPlaying())
    }

    @Test("pause holds position, play advances by rate")
    func pauseAndAdvance() {
        var fake = 100.0
        let clock = PlaybackClock(now: { fake })
        #expect(clock.apply(PlaybackSnapshot(positionSeconds: 30, durationSeconds: 200, playing: false)))
        #expect(clock.position() == 30)

        fake = 102.0
        #expect(clock.position() == 30) // paused holds

        #expect(clock.apply(PlaybackSnapshot(positionSeconds: 30, durationSeconds: 200, playing: true, rate: 1.0)))
        fake = 103.5
        #expect(clock.position() == 31.5)
    }

    @Test("seek forward and backward re-anchor")
    func seek() {
        var fake = 0.0
        let clock = PlaybackClock(now: { fake })
        #expect(clock.apply(PlaybackSnapshot(positionSeconds: 10, durationSeconds: 100, playing: true)))
        fake = 5.0
        let drifted = clock.position() ?? -1
        #expect(abs(drifted - 15.0) < 0.0001)

        #expect(clock.apply(PlaybackSnapshot(positionSeconds: 55, durationSeconds: 100, playing: true)))
        fake = 10.0
        #expect(clock.position() == 60)
    }

    @Test("rate affects interpolation")
    func rate() {
        var fake = 0.0
        let clock = PlaybackClock(now: { fake })
        #expect(clock.apply(PlaybackSnapshot(positionSeconds: 0, durationSeconds: 60, playing: true, rate: 2.0)))
        fake = 10.0
        #expect(clock.position() == 20)
        #expect(clock.apply(PlaybackSnapshot(positionSeconds: 20, durationSeconds: 60, playing: true, rate: 0.5)))
        fake = 20.0
        #expect(clock.position() == 25)
    }

    @Test("clamps to duration when known, unbounded when unknown")
    func durationClamp() {
        var fake = 0.0
        let clock = PlaybackClock(now: { fake })
        #expect(clock.apply(PlaybackSnapshot(positionSeconds: 95, durationSeconds: 100, playing: true)))
        fake = 60.0 // long drift, duration still bounds it
        #expect(clock.position() == 100)

        var fake2 = 0.0
        let unknown = PlaybackClock(now: { fake2 })
        #expect(unknown.apply(PlaybackSnapshot(positionSeconds: 5, durationSeconds: nil, playing: true)))
        fake2 = 40.0
        #expect(unknown.position() == 45)
    }

    @Test("rejects invalid values")
    func invalidRejected() {
        let fake = 0.0
        let clock = PlaybackClock(now: { fake })
        #expect(clock.generation == 0)
        #expect(!clock.apply(PlaybackSnapshot(positionSeconds: .nan, durationSeconds: 10, playing: true)))
        #expect(!clock.apply(PlaybackSnapshot(positionSeconds: 1, durationSeconds: .infinity, playing: true)))
        #expect(!clock.apply(PlaybackSnapshot(positionSeconds: -5, durationSeconds: 10, playing: true)))
        #expect(!clock.apply(PlaybackSnapshot(positionSeconds: 1, durationSeconds: 10, playing: true, rate: .infinity)))
        #expect(clock.generation == 0)
        #expect(clock.position() == nil)
    }

    @Test("nil position keeps unknown, anchored state preserved")
    func nilPositionCarry() {
        var fake = 0.0
        let clock = PlaybackClock(now: { fake })
        #expect(clock.apply(PlaybackSnapshot(positionSeconds: 10, durationSeconds: 100, playing: true)))
        fake = 3.0
        // in-flight snapshot without position must not reset to zero
        #expect(clock.apply(PlaybackSnapshot(positionSeconds: nil, durationSeconds: 100, playing: true)))
        fake = 4.0
        #expect(clock.position() == 14)
    }

    @Test("pause() freezes interpolation at call time")
    func pauseFreeze() {
        var fake = 0.0
        let clock = PlaybackClock(now: { fake })
        #expect(clock.apply(PlaybackSnapshot(positionSeconds: 0, durationSeconds: 60, playing: true, rate: 1.0)))
        fake = 10.0
        clock.pause()
        fake = 30.0
        #expect(clock.position() == 10)
        #expect(!clock.isPlaying())
        #expect(clock.generation == 1)
    }

    @Test("sleep: fresh snapshot re-anchors despite clock regression")
    func sleepReanchor() {
        var fake = 1000.0
        let clock = PlaybackClock(now: { fake })
        #expect(clock.apply(PlaybackSnapshot(positionSeconds: 100, durationSeconds: 300, playing: true)))
        fake = 900.0 // simulated wake: monotonic source reset backward
        #expect(clock.apply(PlaybackSnapshot(positionSeconds: 200, durationSeconds: 300, playing: true)))
        fake = 905.0
        #expect(clock.position() == 205)
    }

    @Test("generation increments only on accepted snapshots")
    func generation() {
        let fake = 0.0
        let clock = PlaybackClock(now: { fake })
        #expect(clock.apply(PlaybackSnapshot(positionSeconds: 1, durationSeconds: 2, playing: true)))
        #expect(clock.apply(PlaybackSnapshot(positionSeconds: 2, durationSeconds: 2, playing: false)))
        #expect(!clock.apply(PlaybackSnapshot(positionSeconds: 2, durationSeconds: -2, playing: false)))
        #expect(clock.generation == 2)
    }

    @Test("pause-wait-resume never adds paused duration and track change resets to zero")
    func pauseWaitResumeAndTrackReset() {
        var fake = 50.0
        let clock = PlaybackClock(now: { fake })
        #expect(clock.apply(PlaybackSnapshot(positionSeconds: 10.0, durationSeconds: 200.0, playing: true, rate: 1.0)))

        // Advance 25s, then pause at 35s
        fake = 75.0
        #expect(clock.position() == 35.0)
        #expect(clock.apply(PlaybackSnapshot(positionSeconds: 35.0, durationSeconds: 200.0, playing: false, rate: 0.0)))

        // Wait 120s while paused -> position stays pinned at 35s
        fake = 195.0
        #expect(clock.position() == 35.0)

        // Resume at 35s with rate 1.0 -> 4.5s later should be 39.5s (no pause-duration leak)
        #expect(clock.apply(PlaybackSnapshot(positionSeconds: 35.0, durationSeconds: 200.0, playing: true, rate: 1.0)))
        fake = 199.5
        #expect(clock.position() == 39.5)

        // Track change re-anchors cleanly to 0 with new duration
        #expect(clock.apply(PlaybackSnapshot(positionSeconds: 0.0, durationSeconds: 180.0, playing: true, rate: 1.0)))
        #expect(clock.position() == 0.0)
        fake = 202.0
        #expect(clock.position() == 2.5)
    }

    @Test("buffering (playing=true, rate=0.0) holds position until rate transitions to > 0")
    func bufferingZeroRateFreezesUntilReady() {
        var fake = 10.0
        let clock = PlaybackClock(now: { fake })

        // Track begins buffering at 0.0 with playing=true, explicit rate=0.0
        #expect(clock.apply(PlaybackSnapshot(positionSeconds: 0.0, durationSeconds: 201.0, playing: true, rate: 0.0)))
        #expect(clock.position() == 0.0)

        // 1.5s of network buffering passes -> position must stay pinned at 0.0 (no early head-start)
        fake = 11.5
        #expect(clock.position() == 0.0)

        // Buffering finishes and audio actually starts (rate transitions 0.0 -> 1.0 at position 0.0)
        #expect(clock.apply(PlaybackSnapshot(positionSeconds: 0.0, durationSeconds: 201.0, playing: true, rate: 1.0)))
        #expect(clock.position() == 0.0)

        // 15.1s of actual playback passes -> position is exactly 15.1s (not 16.6s!)
        fake = 26.6
        #expect(abs((clock.position() ?? -1) - 15.1) < 0.0001)
    }
}
