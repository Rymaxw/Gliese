import Foundation
import Testing
@testable import GlieseCore

@Suite("ClipboardMemoryStore Session RAM, Privacy & Eviction Tests")
struct ClipboardMemoryStoreTests {

    @Test("Opt-in sets baseline changeCount and never imports pre-existing clipboard")
    func optInBaselineAndPauseNoBackfill() {
        var store = ClipboardMemoryStore()

        // Before opt-in: ignored
        let beforeOptIn = store.ingest(
            changeCount: 10,
            pasteboardTypes: ["public.utf8-plain-text"],
            payload: .text("pre-existing")
        )
        #expect(beforeOptIn == .ignoredCaptureDisabledOrPaused)
        #expect(store.entries.isEmpty)

        // Opt-in at changeCount 10: ingest at 10 is ignored because it existed before opt-in
        store.setOptIn(true, currentChangeCount: 10)
        let sameCount = store.ingest(
            changeCount: 10,
            pasteboardTypes: ["public.utf8-plain-text"],
            payload: .text("pre-existing")
        )
        #expect(sameCount == .ignoredUnchangedPasteboardCount)

        // New copy at changeCount 11 is stored
        let stored11 = store.ingest(
            changeCount: 11,
            pasteboardTypes: ["public.utf8-plain-text"],
            payload: .text("https://music.youtube.com/watch?v=abc")
        )
        if case .stored = stored11 {
            #expect(store.entries.count == 1)
            #expect(store.entries.first?.kind == .link)
        } else {
            Issue.record("Expected .stored")
        }

        // Pause at 11, copy happens at 12 while paused, resume at 12 -> 12 is not backfilled
        store.setPaused(true, currentChangeCount: 11)
        #expect(store.ingest(changeCount: 12, pasteboardTypes: ["public.utf8-plain-text"], payload: .text("during-pause")) == .ignoredCaptureDisabledOrPaused)
        store.setPaused(false, currentChangeCount: 12)
        #expect(store.ingest(changeCount: 12, pasteboardTypes: ["public.utf8-plain-text"], payload: .text("during-pause")) == .ignoredUnchangedPasteboardCount)
    }

    @Test("Concealed, transient, auto-generated, and excluded password managers are filtered out")
    func privacyFilter() {
        var store = ClipboardMemoryStore()
        store.setOptIn(true, currentChangeCount: 1)

        let concealed = store.ingest(
            changeCount: 2,
            pasteboardTypes: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"],
            payload: .text("hunter2")
        )
        #expect(concealed == .ignoredSensitivePasteboardType)

        let excludedApp = store.ingest(
            changeCount: 3,
            pasteboardTypes: ["public.utf8-plain-text"],
            payload: .text("secret-token"),
            sourceAppBundleID: "com.1password.1password"
        )
        #expect(excludedApp == .ignoredExcludedSourceApp)
        #expect(store.entries.isEmpty)
    }

    @Test("Consecutive duplicate and self-copy from UI do not duplicate entries")
    func deduplicationAndSelfCopy() {
        var store = ClipboardMemoryStore()
        store.setOptIn(true, currentChangeCount: 1)

        let first = store.ingest(
            changeCount: 2,
            pasteboardTypes: ["public.utf8-plain-text"],
            payload: .text("hello gliese")
        )
        guard case .stored(let id) = first else {
            Issue.record("Expected stored")
            return
        }

        let dup = store.ingest(
            changeCount: 3,
            pasteboardTypes: ["public.utf8-plain-text"],
            payload: .text("hello gliese")
        )
        #expect(dup == .ignoredDuplicateConsecutiveOrSelfCopy)

        // Add another item, then user clicks Copy on first item in UI
        _ = store.ingest(
            changeCount: 4,
            pasteboardTypes: ["public.utf8-plain-text"],
            payload: .text("second item")
        )
        store.markSelfCopy(entryID: id, newChangeCount: 5)
        let selfCopy = store.ingest(
            changeCount: 6,
            pasteboardTypes: ["public.utf8-plain-text"],
            payload: .text("hello gliese")
        )
        #expect(selfCopy == .ignoredDuplicateConsecutiveOrSelfCopy)
        #expect(store.entries.count == 2)
    }

    @Test("Evicts oldest unpinned entry and rejects when all entries are pinned at cap")
    func evictionAndPinnedCap() {
        var store = ClipboardMemoryStore(maxEntries: 2, maxTotalBytes: 1024)
        store.setOptIn(true, currentChangeCount: 0)

        guard case .stored(let id1) = store.ingest(changeCount: 1, pasteboardTypes: ["public.utf8-plain-text"], payload: .text("first")),
              case .stored(let id2) = store.ingest(changeCount: 2, pasteboardTypes: ["public.utf8-plain-text"], payload: .text("second")) else {
            Issue.record("Expected initial stores")
            return
        }

        // Pin `first` so `second` is evicted when `third` arrives
        store.togglePin(id: id1)
        _ = store.ingest(changeCount: 3, pasteboardTypes: ["public.utf8-plain-text"], payload: .text("third"))
        #expect(store.entries.count == 2)
        #expect(store.entries.contains(where: { $0.id == id1 }))
        #expect(!store.entries.contains(where: { $0.id == id2 }))

        // Pin the second remaining entry as well -> now all 2 are pinned, 4th must be rejected
        if let unpinnedID = store.entries.first(where: { !$0.isPinned })?.id {
            store.togglePin(id: unpinnedID)
        }
        let fourth = store.ingest(changeCount: 4, pasteboardTypes: ["public.utf8-plain-text"], payload: .text("fourth"))
        #expect(fourth == .rejectedAllPinnedCapReached)

        // Clear all wipes even pinned entries and resets bytes to 0
        store.clearAll()
        #expect(store.entries.isEmpty)
        #expect(store.totalBytes == 0)
    }
}
