import AppKit
import ApplicationServices
import Combine
import Defaults
import Foundation
import GlieseCore

@MainActor
final class GlieseMultiSourceMediaManager: ObservableObject {
    static let shared = GlieseMultiSourceMediaManager()

    struct SourceDescriptor: Identifiable, Equatable {
        let id: SourceID
        var displayName: String
        var bundleIdentifier: String
        var pid: Int32
        var isRunning: Bool
        var isPlaying: Bool
        var title: String
        var artist: String
        var album: String
        var duration: Double
        var elapsedTime: Double
        var playbackRate: Double
        var timestampDate: Date
        var artwork: Data?
        var revision: UUID
    }

    @Published private(set) var sources: [SourceProvider: SourceDescriptor] = [:]
    @Published private(set) var selectionSnapshot: SourceSelectionSnapshot
    @Published private(set) var mode: SourceMode = .auto
    @Published private(set) var systemNowPlayingPID: Int32? = nil
    @Published var lastControlStatusMessage: String? = nil

    private var sourceCoordinator = SourceCoordinator()
    private var pollTask: Task<Void, Never>?
    private var spotifyObserver: NSObjectProtocol?
    private var systemNowPlayingBundleID: String? = nil
    private var systemNowPlayingIsPlaying: Bool = false

    private init() {
        self.selectionSnapshot = sourceCoordinator.snapshot()
        setupObservers()
        refreshRunningSources()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        if let spotifyObserver {
            DistributedNotificationCenter.default().removeObserver(spotifyObserver)
            self.spotifyObserver = nil
        }
    }

    var activeProviders: [SourceProvider] {
        SourceProvider.allCases.filter { provider in
            guard let desc = sources[provider] else { return false }
            return desc.isRunning || !desc.title.isEmpty
        }
    }

    var selectedProvider: SourceProvider? {
        selectionSnapshot.selected?.provider
    }

    var selectedDescriptor: SourceDescriptor? {
        guard let provider = selectedProvider else { return nil }
        return sources[provider]
    }

    func setMode(_ newMode: SourceMode) {
        mode = newMode
        sourceCoordinator.setMode(newMode)
        selectionSnapshot = sourceCoordinator.snapshot()
        lastControlStatusMessage = nil
        applySelectedSourceToMusicManager()
    }

    func selectProvider(_ provider: SourceProvider?) {
        if let provider {
            setMode(.manual(SourceID(provider: provider)))
        } else {
            setMode(.auto)
        }
    }

    func ingestPlaybackState(_ state: PlaybackState, isSystemNowPlaying: Bool = true) {
        let normalizedBundle = MediaControlPolicy.normalizeBundleIdentifier(state.bundleIdentifier)
        let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: normalizedBundle).first
        let pid = runningApp?.processIdentifier ?? 0
        if isSystemNowPlaying {
            if pid > 0 {
                systemNowPlayingPID = pid
            }
            if !normalizedBundle.isEmpty {
                systemNowPlayingBundleID = normalizedBundle
                systemNowPlayingIsPlaying = state.isPlaying
            }
        }

        guard let provider = provider(for: normalizedBundle) else { return }

        let sourceID = SourceID(provider: provider)
        let previous = sources[provider]

        let cleanTitle = (state.title == "I'm Handsome" && state.artist == "Me") ? "" : state.title
        let cleanArtist = (state.title == "I'm Handsome" && state.artist == "Me") ? "" : state.artist
        let cleanAlbum = (state.album == "Self Love" && cleanTitle.isEmpty) ? "" : state.album

        let descriptor = SourceDescriptor(
            id: sourceID,
            displayName: displayName(for: provider),
            bundleIdentifier: normalizedBundle,
            pid: pid,
            isRunning: runningApp != nil || state.isPlaying || !cleanTitle.isEmpty,
            isPlaying: state.isPlaying,
            title: cleanTitle,
            artist: cleanArtist,
            album: cleanAlbum,
            duration: max(0, state.duration),
            elapsedTime: max(0, state.currentTime),
            playbackRate: state.playbackRate,
            timestampDate: state.lastUpdated == .distantPast ? Date() : state.lastUpdated,
            artwork: state.artwork ?? previous?.artwork,
            revision: UUID()
        )
        sources[provider] = descriptor

