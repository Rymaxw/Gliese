//
//  NowPlayingController.swift
//  Gliese
//
//  Gliese Team
//

import AppKit
import Combine
import Foundation

final class NowPlayingController: ObservableObject, MediaControllerProtocol {
    func updatePlaybackInfo() async {
        await fetchFavoriteStateIfSupported()
    }

    // MARK: - Properties
    @Published private(set) var playbackState: PlaybackState = .init(
        bundleIdentifier: "com.spotify.client"
    )

    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    var supportsVolumeControl: Bool {
        let bundleID = playbackState.bundleIdentifier
        return bundleID == "com.spotify.client"
    }

    var supportsFavorite: Bool {
        return false
    }

    func setFavorite(_ favorite: Bool) async {
        let bundleID = playbackState.bundleIdentifier
        
        if bundleID == "com.apple.Music" {
            let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
            if !runningApps.isEmpty {
                let script = """
                tell application "Music"
                    try
                        set favorited of current track to \(favorite ? "true" : "false")
                    end try
                end tell
                """
                try? await AppleScriptHelper.executeVoid(script)
            }
        }
        
        // Update the favorite state locally and fetch updated info
        try? await Task.sleep(for: .milliseconds(150))
        await updatePlaybackInfo()
    }

    private var lastMusicItem:
        (title: String, artist: String, album: String, duration: TimeInterval, artworkData: Data?)?

    // MARK: - Media Remote Functions
    private let mediaRemoteBundle: CFBundle
    private let MRMediaRemoteSendCommandFunction: @convention(c) (Int, AnyObject?) -> Void
    private let MRMediaRemoteSetElapsedTimeFunction: @convention(c) (Double) -> Void
    private let MRMediaRemoteSetShuffleModeFunction: @convention(c) (Int) -> Void
    private let MRMediaRemoteSetRepeatModeFunction: @convention(c) (Int) -> Void

    private var process: Process?
    private var pipeHandler: JSONLinesPipeHandler?
    private var streamTask: Task<Void, Never>?

