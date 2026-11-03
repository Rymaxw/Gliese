import Foundation

/// Pure policy and state machines for Gliese's per-app audio mixer and output router (T04 / T07).
///
/// Design invariants from `PLAN.md` and `ARCHITECTURE.md`:
/// 1. Volume range is strictly `0.0...1.0` (0%–100%) with no boost (`> 1.0`) or limiter.
/// 2. Unity bypass: an unmuted app at 100% volume on the system default output requires no tap/aggregate engine.
/// 3. Missing selected output device falls back cleanly to system default (`effectiveDeviceUID == nil`) while
///    preserving `selectedDeviceUID` so reconnecting the device restores routing automatically.
/// 4. Gliese never taps its own process (`com.rymaxw.gliese`), preventing feedback loops and Now Playing self-attribution.
/// 5. Async engine builds are fenced by monotonic tokens so a superseded build never installs a second live tap.
public enum AudioMixerPolicy {
    public static let minVolume: Double = 0.0
    public static let maxVolume: Double = 1.0
    public static let unityTolerance: Double = 0.0005
    public static let maxParentSearchDepth: Int = 6
    public static let renderStartupGraceSeconds: TimeInterval = 0.5
    public static let idleProcessTeardownDelaySeconds: TimeInterval = 0.5
    public static let glieseBundleIdentifier = "com.rymaxw.gliese"
    public static let glieseBundleID = "com.rymaxw.gliese"

    public struct AppAudioSetting: Equatable, Sendable {
        public var bundleIdentifier: String
        public var volume: Double
        public var isMuted: Bool
        public var selectedDeviceUID: String?

        public init(
            bundleIdentifier: String,
            volume: Double = AudioMixerPolicy.maxVolume,
            isMuted: Bool = false,
            selectedDeviceUID: String? = nil
        ) {
            self.bundleIdentifier = bundleIdentifier
            self.volume = AudioMixerPolicy.clampVolume(volume)
            self.isMuted = isMuted
            self.selectedDeviceUID = selectedDeviceUID
        }
    }

    public struct RouteResolution: Equatable, Sendable {
        public let selectedDeviceUID: String?
        public let effectiveDeviceUID: String?
        public let isSelectedDeviceUnavailable: Bool

        public var didFallbackToSystemDefault: Bool {
            isSelectedDeviceUnavailable && selectedDeviceUID != nil
        }

        public init(
            selectedDeviceUID: String?,
            effectiveDeviceUID: String?,
            isSelectedDeviceUnavailable: Bool
        ) {
            self.selectedDeviceUID = selectedDeviceUID
            self.effectiveDeviceUID = effectiveDeviceUID
            self.isSelectedDeviceUnavailable = isSelectedDeviceUnavailable
        }
    }

    public static func resolveRoute(
        selectedDeviceUID: String?,
        availableDeviceUIDs: Set<String>
    ) -> RouteResolution {
        let uidsArray = Array(availableDeviceUIDs)
        let effective = effectiveDeviceUID(selectedUID: selectedDeviceUID, availableUIDs: uidsArray)
        let unavailable = isSelectedOutputUnavailable(selectedUID: selectedDeviceUID, availableUIDs: uidsArray)
        return RouteResolution(
            selectedDeviceUID: selectedDeviceUID,
            effectiveDeviceUID: effective,
            isSelectedDeviceUnavailable: unavailable
        )
    }

    public static func requiresTapEngine(
        for setting: AppAudioSetting,
        effectiveDeviceUID: String?,
        systemDefaultDeviceUID: String
    ) -> Bool {
        if setting.isMuted { return true }
        if !isUnity(volume: setting.volume, isMuted: false) { return true }
        if let effective = effectiveDeviceUID, effective != systemDefaultDeviceUID {
            return true
        }
        return false
    }

    public static func gainScalar(for setting: AppAudioSetting) -> Float {
        gain(forVolume: setting.volume, isMuted: setting.isMuted)
    }

    public struct ProcessNode: Equatable, Sendable {
        public let pid: Int32
        public let ppid: Int32
        public let bundleIdentifier: String?

        public init(pid: Int32, ppid: Int32, bundleIdentifier: String?) {
            self.pid = pid
            self.ppid = ppid
            self.bundleIdentifier = bundleIdentifier
        }
    }

