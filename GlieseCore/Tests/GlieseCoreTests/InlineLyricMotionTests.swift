import Testing
@testable import GlieseCore

@Suite("Inline lyric motion")
struct InlineLyricMotionTests {
    private func line(_ index: Int, track: String = "fixture") -> InlineLyricMotion.Line {
        .init(track: track, index: index, text: "Fixture lyric \(index)")
    }

    @Test func transitionsOnlyOnLineChangesAndReplacesInterruptedAnimation() {
        var motion = InlineLyricMotion()
        motion.update(line: line(0), position: 0, time: 0, playing: true, reduceMotion: false)
        motion.update(line: line(0), position: 0.1, time: 0.1, playing: true, reduceMotion: false)
        #expect(motion.outgoing == nil)
        motion.update(line: line(1), position: 0.2, time: 0.2, playing: true, reduceMotion: false)
        #expect(motion.outgoing == line(0))
        motion.update(line: line(2), position: 0.3, time: 0.3, playing: true, reduceMotion: false)
        #expect(motion.outgoing == line(1))
        #expect(motion.current == line(2))
        motion.update(line: line(2), position: 0.6, time: 0.6, playing: true, reduceMotion: false)
        #expect(motion.progress == 1)
        #expect(motion.outgoing == nil)
    }

    @Test func seekAndTrackSwitchDiscardOldLinesEvenWhenTextIsEqual() {
        var motion = InlineLyricMotion()
        motion.update(line: line(0), position: 0, time: 0, playing: true, reduceMotion: false)
        motion.update(line: line(4), position: 30, time: 0.1, playing: true, reduceMotion: false)
        #expect(motion.outgoing == nil)
        motion.update(line: line(0), position: 1, time: 0.2, playing: true, reduceMotion: false)
        #expect(motion.progress == 1)
        motion.update(line: line(0, track: "other"), position: 1.1, time: 0.3, playing: true, reduceMotion: false)
        #expect(motion.current?.track == "other")
        #expect(motion.outgoing == nil)
        #expect(motion.readingTime == 0)
    }

    @Test func pauseFreezesScrollAndResumeDoesNotCountPausedTime() {
        var motion = InlineLyricMotion()
        motion.update(line: line(0), position: 0, time: 0, playing: true, reduceMotion: false)
        motion.update(line: line(0), position: 2, time: 2, playing: true, reduceMotion: false)
        let beforePause = motion.readingTime
        motion.update(line: line(0), position: 2, time: 2, playing: false, reduceMotion: false)
        motion.update(line: line(0), position: 2, time: 12, playing: false, reduceMotion: false)
        motion.update(line: line(0), position: 2, time: 12, playing: true, reduceMotion: false)
        #expect(motion.readingTime == beforePause)
        #expect(motion.current == line(0))
    }

    @Test func reducedMotionAndOverflowBounds() {
        var motion = InlineLyricMotion()
        motion.update(line: line(0), position: 0, time: 0, playing: true, reduceMotion: false)
        motion.update(line: line(1), position: 0.1, time: 0.1, playing: true, reduceMotion: false)
        motion.update(line: line(1), position: 0.2, time: 0.2, playing: true, reduceMotion: true)
        #expect(motion.outgoing == nil)
        #expect(motion.readingTime == 0)
        #expect(InlineLyricMotion.scrollOffset(textWidth: 500, availableWidth: 200, readingTime: 1) == 0)
        #expect(InlineLyricMotion.scrollOffset(textWidth: 500, availableWidth: 200, readingTime: 100) == 300)
        #expect(InlineLyricMotion.scrollOffset(textWidth: 100, availableWidth: 200, readingTime: 100) == 0)
    }

    @Test func rateAdjustedPlaybackDoesNotLookLikeASeek() {
        var motion = InlineLyricMotion()
        motion.update(line: line(0), position: 0, time: 0, playing: true, reduceMotion: false, playbackRate: 2)
        motion.update(line: line(0), position: 4, time: 2, playing: true, reduceMotion: false, playbackRate: 2)
        #expect(motion.readingTime == 2)
        motion.update(line: line(0), position: 4, time: 2, playing: false, reduceMotion: false)
        motion.update(line: line(0), position: 20, time: 3, playing: false, reduceMotion: false)
        #expect(motion.readingTime == 0)
        #expect(motion.outgoing == nil)
    }
}
