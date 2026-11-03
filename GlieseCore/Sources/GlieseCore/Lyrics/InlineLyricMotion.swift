import Foundation

public struct InlineLyricMotion: Equatable {
    public struct Line: Equatable {
        public let track: String
        public let index: Int?
        public let text: String

        public init(track: String, index: Int?, text: String) {
            self.track = track
            self.index = index
            self.text = text
        }
    }

    public static let transitionDuration = 0.22
    public private(set) var current: Line?
    public private(set) var outgoing: Line?
    public private(set) var progress: Double = 1
    public private(set) var readingTime: Double = 0
    public private(set) var outgoingReadingTime: Double = 0
    private var lastTime: Double?
    private var lastPosition: Double?
    private var wasPlaying = false
    private var lastRate: Double = 1
    private var transitionStart: Double = 0

    public init() {}

    public mutating func update(line: Line, position: Double, time: Double, playing: Bool, reduceMotion: Bool, playbackRate: Double = 1) {
        let delta = max(0, time - (lastTime ?? time))
        let expectedAdvance = wasPlaying ? delta * lastRate : 0
        let discontinuity = lastPosition.map { abs(position - $0 - expectedAdvance) > 0.75 } ?? false
        let trackChanged = current?.track != line.track
        let changed = current != line
        let interrupted = trackChanged || discontinuity || reduceMotion

        if interrupted {
            current = line
            outgoing = nil
            progress = 1
            readingTime = 0
        } else if changed {
            outgoing = current
            outgoingReadingTime = readingTime
            current = line
            transitionStart = time
            progress = 0
            readingTime = 0
        } else {
            if outgoing != nil {
                progress = min(1, max(0, (time - transitionStart) / Self.transitionDuration))
                if progress >= 1 { outgoing = nil }
            }
            if playing && wasPlaying { readingTime += delta }
        }
        lastTime = time
        lastPosition = position
        wasPlaying = playing
        lastRate = playbackRate
    }

    public static func scrollOffset(textWidth: Double, availableWidth: Double, readingTime: Double) -> Double {
        let overflow = max(0, textWidth - max(0, availableWidth))
        return min(overflow, max(0, readingTime - transitionDuration - 1.0) * 24)
    }
}