    public static func isSelfOrDescendant(
        pid: Int32,
        selfPID: Int32,
        processTable: [Int32: ProcessNode]
    ) -> Bool {
        if pid == selfPID { return true }
        var current = pid
        for _ in 0..<maxParentSearchDepth {
            guard let node = processTable[current], node.ppid > 1 else { break }
            if node.ppid == selfPID { return true }
            current = node.ppid
        }
        return false
    }

    public struct EngineTokenFence: Sendable {
        private var tracker = AudioEngineBuildTracker()

        public init() {}

        public mutating func issueToken(for rowID: String) -> UInt64 {
            tracker.beginBuild(for: rowID)
        }

        public func isCurrent(token: UInt64, for rowID: String) -> Bool {
            tracker.isCurrentBuild(token, for: rowID)
        }

        public mutating func invalidate(for rowID: String) {
            tracker.cancelBuild(for: rowID)
        }
    }

    /// Apps whose voice-processing / echo-cancellation pipeline breaks if their output is re-rendered
    /// while they are actively capturing microphone input.
    public static let echoCancelledCallBundleIdentifiers: Set<String> = [
        "com.apple.FaceTime",
        "com.apple.TelephonyUtilities",
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.webex.meetingmanager",
    ]

    /// Clamps a user or persisted volume into `0.0...1.0`. Non-finite values default to `1.0` (unity).
    public static func clampVolume(_ volume: Double) -> Double {
        guard volume.isFinite else { return maxVolume }
        return min(max(volume, minVolume), maxVolume)
    }

    /// Whether a row is effectively at unity volume and unmuted.
    public static func isUnity(volume: Double, isMuted: Bool, tolerance: Double = unityTolerance) -> Bool {
        guard !isMuted, volume.isFinite else { return false }
        let clamped = clampVolume(volume)
        return abs(clamped - maxVolume) <= tolerance
    }

    /// Converts a slider position (`0.0...1.0`) and mute flag into linear sample gain (`0.0...1.0`).
    /// Uses a quadratic curve (`level * level`) below unity for natural perceived loudness.
    public static func gain(forVolume volume: Double, isMuted: Bool = false) -> Float {
        guard !isMuted else { return 0.0 }
        guard volume.isFinite else { return 1.0 }
        let clamped = clampVolume(volume)
        if clamped <= 0.0 { return 0.0 }
        if clamped >= 1.0 - unityTolerance { return 1.0 }
        return Float(clamped * clamped)
    }

    /// Inverse of `gain(forVolume:)` for restoring slider position from a linear gain factor.
    public static func volume(forGain gain: Double) -> Double {
        guard gain.isFinite else { return maxVolume }
        let clamped = min(max(gain, minVolume), maxVolume)
        return clamped < maxVolume ? clamped.squareRoot() : maxVolume
    }

    /// Resolves the active explicit output device UID against currently connected output devices.
    /// When `selectedUID` is `nil` (System Default) or not currently connected, returns `nil` so audio
    /// routes to the current system default output instead of going permanently silent.
    public static func effectiveDeviceUID(selectedUID: String?, availableUIDs: [String]) -> String? {
        guard let selectedUID, !selectedUID.isEmpty else { return nil }
        return availableUIDs.contains(selectedUID) ? selectedUID : nil
    }

    /// True when the user picked a specific output device that is currently unplugged/unavailable.
    public static func isSelectedOutputUnavailable(selectedUID: String?, availableUIDs: [String]) -> Bool {
        guard let selectedUID, !selectedUID.isEmpty else { return false }
        return !availableUIDs.contains(selectedUID)
    }

    /// Decides whether an app row needs an active CoreAudio process tap + aggregate device engine.
    /// At unity volume (`1.0`), unmuted, and on System Default output (`effectiveDeviceUID == nil`),
    /// no tap is needed (unity bypass).
    public static func requiresEngine(
        volume: Double,
        isMuted: Bool,
        selectedUID: String?,
        availableUIDs: [String]
    ) -> Bool {
        let effectiveUID = effectiveDeviceUID(selectedUID: selectedUID, availableUIDs: availableUIDs)
        return isMuted || !isUnity(volume: volume, isMuted: false) || effectiveUID != nil
    }

    /// Walks the BSD parent process chain up to `maxDepth` so browser/WebKit audio helper processes
    /// roll up into the owning `.app` bundle (such as Brave or Safari).
    public static func owningRegularAppPID(
        responsiblePID: Int32,
        maxDepth: Int = maxParentSearchDepth,
        isRegularApp: (Int32) -> Bool,
        parentPID: (Int32) -> Int32
    ) -> Int32? {
        guard responsiblePID > 0 else { return nil }
        if isRegularApp(responsiblePID) { return responsiblePID }
        var current = responsiblePID
        guard maxDepth > 0 else { return nil }
        for _ in 0..<maxDepth {
            current = parentPID(current)
            guard current > 1 else { return nil }
            if isRegularApp(current) { return current }
        }
        return nil
    }

