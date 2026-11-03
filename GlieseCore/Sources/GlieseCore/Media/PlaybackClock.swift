// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One media playback observation from a provider. Optional fields are unknown, never zero.
public struct PlaybackSnapshot: Equatable {
    public let positionSeconds: Double?
    public let durationSeconds: Double?
    public let playing: Bool
    public let rate: Double

    public init(positionSeconds: Double?, durationSeconds: Double?, playing: Bool, rate: Double = 1.0) {
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
        self.playing = playing
        self.rate = rate
    }
}

/// Interpolates playback position between snapshots using injected monotonic time.
/// Anchors are replaced at every accepted snapshot; a snapshot after wake is the re-anchor path.
public final class PlaybackClock {
    private let now: () -> Double
    private var anchorPosition: Double = 0
    private var anchorTime: Double = 0
    private var rate: Double = 1
    private var duration: Double?
    private var _playing = false
    private var _anchored = false

    public private(set) var generation: Int = 0

    public init(now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    /// Fulfills "position nil is unknown, not zero": invalid or missing positions are rejected, nil keeps unknown.
    @discardableResult
    public func apply(_ snapshot: PlaybackSnapshot) -> Bool {
        if let p = snapshot.positionSeconds, !p.isFinite || p < 0 { return false }
        if let d = snapshot.durationSeconds, !d.isFinite || d < 0 { return false }
        guard snapshot.rate.isFinite, snapshot.rate >= 0 else { return false }

        _playing = snapshot.playing
        rate = snapshot.rate
        duration = snapshot.durationSeconds
        let carried = currentInterpolatedPosition()
        anchorTime = now()
        anchorPosition = snapshot.positionSeconds ?? carried
        _anchored = true
        generation += 1
        return true
    }

    /// Stops interpolation at the current position; used when playback controls pause or track ends.
    public func pause() {
        guard _anchored else { return }
        anchorPosition = currentInterpolatedPosition()
        anchorTime = now()
        _playing = false
    }

    public func position() -> Double? {
        guard _anchored else { return nil }
        return clamped(currentInterpolatedPosition())
    }

    public func durationSeconds() -> Double? { duration }

    public func isPlaying() -> Bool { _playing }

    private func currentInterpolatedPosition() -> Double {
        guard _playing else { return anchorPosition }
        return anchorPosition + rate * (now() - anchorTime)
    }

    private func clamped(_ value: Double) -> Double {
        var result = value
        if !result.isFinite || result < 0 { result = 0 }
        if let d = duration { result = min(d, result) }
        return result
    }
}
