import Foundation

/// Pure policy and validation rules for multi-source media control (T03 / T06).
///
/// Guarantees that a user action (Play, Pause, Next, Previous, Seek) is bound to an explicit
/// `(pid, bundleIdentifier, revision)` context and never falls back to an untargeted global
/// media key when another player owns the system Now Playing session.
public enum MediaControlPolicy {
    public static let spotifyBundleID = "com.spotify.client"
    public static let braveBundleID = "com.brave.Browser"
    public static let safariBundleID = "com.apple.Safari"
    public static let webKitGPUBundleID = "com.apple.WebKit.GPU"
    public static let webKitWebContentBundleID = "com.apple.WebKit.WebContent"

    public static let maxSeekSeconds: Double = 604_800 // 7 days

    /// Normalizes child WebKit/helper bundles back to their parent browser bundle identifier.
    public static func normalizeBundleIdentifier(_ bundleID: String?) -> String {
        guard let bundleID, !bundleID.isEmpty else { return "" }
        if bundleID == webKitGPUBundleID || bundleID == webKitWebContentBundleID {
            return safariBundleID
        }
        return bundleID
    }

    public enum Command: Equatable, Sendable {
        case play
        case pause
        case togglePlayPause
        case nextTrack
        case previousTrack
        case seek(seconds: Double)
    }

    public struct TargetContext: Equatable, Sendable {
        public let pid: Int32
        public let bundleIdentifier: String
        public let parentBundleIdentifier: String?
        public let revision: UUID
        public let itemIdentifier: String?
        public let isPlaying: Bool

        public init(
            pid: Int32,
            bundleIdentifier: String,
            parentBundleIdentifier: String? = nil,
            revision: UUID,
            itemIdentifier: String? = nil,
            isPlaying: Bool
        ) {
            self.pid = pid
            self.bundleIdentifier = bundleIdentifier
            self.parentBundleIdentifier = parentBundleIdentifier
            self.revision = revision
            self.itemIdentifier = itemIdentifier
            self.isPlaying = isPlaying
        }

        /// Canonical app bundle identifier (maps Safari WebKit helper PIDs back to `com.apple.Safari` for UI/Automation).
        public var canonicalApplicationBundleID: String {
            if let parent = parentBundleIdentifier, !parent.isEmpty {
                return parent
            }
            if bundleIdentifier == MediaControlPolicy.webKitGPUBundleID
                || bundleIdentifier == MediaControlPolicy.webKitWebContentBundleID {
                return MediaControlPolicy.safariBundleID
            }
            return bundleIdentifier
        }
    }

    public enum AutomationAccessState: Equatable, Sendable {
        case granted
        case requiresConsent
        case denied
        case unavailable
    }

    public enum DispatchRoute: Equatable, Sendable {
        /// Send via `MRMediaRemoteSendCommandToPlayer` targeting the specific `MRPlayerPath(pid, bundleIdentifier)`.
        /// Note: On macOS 27.2 (`26B123`), omit `kMRMediaRemoteOptionNowPlayingContentItemID` for non-system players
        /// (`Spotify`, `Brave`, `Safari`) because passing `itemIdentifier` returns `error = 7`.
        case mediaRemotePlayerPath(pid: Int32, bundleIdentifier: String, mrCommandID: Int32, seekPosition: Double?)
        /// Send via PID-targeted AppleEvents to a native scriptable player (such as `com.spotify.client`).
        case appleEventPlayer(pid: Int32, bundleIdentifier: String, command: Command)
        /// Send via tab-targeted AppleEvents (`execute ... javascript` / `do JavaScript`) to a YouTube Music tab
        /// in `com.brave.Browser` or `com.apple.Safari` when that browser is not the current `systemNowPlayingPID`.
        case browserTabJavaScript(bundleIdentifier: String, command: Command)
        /// Rejected before dispatch so the wrong app is never controlled.
        case rejected(Reason)
    }

    public enum Reason: Equatable, Sendable {
        case invalidPID
        case staleRevision
        case processTerminatedOrMismatched
        case invalidSeekPosition
        case nonCurrentPlayerRequiresAutomationConsent(bundleIdentifier: String)
        case nonCurrentPlayerAutomationDenied(bundleIdentifier: String)
        case unsupportedTransportForBackgroundSource(bundleIdentifier: String)
    }

