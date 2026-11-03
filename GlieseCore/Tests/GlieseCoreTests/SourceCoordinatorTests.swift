// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import GlieseCore

private let spotify = SourceID(provider: .spotify)
private let brave = SourceID(provider: .brave, session: "tab-1")
private let brave2 = SourceID(provider: .brave, session: "tab-2")
private let safari = SourceID(provider: .safari, session: "s1")

@Suite("Source coordinator (auto)")
struct SourceCoordinatorAutoTests {
    @Test("sticky while selected is playing; two playing keep chosen; no ambiguity flag")
    func stickyWhenSelectedPlaying() {
        var c = SourceCoordinator()
        c.receive(.startedPlaying(spotify))
        c.receive(.startedPlaying(brave))
        let snap = c.snapshot()
        #expect(snap.selected == spotify)
        #expect(snap.isPlaying)
        #expect(!snap.ambiguous)
    }

    @Test("metadata only never changes selection")
    func metadataOnly() {
        var c = SourceCoordinator()
        c.receive(.startedPlaying(spotify))
        c.receive(.metadataUpdate(brave))
        c.receive(.paused(spotify))
        c.receive(.metadataUpdate(safari))
        #expect(c.snapshot().selected == spotify)
        #expect(c.revision == 1)
    }

    @Test("selected paused, another source truly starts: switch allowed")
    func pausedThenOtherStarts() {
        var c = SourceCoordinator()
        c.receive(.startedPlaying(spotify))
        c.receive(.paused(spotify))
        #expect(c.snapshot().selected == spotify)
        #expect(!c.snapshot().isPlaying)

        c.receive(.startedPlaying(safari))
        #expect(c.snapshot().selected == safari)
        #expect(c.snapshot().isPlaying)
        #expect(c.snapshot().selectedAvailable)
    }

    @Test("selected stopped completely, sole candidate takes over without ambiguity")
    func stoppedSwitchesToSoleCandidate() {
        var c = SourceCoordinator()
        c.receive(.startedPlaying(spotify))
        c.receive(.startedPlaying(brave))
        c.receive(.stopped(spotify))
        let snap = c.snapshot()
        #expect(snap.selected == brave)
        #expect(snap.isPlaying)
        #expect(!snap.ambiguous)
    }

    @Test("selected stopped while multiple candidates playing: newest trusted start wins, flagged ambiguous")
    func stoppedMultipleCandidatesAmbiguous() {
        var c = SourceCoordinator()
        c.receive(.startedPlaying(spotify))
        c.receive(.startedPlaying(brave))
        c.receive(.startedPlaying(safari))
        c.receive(.stopped(spotify))
        let snap = c.snapshot()
        #expect(snap.selected == safari)
        #expect(snap.ambiguous)
    }

    @Test("cold start: second source starting while first plays does not steal selection (two-playing rule)")
    func coldStartKeepsFirst() {
        var c = SourceCoordinator()
        c.receive(.startedPlaying(brave))
        #expect(c.snapshot().selected == brave)
        c.receive(.startedPlaying(safari))
        let snap = c.snapshot()
        #expect(snap.selected == brave)
        #expect(!snap.ambiguous) // switcher remains available for manual correction
    }

    @Test("session identity distinguishes two tabs of the same browser")
    func sessionIdentity() {
        var c = SourceCoordinator()
        c.receive(.startedPlaying(brave2))
        c.receive(.metadataUpdate(spotify))
        #expect(c.snapshot().selected == brave2)
        c.receive(.startedPlaying(brave))
        #expect(c.snapshot().selected == brave2) // tab-1 still live, sticky
        #expect(c.snapshot().selected?.session == "tab-2")
    }

    @Test("no automatic controls exist; selection is the coordinator's only output")
    func selectionOnly() {
        var c = SourceCoordinator()
        c.receive(.startedPlaying(spotify))
        c.receive(.startedPlaying(brave))
        #expect(c.playing.count == 2)
        #expect(c.snapshot().selected == spotify)
    }

    @Test("auto snapshot marks dead selected source as unavailable then drops it on confirmed stop")
    func deadSourceLifecycle() {
        var c = SourceCoordinator()
        c.receive(.startedPlaying(spotify))
        c.receive(.paused(spotify))
        #expect(c.snapshot().selectedAvailable)
        c.receive(.stopped(spotify))
        let snap = c.snapshot()
        #expect(snap.selected == nil)
        #expect(!snap.selectedAvailable)
    }
}

@Suite("Source coordinator (manual)")
struct SourceCoordinatorManualTests {
    @Test("manual stays pinned even when other sources play")
    func manualPinned() {
        var c = SourceCoordinator(mode: .manual(brave))
        c.receive(.startedPlaying(spotify))
        let snap = c.snapshot()
        #expect(snap.selected == brave)
        #expect(snap.selectedAvailable == false)
        #expect(!snap.isPlaying)
    }

    @Test("manual target lives, pauses, stops: availability follows without fallback")
    func manualLifecycle() {
        var c = SourceCoordinator(mode: .manual(brave))
        c.receive(.startedPlaying(brave))
        #expect(c.snapshot().selectedAvailable)
        #expect(c.snapshot().isPlaying)

        c.receive(.startedPlaying(spotify))
        #expect(c.snapshot().selected == brave)

        c.receive(.paused(brave))
        #expect(c.snapshot().selectedAvailable)
        #expect(!c.snapshot().isPlaying)

        c.receive(.stopped(brave))
        let snap = c.snapshot()
        #expect(snap.selected == brave) // pinned intent remains
        #expect(!snap.selectedAvailable)
        #expect(!snap.isPlaying)
        #expect(c.playing.isEmpty) // manual ignores non-target sources entirely

        c.receive(.metadataUpdate(spotify))
        #expect(!c.snapshot().selectedAvailable)
    }

    @Test("switching to manual tracks revision and drops ambiguity")
    func manualSwitchRevision() {
        var c = SourceCoordinator()
        c.receive(.startedPlaying(spotify))
        let before = c.revision
        c.setMode(.manual(safari))
        #expect(c.revision > before)
        #expect(c.snapshot().selected == safari)
    }
}