    /// Determines whether a process/bundle must be excluded from CoreAudio process tapping.
    /// - Always excludes Gliese itself (`com.rymaxw.gliese`) to prevent feedback/duplicate rendering and
    ///   Now Playing self-detection.
    /// - Excludes call apps while they are actively capturing microphone input so macOS hardware AEC continues to work.
    public static func shouldExcludeProcess(
        bundleIdentifier: String?,
        isCapturingMicrophoneInput: Bool = false,
        ownBundleIdentifier: String = glieseBundleIdentifier
    ) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }
        if bundleIdentifier == ownBundleIdentifier { return true }
        if isCapturingMicrophoneInput && echoCancelledCallBundleIdentifiers.contains(bundleIdentifier) {
            return true
        }
        return false
    }

    /// Evaluates whether a running tap engine's IOProc is healthy, still within startup grace, or stalled.
    public enum EngineRenderVerdict: Equatable, Sendable {
        case waiting
        case healthy
        case stalled
    }

    public static func engineRenderVerdict(
        renderedFrames: UInt64,
        elapsedSinceStart: TimeInterval,
        startupGrace: TimeInterval = renderStartupGraceSeconds
    ) -> EngineRenderVerdict {
        if renderedFrames > 0 { return .healthy }
        if elapsedSinceStart < startupGrace { return .waiting }
        return .stalled
    }

    /// How long to keep an engine alive when its app row temporarily disappears from the active process list.
    /// Track transitions in browsers/players briefly stop and restart audio streams; holding the engine for
    /// `0.5s` avoids audible clicks, whereas an explicit reset or unavailable output device tears down immediately.
    public static func engineTeardownDelay(
        stillListedInApps: Bool,
        outputDeviceStillAvailable: Bool
    ) -> TimeInterval? {
        if stillListedInApps { return nil }
        return outputDeviceStillAvailable ? idleProcessTeardownDelaySeconds : 0.0
    }
}

/// Tracks in-flight asynchronous engine builds per app row so a stale build never installs a duplicate tap.
public struct AudioEngineBuildTracker: Equatable, Sendable {
    private var nextToken: UInt64 = 0
    private var activeTokensByRow: [String: UInt64] = [:]

    public init() {}

    public mutating func beginBuild(for rowID: String) -> UInt64 {
        nextToken &+= 1
        activeTokensByRow[rowID] = nextToken
        return nextToken
    }

    public func isCurrentBuild(_ token: UInt64, for rowID: String) -> Bool {
        activeTokensByRow[rowID] == token
    }

    public mutating func cancelBuild(for rowID: String) {
        activeTokensByRow.removeValue(forKey: rowID)
    }

    public mutating func cancelAll() {
        activeTokensByRow.removeAll()
    }
}

/// Bounded retry tracker for CoreAudio tap/aggregate engines that invalidate or fail to render after startup.
public struct AudioEngineStallRecovery: Equatable, Sendable {
    public static let maxAttempts = 3
    private var attemptsByRow: [String: Int] = [:]
    private var pendingRows: Set<String> = []

    public init() {}

    /// Records a failure and returns `true` if a retry should be scheduled within the retry budget.
    public mutating func scheduleRetryIfAllowed(for rowID: String) -> Bool {
        guard !pendingRows.contains(rowID) else { return false }
        let nextAttempt = (attemptsByRow[rowID] ?? 0) + 1
        guard nextAttempt <= Self.maxAttempts else { return false }
        attemptsByRow[rowID] = nextAttempt
        pendingRows.insert(rowID)
        return true
    }

    public mutating func retryDidBegin(for rowID: String) {
        pendingRows.remove(rowID)
    }

    public mutating func markHealthy(for rowID: String) {
        attemptsByRow.removeValue(forKey: rowID)
        pendingRows.remove(rowID)
    }

    public mutating func reset(for rowID: String) {
        attemptsByRow.removeValue(forKey: rowID)
        pendingRows.remove(rowID)
    }

    public func attempts(for rowID: String) -> Int {
        attemptsByRow[rowID] ?? 0
    }
}