    /// Resolves the MediaRemote command code (`MRMediaRemoteCommand`) for a high-level command.
    /// - `0`: Play (`kMRMediaRemoteCommandPlay`)
    /// - `1`: Pause (`kMRMediaRemoteCommandPause`)
    /// - `2`: TogglePlayPause (`kMRMediaRemoteCommandTogglePlayPause`)
    /// - `4`: NextTrack (`kMRMediaRemoteCommandNextTrack`)
    /// - `5`: PreviousTrack (`kMRMediaRemoteCommandPreviousTrack`)
    /// - `24`: ChangePlaybackPosition (`kMRMediaRemoteCommandChangePlaybackPosition`)
    public static func mediaRemoteCommandID(
        for command: Command,
        isPlaying: Bool,
        supportsPlay: Bool = true,
        supportsPause: Bool = true
    ) -> Int32 {
        switch command {
        case .play:
            return supportsPlay ? 0 : 2
        case .pause:
            return supportsPause ? 1 : 2
        case .togglePlayPause:
            if isPlaying && supportsPause { return 1 }
            if !isPlaying && supportsPlay { return 0 }
            return 2
        case .nextTrack:
            return 4
        case .previousTrack:
            return 5
        case .seek:
            return 24
        }
    }

    /// Determines the safe dispatch route for a command targeting `requested`.
    ///
    /// Rules:
    /// 1. `requested` must match `currentSnapshot` (`pid`, `bundleIdentifier`, and `revision`), and the process must still be alive.
    /// 2. Seek positions must be finite and within `0...604_800`.
    /// 3. If `requested.pid == systemNowPlayingPID` (or `directPlayerPathVerified` is true for that client),
    ///    `MRMediaRemoteSendCommandToPlayer` on the per-PID `MRPlayerPath` is used directly without needing Automation.
    /// 4. If `requested.pid != systemNowPlayingPID` and the target is a scriptable native player (`com.spotify.client`),
    ///    PID-targeted AppleEvents are used when `automationAccess == .granted`; otherwise `.requiresConsent` / `.denied` is surfaced.
    /// 5. Never falls back to an untargeted global command when another PID owns the system session.
    public static func resolveDispatchRoute(
        command: Command,
        requested: TargetContext,
        currentSnapshot: TargetContext?,
        isProcessRunningWithSameBundle: Bool,
        systemNowPlayingPID: Int32?,
        directPlayerPathVerifiedForBackground: Bool = false,
        supportsPlay: Bool = true,
        supportsPause: Bool = true,
        automationAccess: AutomationAccessState = .unavailable
    ) -> DispatchRoute {
        guard requested.pid > 0 else {
            return .rejected(.invalidPID)
        }
        guard isProcessRunningWithSameBundle else {
            return .rejected(.processTerminatedOrMismatched)
        }
        guard let currentSnapshot,
              currentSnapshot.pid == requested.pid,
              currentSnapshot.bundleIdentifier == requested.bundleIdentifier,
              currentSnapshot.revision == requested.revision else {
            return .rejected(.staleRevision)
        }

        var seekValue: Double?
        if case .seek(let seconds) = command {
            guard seconds.isFinite, (0.0...maxSeekSeconds).contains(seconds) else {
                return .rejected(.invalidSeekPosition)
            }
            seekValue = seconds
        }

        let isSystemOwner = (systemNowPlayingPID == requested.pid)
        if isSystemOwner || directPlayerPathVerifiedForBackground {
            let mrID = mediaRemoteCommandID(
                for: command,
                isPlaying: currentSnapshot.isPlaying,
                supportsPlay: supportsPlay,
                supportsPause: supportsPause
            )
            return .mediaRemotePlayerPath(
                pid: requested.pid,
                bundleIdentifier: requested.bundleIdentifier,
                mrCommandID: mrID,
                seekPosition: seekValue
            )
        }

        let appBundle = requested.canonicalApplicationBundleID
        if appBundle == spotifyBundleID {
            switch automationAccess {
            case .granted:
                return .appleEventPlayer(pid: requested.pid, bundleIdentifier: appBundle, command: command)
            case .requiresConsent:
                return .rejected(.nonCurrentPlayerRequiresAutomationConsent(bundleIdentifier: appBundle))
            case .denied:
                return .rejected(.nonCurrentPlayerAutomationDenied(bundleIdentifier: appBundle))
            case .unavailable:
                return .rejected(.unsupportedTransportForBackgroundSource(bundleIdentifier: appBundle))
            }
        }

        if appBundle == braveBundleID || appBundle == safariBundleID {
            switch automationAccess {
            case .granted:
                return .browserTabJavaScript(bundleIdentifier: appBundle, command: command)
            case .requiresConsent:
                return .rejected(.nonCurrentPlayerRequiresAutomationConsent(bundleIdentifier: appBundle))
            case .denied:
                return .rejected(.nonCurrentPlayerAutomationDenied(bundleIdentifier: appBundle))
            case .unavailable:
                return .rejected(.unsupportedTransportForBackgroundSource(bundleIdentifier: appBundle))
            }
        }

        return .rejected(.unsupportedTransportForBackgroundSource(bundleIdentifier: appBundle))
    }
}