        if state.isPlaying {
            sourceCoordinator.handle(.startedPlaying(sourceID))
        } else if previous?.isPlaying == true && !state.isPlaying {
            sourceCoordinator.handle(.paused(sourceID))
        } else if !cleanTitle.isEmpty {
            sourceCoordinator.handle(.metadataUpdate(sourceID))
        }
        selectionSnapshot = sourceCoordinator.snapshot()
    }

    func refreshRunningSources() {
        for provider in SourceProvider.allCases {
            let bundleID = bundleIdentifier(for: provider)
            let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
            let isRunning = runningApp != nil
            let pid = runningApp?.processIdentifier ?? 0
            let sourceID = SourceID(provider: provider)

            if var existing = sources[provider] {
                let wasRunning = existing.isRunning
                existing.isRunning = isRunning
                if pid > 0 {
                    existing.pid = pid
                }
                if !isRunning {
                    existing.isPlaying = false
                }
                sources[provider] = existing
                if wasRunning && !isRunning {
                    sourceCoordinator.handle(.stopped(sourceID))
                }
            } else if isRunning {
                sources[provider] = SourceDescriptor(
                    id: sourceID,
                    displayName: displayName(for: provider),
                    bundleIdentifier: bundleID,
                    pid: pid,
                    isRunning: true,
                    isPlaying: false,
                    title: "",
                    artist: "",
                    album: "",
                    duration: 0,
                    elapsedTime: 0,
                    playbackRate: 0,
                    timestampDate: Date(),
                    artwork: nil,
                    revision: UUID()
                )
            }
        }
        selectionSnapshot = sourceCoordinator.snapshot()

        if NSRunningApplication.runningApplications(withBundleIdentifier: MediaControlPolicy.spotifyBundleID).first != nil {
            Task {
                await pollSpotifyIfAuthorized()
            }
        }
    }

    func executeCommand(_ command: MediaControlPolicy.Command) async -> Bool {
        lastControlStatusMessage = nil
        refreshRunningSources()

        let targetProvider = selectedProvider
            ?? activeProviders.first(where: { sources[$0]?.isPlaying == true })
            ?? activeProviders.first

        guard let provider = targetProvider,
              let descriptor = sources[provider],
              descriptor.pid > 0 else {
            return false
        }

        let targetContext = MediaControlPolicy.TargetContext(
            pid: descriptor.pid,
            bundleIdentifier: descriptor.bundleIdentifier,
            revision: descriptor.revision,
            isPlaying: descriptor.isPlaying
        )

        let hasAutomation = checkAutomationPermission(bundleIdentifier: descriptor.bundleIdentifier)
        let automationAccess: MediaControlPolicy.AutomationAccessState = hasAutomation ? .granted : .requiresConsent
        let decision = MediaControlPolicy.resolveDispatchRoute(
            command: command,
            requested: targetContext,
            currentSnapshot: targetContext,
            isProcessRunningWithSameBundle: true,
            systemNowPlayingPID: systemNowPlayingPID,
            automationAccess: automationAccess
        )

        switch decision {
        case .mediaRemotePlayerPath:
            return false // Let MusicManager's active NowPlayingController handle system Now Playing directly
        case .appleEventPlayer:
            let ok = await executeSpotifyAppleEvent(command: command)
            if !ok {
                lastControlStatusMessage = "Spotify automation unavailable. Check Automation permission in System Settings."
            }
            return true
        case .browserTabJavaScript:
            let ok = await executeBrowserYTMJavaScript(command: command, bundleID: descriptor.bundleIdentifier)
            if !ok {
                let browserName = descriptor.displayName
                lastControlStatusMessage = "Enable 'Allow JavaScript from Apple Events' in \(browserName) to control background YouTube Music tabs."
            }
            return true
        case .rejected(let reason):
            switch reason {
            case .nonCurrentPlayerRequiresAutomationConsent(let bundleID):
                lastControlStatusMessage = "Automation permission required for \(bundleID)."
            case .nonCurrentPlayerAutomationDenied(let bundleID):
                lastControlStatusMessage = "Automation permission denied for \(bundleID)."
            default:
                lastControlStatusMessage = "Cannot control \(descriptor.displayName) (\(reason))."
            }
            return true
        }
    }

    // MARK: - Private Helpers

    private func setupObservers() {
        spotifyObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let userInfo = notification.userInfo
            Task { @MainActor in
                self.handleSpotifyDistributedNotification(userInfo: userInfo)
            }
        }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self?.refreshRunningSources()
                }
            }
        }
    }

    private func handleSpotifyDistributedNotification(userInfo: [AnyHashable: Any]?) {
        guard let userInfo else { return }
        let stateStr = (userInfo["Player State"] as? String) ?? ""
        if stateStr == "Stopped" {
            sourceCoordinator.handle(.stopped(SourceID(provider: .spotify)))
            selectionSnapshot = sourceCoordinator.snapshot()
            return
        }

        let isPlaying = (stateStr == "Playing")
        let title = (userInfo["Name"] as? String) ?? ""
        let artist = (userInfo["Artist"] as? String) ?? ""
        let album = (userInfo["Album"] as? String) ?? ""
        let durationRaw = (userInfo["Duration"] as? Double) ?? 0
        let durationSeconds = durationRaw > 1000 ? durationRaw / 1000.0 : durationRaw
        let positionSeconds = (userInfo["Playback Position"] as? Double) ?? 0

        var state = PlaybackState(bundleIdentifier: MediaControlPolicy.spotifyBundleID)
        state.isPlaying = isPlaying
        state.title = title
        state.artist = artist
        state.album = album
        state.duration = durationSeconds
        state.currentTime = positionSeconds
        state.playbackRate = isPlaying ? 1.0 : 0.0
        state.lastUpdated = Date()

        let spotifyPID = NSRunningApplication.runningApplications(
            withBundleIdentifier: MediaControlPolicy.spotifyBundleID
        ).first?.processIdentifier

        let isSystem = (spotifyPID != nil && spotifyPID == systemNowPlayingPID) || systemNowPlayingPID == nil
        ingestPlaybackState(state, isSystemNowPlaying: isSystem)
        if shouldPushSpotifyToMusicManager(title: title, artist: artist, isPlaying: isPlaying, isSystem: isSystem, isPoll: false) {
            applySelectedSourceToMusicManager()
        }
    }

    private func applySelectedSourceToMusicManager() {
        guard let desc = selectedDescriptor, !desc.title.isEmpty else { return }
        var state = PlaybackState(bundleIdentifier: desc.bundleIdentifier)
        state.isPlaying = desc.isPlaying
        state.title = desc.title
        state.artist = desc.artist
        state.album = desc.album
        state.duration = desc.duration
        state.currentTime = desc.elapsedTime
        state.playbackRate = desc.playbackRate
        state.lastUpdated = desc.timestampDate
        state.artwork = desc.artwork
        MusicManager.shared.applyExternalSourceSnapshot(state)
    }

    private func pollSpotifyIfAuthorized() async {
        guard checkAutomationPermission(bundleIdentifier: MediaControlPolicy.spotifyBundleID) else { return }
        let script = """
        tell application id "com.spotify.client"
            if it is running then
                set pState to (player state as string)
                if pState is "playing" or pState is "paused" then
                    set tName to name of current track
                    set tArtist to artist of current track
                    set tAlbum to album of current track
                    set tDur to duration of current track
                    set tPos to player position
                    return pState & "|||" & tName & "|||" & tArtist & "|||" & tAlbum & "|||" & (tDur as string) & "|||" & (tPos as string)
                end if
            end if
        end tell
        return ""
        """
        guard let descriptor = try? await AppleScriptHelper.execute(script),
              let raw = descriptor.stringValue,
              !raw.isEmpty else { return }

        let parts = raw.components(separatedBy: "|||")
        guard parts.count >= 6 else { return }
        let isPlaying = parts[0].lowercased().contains("playing")
        let title = parts[1]
        let artist = parts[2]
        let album = parts[3]
        let durMs = Double(parts[4].replacingOccurrences(of: ",", with: ".")) ?? 0
        let posSec = Double(parts[5].replacingOccurrences(of: ",", with: ".")) ?? 0

        var state = PlaybackState(bundleIdentifier: MediaControlPolicy.spotifyBundleID)
        state.isPlaying = isPlaying
        state.title = title
        state.artist = artist
        state.album = album
        state.duration = durMs > 1000 ? durMs / 1000.0 : durMs
        state.currentTime = posSec
        state.playbackRate = isPlaying ? 1.0 : 0.0
        state.lastUpdated = Date()

        let spotifyPID = NSRunningApplication.runningApplications(
            withBundleIdentifier: MediaControlPolicy.spotifyBundleID
        ).first?.processIdentifier
        let isSystem = (spotifyPID != nil && spotifyPID == systemNowPlayingPID)
        ingestPlaybackState(state, isSystemNowPlaying: isSystem)
        if shouldPushSpotifyToMusicManager(title: title, artist: artist, isPlaying: isPlaying, isSystem: isSystem, isPoll: true) {
            applySelectedSourceToMusicManager()
        }
    }

    private func shouldPushSpotifyToMusicManager(
        title: String,
        artist: String,
        isPlaying: Bool,
        isSystem: Bool,
        isPoll: Bool
    ) -> Bool {
        if case .manual(let target) = mode {
            return target.provider == .spotify
        }
        guard selectedProvider == .spotify else { return false }

        // Never let background Spotify polling overwrite another actively playing source
        // (e.g., Brave/Safari YouTube Music, Chrome, Arc, Pear Desktop, Apple Music).
        if systemNowPlayingIsPlaying,
           let activeBundle = systemNowPlayingBundleID,
           activeBundle != MediaControlPolicy.spotifyBundleID {
            return false
        }

        // When NowPlayingController is already streaming Spotify directly, skip redundant 2.5s AppleScript
        // re-pushes that would race MediaRemote's microsecond clock and duration precision.
        if isPoll && isSystem
            && !MusicManager.shared.isNowPlayingDeprecated
            && Defaults[.mediaController] == .nowPlaying
            && MusicManager.shared.bundleIdentifier == MediaControlPolicy.spotifyBundleID
            && MusicManager.shared.songTitle == title
            && MusicManager.shared.artistName == artist
            && MusicManager.shared.isPlaying == isPlaying {
            return false
        }

        return true
    }

    private func checkAutomationPermission(bundleIdentifier: String) -> Bool {
        guard let data = bundleIdentifier.data(using: .utf8) else { return false }
        let targetDesc = data.withUnsafeBytes { rawBuffer -> AEAddressDesc in
            var desc = AEAddressDesc()
            if let base = rawBuffer.baseAddress {
                AECreateDesc(typeApplicationBundleID, base, rawBuffer.count, &desc)
            }
            return desc
        }
        defer {
            var mutableDesc = targetDesc
            AEDisposeDesc(&mutableDesc)
        }
        var mutableTarget = targetDesc
        let status = AEDeterminePermissionToAutomateTarget(
            &mutableTarget,
            typeWildCard,
            typeWildCard,
            false
        )
        return status == noErr
    }

    private func executeSpotifyAppleEvent(command: MediaControlPolicy.Command) async -> Bool {
        let action: String
        switch command {
        case .play:
            action = "play"
        case .pause:
            action = "pause"
        case .togglePlayPause:
            action = "playpause"
        case .nextTrack:
            action = "next track"
        case .previousTrack:
            action = "previous track"
        case .seek(let seconds):
            action = String(format: "set player position to %.2f", seconds)
        }
        let script = """
        tell application id "com.spotify.client"
            if it is running then
                \(action)
                return "OK"
            end if
        end tell
        return "ERR"
        """
        if let result = try? await AppleScriptHelper.execute(script),
           result.stringValue == "OK" {
            await pollSpotifyIfAuthorized()
            return true
        }
        return false
    }

    private func executeBrowserYTMJavaScript(command: MediaControlPolicy.Command, bundleID: String) async -> Bool {
        let jsSnippet: String
        switch command {
        case .play:
            jsSnippet = "(function(){ const v = document.querySelector('video'); if (v) { v.play(); return 'OK'; } return 'NO_VIDEO'; })()"
        case .pause:
            jsSnippet = "(function(){ const v = document.querySelector('video'); if (v) { v.pause(); return 'OK'; } return 'NO_VIDEO'; })()"
        case .togglePlayPause:
            jsSnippet = "(function(){ const v = document.querySelector('video'); if (v) { if (v.paused) v.play(); else v.pause(); return 'OK'; } return 'NO_VIDEO'; })()"
        case .nextTrack:
            jsSnippet = "(function(){ const b = document.querySelector('.next-button, tp-yt-paper-icon-button.next-button'); if (b) { b.click(); return 'OK'; } return 'NO_BTN'; })()"
        case .previousTrack:
            jsSnippet = "(function(){ const b = document.querySelector('.previous-button, tp-yt-paper-icon-button.previous-button'); if (b) { b.click(); return 'OK'; } return 'NO_BTN'; })()"
        case .seek(let seconds):
            jsSnippet = String(format: "(function(){ const v = document.querySelector('video'); if (v) { v.currentTime = %.2f; return 'OK'; } return 'NO_VIDEO'; })()", seconds)
        }

        let script: String
        if bundleID == MediaControlPolicy.braveBundleID {
            script = """
            tell application id "com.brave.Browser"
                repeat with w in windows
                    repeat with t in tabs of w
                        if URL of t starts with "https://music.youtube.com" then
                            return execute t javascript "\(jsSnippet.replacingOccurrences(of: "\"", with: "\\\""))"
                        end if
                    end repeat
                end repeat
            end tell
            return "NOT_FOUND"
            """
        } else if bundleID == MediaControlPolicy.safariBundleID {
            script = """
            tell application id "com.apple.Safari"
                repeat with w in windows
                    repeat with t in tabs of w
                        if URL of t starts with "https://music.youtube.com" then
                            return do JavaScript "\(jsSnippet.replacingOccurrences(of: "\"", with: "\\\""))" in t
                        end if
                    end repeat
                end repeat
            end tell
            return "NOT_FOUND"
            """
        } else {
            return false
        }

        if let res = try? await AppleScriptHelper.execute(script),
           res.stringValue == "OK" {
            return true
        }
        return false
    }

    private func provider(for bundleID: String) -> SourceProvider? {
        switch bundleID {
        case MediaControlPolicy.spotifyBundleID:
            return .spotify
        case MediaControlPolicy.braveBundleID:
            return .brave
        case MediaControlPolicy.safariBundleID:
            return .safari
        default:
            return nil
        }
    }

    private func bundleIdentifier(for provider: SourceProvider) -> String {
        switch provider {
        case .spotify:
            return MediaControlPolicy.spotifyBundleID
        case .brave:
            return MediaControlPolicy.braveBundleID
        case .safari:
            return MediaControlPolicy.safariBundleID
        }
    }

    private func displayName(for provider: SourceProvider) -> String {
        switch provider {
        case .spotify:
            return "Spotify"
        case .brave:
            return "Brave (YTM)"
        case .safari:
            return "Safari (YTM)"
        }
    }
}
