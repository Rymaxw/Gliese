// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum SourceProvider: String, Equatable, CaseIterable, Sendable {
    case spotify
    case brave
    case safari
}

public struct SourceID: Equatable, Hashable, Sendable {
    public let provider: SourceProvider
    public let session: String?

    public init(provider: SourceProvider, session: String? = nil) {
        self.provider = provider
        self.session = session
    }
}

public enum SourceMode: Equatable {
    case auto
    case manual(SourceID)
}

/// Media events that drive source selection. Metadata-only updates must never change the selection.
public enum MediaSourceEvent: Equatable {
    case startedPlaying(SourceID)
    case paused(SourceID)
    case stopped(SourceID)
    case metadataUpdate(SourceID)
}

public struct SourceSelectionSnapshot: Equatable, Sendable {
    public let selected: SourceID?
    public let selectedAvailable: Bool
    public let isPlaying: Bool
    public let ambiguous: Bool

    init(selected: SourceID?, selectedAvailable: Bool, isPlaying: Bool, ambiguous: Bool) {
        self.selected = selected
        self.selectedAvailable = selectedAvailable
        self.isPlaying = isPlaying
        self.ambiguous = ambiguous
    }
}

/// Pure selection state machine.
/// Auto: sticky; switches only on real play transitions or source loss, never on metadata.
/// Manual: pinned target; dead target surfaces unavailable without falling back to another source.
/// Concurrency note: a true "two starts before any anchor" race with a timer is not modeled yet;
/// sequential events keep the first selection, which the recorded limitation and the UI switcher cover.
public struct SourceCoordinator: Equatable {
    public private(set) var mode: SourceMode
    public private(set) var selected: SourceID?
    public private(set) var playing: Set<SourceID> = []
    public private(set) var paused: Set<SourceID> = []
    /// Arrival order of last start events, newest last; drives "newest trusted start" tie-breaks.
    private var startOrder: [SourceID] = []
    public private(set) var ambiguous = false
    public private(set) var revision = 0

    public init(mode: SourceMode = .auto) {
        self.mode = mode
        if case .manual(let id) = mode { selected = id }
    }

    public static func == (lhs: SourceCoordinator, rhs: SourceCoordinator) -> Bool {
        lhs.mode == rhs.mode && lhs.selected == rhs.selected && lhs.playing == rhs.playing
            && lhs.paused == rhs.paused && lhs.ambiguous == rhs.ambiguous && lhs.revision == rhs.revision
    }

    public mutating func receive(_ event: MediaSourceEvent) {
        switch mode {
        case .auto:
            receiveAuto(event)
        case .manual(let target):
            receiveManual(event, target: target)
        }
    }

    public mutating func handle(_ event: MediaSourceEvent) {
        receive(event)
    }

    public mutating func setMode(_ newMode: SourceMode) {
        mode = newMode
        if case .manual(let id) = newMode {
            selected = id
            ambiguous = false
            revision += 1
        } else {
            // leaving manual: live tracking is stale, let auto re-learn from incoming events
            selected = nil
            playing = []
            paused = []
            startOrder = []
            ambiguous = false
            revision += 1
        }
    }

    private mutating func receiveAuto(_ event: MediaSourceEvent) {
        switch event {
        case .startedPlaying(let id):
            playing.insert(id)
            paused.remove(id)
            trackStart(id)
            if currentSelectionIsPlaying() {
                ambiguous = false
            } else if let chosen = newestPlaying(excluding: nil) {
                ambiguous = playing.count > 1
                select(chosen)
            }
        case .paused(let id):
            playing.remove(id)
            paused.insert(id)
        case .stopped(let id):
            playing.remove(id)
            paused.remove(id)
            forgetStart(id)
            if selected == id {
                let candidates = playing
                selected = candidates.count == 1 ? candidates.first : newestPlaying(excluding: nil)
                if candidates.count > 1 { ambiguous = true } else if candidates.isEmpty { ambiguous = false }
                if selected != nil { revision += 1 }
            }
        case .metadataUpdate:
            break
        }
    }

    private mutating func receiveManual(_ event: MediaSourceEvent, target: SourceID) {
        switch event {
        case .startedPlaying(let id):
            if id == target {
                playing.insert(id)
                paused.remove(id)
                trackStart(id)
                ambiguous = false
            }
        case .paused(let id):
            if id == target {
                playing.remove(id)
                paused.insert(id)
            }
        case .stopped(let id):
            if id == target {
                playing.remove(id)
                paused.remove(id)
                forgetStart(id)
            }
        case .metadataUpdate:
            break
        }
    }

    private mutating func trackStart(_ id: SourceID) {
        startOrder.removeAll { $0 == id }
        startOrder.append(id)
    }

    private mutating func forgetStart(_ id: SourceID) {
        startOrder.removeAll { $0 == id }
    }

    private func newestPlaying(excluding: SourceID?) -> SourceID? {
        for id in startOrder.reversed() {
            if id != excluding, playing.contains(id) { return id }
        }
        return nil
    }

    private func currentSelectionIsPlaying() -> Bool {
        guard let s = selected else { return false }
        return playing.contains(s)
    }

    private mutating func select(_ id: SourceID?) {
        if id != selected {
            selected = id
            revision += 1
        }
    }

    /// Snapshot for UI. Manual mode always reports its target; availability says alive or not.
    public func snapshot() -> SourceSelectionSnapshot {
        switch mode {
        case .auto:
            let alive = selected.map { playing.contains($0) || paused.contains($0) } ?? false
            return SourceSelectionSnapshot(
                selected: selected,
                selectedAvailable: alive,
                isPlaying: currentSelectionIsPlaying(),
                ambiguous: ambiguous
            )
        case .manual(let target):
            let alive = playing.contains(target) || paused.contains(target)
            return SourceSelectionSnapshot(
                selected: target,
                selectedAvailable: alive,
                isPlaying: playing.contains(target),
                ambiguous: ambiguous
            )
        }
    }
}
