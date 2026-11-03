// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct ActiveLyricSelection: Equatable, Sendable {
    public let index: Int
    public let line: LyricLine
    public let effectiveTimestamp: Double

    public init(index: Int, line: LyricLine, effectiveTimestamp: Double) {
        self.index = index
        self.line = line
        self.effectiveTimestamp = effectiveTimestamp
    }
}

public struct LyricsTimeline: Equatable, Sendable {
    public static let minUserOffsetSeconds: Double = -10.0
    public static let maxUserOffsetSeconds: Double = 10.0
    public static let defaultStepSeconds: Double = 0.5

    public let file: LRCFile
    public private(set) var userOffsetSeconds: Double = 0.0
    public private(set) var isFollowing: Bool = true

    public init(file: LRCFile, userOffsetSeconds: Double = 0.0) {
        self.file = file
        self.userOffsetSeconds = Self.clampOffset(userOffsetSeconds)
    }

    public mutating func setUserOffset(_ seconds: Double) {
        guard seconds.isFinite else { return }
        userOffsetSeconds = Self.clampOffset(seconds)
    }

    public mutating func stepUserOffset(steps: Int) {
        let next = userOffsetSeconds + Double(steps) * Self.defaultStepSeconds
        // Round to nearest millisecond to avoid binary floating-point drift across steps.
        let rounded = (next * 1000.0).rounded() / 1000.0
        userOffsetSeconds = Self.clampOffset(rounded)
    }

    public mutating func stepUserOffset(by delta: Double) {
        setUserOffset(userOffsetSeconds + delta)
    }

    public mutating func resetUserOffset() {
        userOffsetSeconds = 0.0
    }

    public mutating func userScrolled() {
        isFollowing = false
    }

    public mutating func pauseFollowForManualScroll() {
        userScrolled()
    }

    public mutating func resumeFollow() {
        isFollowing = true
    }

    /// Active line is the last line whose effective timestamp <= playbackPositionSeconds.
    /// File offset and user offset are combined once from raw timestamps, never double-counted.
    public func activeLine(at playbackPositionSeconds: Double?) -> ActiveLyricSelection? {
        guard let pos = playbackPositionSeconds, pos.isFinite, pos >= 0 else {
            return nil
        }
        let fileOffsetSeconds = Double(file.offsetTagMilliseconds ?? 0) / 1000.0
        let totalShiftSeconds = fileOffsetSeconds + userOffsetSeconds

        var matched: ActiveLyricSelection?
        for (idx, line) in file.lines.enumerated() {
            let effective = max(0.0, line.timestampSeconds - totalShiftSeconds)
            if effective <= pos {
                matched = ActiveLyricSelection(index: idx, line: line, effectiveTimestamp: effective)
            } else {
                break
            }
        }
        return matched
    }

    private static func clampOffset(_ value: Double) -> Double {
        guard value.isFinite else { return 0.0 }
        return min(maxUserOffsetSeconds, max(minUserOffsetSeconds, value))
    }
}