    // MARK: - Initialization
    init?() {
        guard
            let bundle = CFBundleCreate(
                kCFAllocatorDefault,
                NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")),
            let MRMediaRemoteSendCommandPointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSendCommand" as CFString),
            let MRMediaRemoteSetElapsedTimePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetElapsedTime" as CFString),
            let MRMediaRemoteSetShuffleModePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetShuffleMode" as CFString),
            let MRMediaRemoteSetRepeatModePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetRepeatMode" as CFString)
            
        else { return nil }

        mediaRemoteBundle = bundle
        MRMediaRemoteSendCommandFunction = unsafeBitCast(
            MRMediaRemoteSendCommandPointer, to: (@convention(c) (Int, AnyObject?) -> Void).self)
        MRMediaRemoteSetElapsedTimeFunction = unsafeBitCast(
            MRMediaRemoteSetElapsedTimePointer, to: (@convention(c) (Double) -> Void).self)
        MRMediaRemoteSetShuffleModeFunction = unsafeBitCast(
            MRMediaRemoteSetShuffleModePointer, to: (@convention(c) (Int) -> Void).self)
        MRMediaRemoteSetRepeatModeFunction = unsafeBitCast(
            MRMediaRemoteSetRepeatModePointer, to: (@convention(c) (Int) -> Void).self)

        Task { await setupNowPlayingObserver() }
    }

    deinit {
        stop()
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil

        if let pipeHandler = self.pipeHandler {
            Task { await pipeHandler.close() }
        }

        if let process = self.process {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        self.process = nil
        self.pipeHandler = nil
    }

    // MARK: - Protocol Implementation
    func play() async {
        MRMediaRemoteSendCommandFunction(0, nil)
    }

    func pause() async {
        MRMediaRemoteSendCommandFunction(1, nil)
    }

    func togglePlay() async {
        MRMediaRemoteSendCommandFunction(2, nil)
    }

    func nextTrack() async {
        MRMediaRemoteSendCommandFunction(4, nil)
    }

    func previousTrack() async {
        MRMediaRemoteSendCommandFunction(5, nil)
    }

    func seek(to time: Double) async {
        MRMediaRemoteSetElapsedTimeFunction(time)
    }

    func isActive() -> Bool {
        return true
    }
    
    func toggleShuffle() async {
        // MRMediaRemoteSendCommandFunction(6, nil)
        MRMediaRemoteSetShuffleModeFunction(playbackState.isShuffled ? 1 : 3)
        playbackState.isShuffled.toggle()
    }
    
    func toggleRepeat() async {
        // MRMediaRemoteSendCommandFunction(7, nil)
        let newRepeatMode = (playbackState.repeatMode == .off) ? 3 : (playbackState.repeatMode.rawValue - 1)
        playbackState.repeatMode = RepeatMode(rawValue: newRepeatMode) ?? .off
        MRMediaRemoteSetRepeatModeFunction(newRepeatMode)
    }
    
    func setVolume(_ level: Double) async {
        // MediaRemote framework doesn't provide direct volume control for the active audio session
        // As a workaround, try to control the currently active music app directly
        let clampedLevel = max(0.0, min(1.0, level))
        let volumePercentage = Int(clampedLevel * 100)
        
        let bundleID = playbackState.bundleIdentifier
        if bundleID == "com.spotify.client" {
            let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client")
            if !runningApps.isEmpty {
                let script = "tell application \"Spotify\" to set sound volume to \(volumePercentage)"
                try? await AppleScriptHelper.executeVoid(script)
            }
        }
        
        playbackState.volume = clampedLevel
    }
    
    // MARK: - Setup Methods
    private func setupNowPlayingObserver() async {
        let process = Process()
        guard
            let scriptURL = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
            let frameworkPath = Bundle.main.privateFrameworksPath?.appending("/MediaRemoteAdapter.framework")
        else {
            assertionFailure("Could not find mediaremote-adapter.pl script or framework path")
            return
        }
        
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, frameworkPath, "stream", "--micros"]
        
        let pipeHandler = JSONLinesPipeHandler()
        process.standardOutput = await pipeHandler.getPipe()
        
        self.process = process
        self.pipeHandler = pipeHandler

        do {
            try process.run()
            streamTask = Task { [weak self, pipeHandler] in
                await pipeHandler.readJSONLines(as: NowPlayingUpdate.self) { [weak self] update in
                    await self?.handleAdapterUpdate(update)
                }
            }
        } catch {
            assertionFailure("Failed to launch mediaremote-adapter.pl: \(error)")
        }
    }

    // MARK: - Update Methods
    private func handleAdapterUpdate(_ update: NowPlayingUpdate) async {
        let now = Date()
        let prev = self.playbackState
        let payload = update.payload
        let diff = update.diff ?? false

        let resolvedDuration: Double? = payload.durationMicros.map { $0 / 1_000_000.0 } ?? payload.duration
        let resolvedElapsed: Double? = payload.elapsedTimeMicros.map { $0 / 1_000_000.0 } ?? payload.elapsedTime
        let resolvedTimestamp: Date? = {
            if let micros = payload.timestampEpochMicros {
                return Date(timeIntervalSince1970: micros / 1_000_000.0)
            }
            if let dateString = payload.timestamp {
                let fractional = ISO8601DateFormatter()
                fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let d = fractional.date(from: dateString) {
                    return d
                }
                return ISO8601DateFormatter().date(from: dateString)
            }
            return nil
        }()

        var newPlaybackState = PlaybackState(bundleIdentifier: prev.bundleIdentifier)

        newPlaybackState.title = payload.title ?? (diff ? prev.title : "")
        newPlaybackState.artist = payload.artist ?? (diff ? prev.artist : "")
        newPlaybackState.album = payload.album ?? (diff ? prev.album : "")
        newPlaybackState.duration = max(0, resolvedDuration ?? (diff ? prev.duration : 0))

        let trackMetadataChanged = diff && (
            (payload.title != nil && payload.title != prev.title) ||
            (payload.artist != nil && payload.artist != prev.artist)
        )

        let newIsPlaying = payload.playing ?? (diff ? prev.isPlaying : false)
        let newPlaybackRate: Double
        if let explicitRate = payload.playbackRate {
            // Respect explicit 0.0 (Chromium/Brave buffering/stalled) — do not advance elapsed time while buffering.
            newPlaybackRate = max(0.0, explicitRate)
        } else if diff {
            if payload.playing == true && prev.playbackRate <= 0 {
                // Resume-from-pause diff that omitted playbackRate: restore normal playback speed.
                newPlaybackRate = 1.0
            } else {
                newPlaybackRate = prev.playbackRate
            }
        } else {
            newPlaybackRate = newIsPlaying ? 1.0 : 0.0
        }
        newPlaybackState.isPlaying = newIsPlaying
        newPlaybackState.playbackRate = newPlaybackRate

        let resumedFromBufferOrPause = (newIsPlaying && newPlaybackRate > 0) && (!prev.isPlaying || prev.playbackRate <= 0)
        let hasValidPrevAnchor = prev.lastUpdated != .distantPast
        var advancedOnPause = false

        if let elapsedTime = resolvedElapsed {
            newPlaybackState.currentTime = max(0, elapsedTime)
        } else if trackMetadataChanged {
            // Never inherit the previous track's position when a diff switches tracks without an explicit elapsedTime.
            newPlaybackState.currentTime = 0
        } else if diff {
            if payload.playing == false && prev.isPlaying && prev.playbackRate > 0 && hasValidPrevAnchor {
                let timeSinceLastUpdate = max(0, now.timeIntervalSince(prev.lastUpdated))
                let computed = prev.currentTime + (prev.playbackRate * timeSinceLastUpdate)
                newPlaybackState.currentTime = newPlaybackState.duration > 0 ? min(computed, newPlaybackState.duration) : computed
                advancedOnPause = true
            } else {
                newPlaybackState.currentTime = prev.currentTime
            }
        } else {
            newPlaybackState.currentTime = 0
        }

        if let shuffleMode = payload.shuffleMode {
            newPlaybackState.isShuffled = shuffleMode != 1
        } else if !diff {
            newPlaybackState.isShuffled = false
        } else {
            newPlaybackState.isShuffled = prev.isShuffled
        }
        if let repeatModeValue = payload.repeatMode {
            newPlaybackState.repeatMode = RepeatMode(rawValue: repeatModeValue) ?? .off
        } else if !diff {
            newPlaybackState.repeatMode = .off
        } else {
            newPlaybackState.repeatMode = prev.repeatMode
        }

        if let artworkDataString = payload.artworkData {
            newPlaybackState.artwork = Data(
                base64Encoded: artworkDataString.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } else if !diff {
            newPlaybackState.artwork = nil
        }

        if trackMetadataChanged && resolvedElapsed == nil {
            // Track switched without explicit elapsedTime: anchor to `now` (ignore stale timestamps from previous track).
            if let ts = resolvedTimestamp, ts > prev.lastUpdated, abs(now.timeIntervalSince(ts)) < 1.0 {
                newPlaybackState.lastUpdated = ts
            } else {
                newPlaybackState.lastUpdated = now
            }
        } else if let ts = resolvedTimestamp {
            if (advancedOnPause || resumedFromBufferOrPause) && ts <= prev.lastUpdated {
                newPlaybackState.lastUpdated = now
            } else {
                newPlaybackState.lastUpdated = ts
            }
        } else if !diff || resolvedElapsed != nil || advancedOnPause || resumedFromBufferOrPause || !hasValidPrevAnchor {
            newPlaybackState.lastUpdated = now
        } else {
            newPlaybackState.lastUpdated = prev.lastUpdated
        }

        newPlaybackState.bundleIdentifier = (
            payload.parentApplicationBundleIdentifier ??
            payload.bundleIdentifier ??
            (diff ? prev.bundleIdentifier : "")
        )

        newPlaybackState.volume = payload.volume ?? (diff ? prev.volume : 0.5)

        self.playbackState = newPlaybackState

        // Fetch favorite state for supported apps asynchronously
        // await fetchFavoriteStateIfSupported()
    }
    
     private func fetchFavoriteStateIfSupported() async {
         let bundleID = playbackState.bundleIdentifier
        
         if bundleID == "com.apple.Music" {
             let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
             guard !runningApps.isEmpty else { return }
             
             let script = """
             tell application "Music"
                 try
                     return favorited of current track
                 on error
                     return false
                 end try
             end tell
             """
             if let result = try? await AppleScriptHelper.execute(script) {
                 var updated = self.playbackState
                 updated.isFavorite = result.booleanValue
                 self.playbackState = updated
             }
         }
     }
    
}

struct NowPlayingUpdate: Codable {
    let payload: NowPlayingPayload
    let diff: Bool?
}

struct NowPlayingPayload: Codable {
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let durationMicros: Double?
    let elapsedTime: Double?
    let elapsedTimeMicros: Double?
    let shuffleMode: Int?
    let repeatMode: Int?
    let artworkData: String?
    let timestamp: String?
    let timestampEpochMicros: Double?
    let playbackRate: Double?
    let playing: Bool?
    let parentApplicationBundleIdentifier: String?
    let bundleIdentifier: String?
    let volume: Double?
}

actor JSONLinesPipeHandler {
    private let pipe: Pipe
    private let fileHandle: FileHandle
    private var buffer = ""
    private var pendingContinuation: CheckedContinuation<Data, Error>?
    private var isClosed = false
    
    init() {
        self.pipe = Pipe()
        self.fileHandle = pipe.fileHandleForReading
    }
    
    func getPipe() -> Pipe {
        return pipe
    }
    
    func readJSONLines<T: Decodable>(as type: T.Type, onLine: @escaping (T) async -> Void) async {
        do {
            try await self.processLines(as: type) { decodedObject in
                await onLine(decodedObject)
            }
        } catch {
            print("Error processing JSON stream: \(error)")
        }
    }
    
    private func processLines<T: Decodable>(as type: T.Type, onLine: @escaping (T) async -> Void) async throws {
        while true {
            let data = try await readData()
            guard !data.isEmpty else { break }
            
            if let chunk = String(data: data, encoding: .utf8) {
                buffer.append(chunk)
                
                while let range = buffer.range(of: "\n") {
                    let line = String(buffer[..<range.lowerBound])
                    buffer = String(buffer[range.upperBound...])
                    
                    if !line.isEmpty {
                        await processJSONLine(line, as: type, onLine: onLine)
                    }
                }
            }
        }
    }
    
    private func processJSONLine<T: Decodable>(_ line: String, as type: T.Type, onLine: @escaping (T) async -> Void) async {
        guard let data = line.data(using: .utf8) else {
            return
        }
        do {
            let decodedObject = try JSONDecoder().decode(T.self, from: data)
            await onLine(decodedObject)
        } catch {
            // Ignore lines that can't be decoded
        }
    }
    
    private func readData() async throws -> Data {
        if isClosed { return Data() }
        return try await withCheckedThrowingContinuation { continuation in
            self.pendingContinuation = continuation
            fileHandle.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                handle.readabilityHandler = nil
                Task { await self?.completeRead(with: data) }
            }
        }
    }

    private func completeRead(with data: Data) {
        guard let cont = pendingContinuation else { return }
        pendingContinuation = nil
        cont.resume(returning: data)
    }

    func close() async {
        isClosed = true
        fileHandle.readabilityHandler = nil
        if let cont = pendingContinuation {
            pendingContinuation = nil
            cont.resume(returning: Data())
        }
        try? fileHandle.close()
        try? pipe.fileHandleForWriting.close()
    }
}
