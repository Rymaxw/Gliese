import Foundation
import Testing
@testable import GlieseCore

@Suite("AudioMixerPolicy & Engine State Machine Tests")
struct AudioMixerPolicyTests {

    @Test("Volume clamps strictly to 0.0...1.0 without boost")
    func volumeClampingNoBoost() {
        #expect(AudioMixerPolicy.clampVolume(-0.5) == 0.0)
        #expect(AudioMixerPolicy.clampVolume(0.0) == 0.0)
        #expect(AudioMixerPolicy.clampVolume(0.5) == 0.5)
        #expect(AudioMixerPolicy.clampVolume(1.0) == 1.0)
        #expect(AudioMixerPolicy.clampVolume(2.0) == 1.0)
        #expect(AudioMixerPolicy.clampVolume(.nan) == 1.0)
        #expect(AudioMixerPolicy.clampVolume(.infinity) == 1.0)
    }

    @Test("Quadratic loudness gain curve and inverse volume mapping")
    func gainCurveAndInverse() {
        #expect(AudioMixerPolicy.gain(forVolume: 0.0) == 0.0)
        #expect(AudioMixerPolicy.gain(forVolume: 0.8, isMuted: true) == 0.0)
        #expect(AudioMixerPolicy.gain(forVolume: 0.5) == 0.25)
        #expect(AudioMixerPolicy.gain(forVolume: 1.0) == 1.0)
        #expect(AudioMixerPolicy.gain(forVolume: 1.5) == 1.0)

        let roundTrip = AudioMixerPolicy.volume(forGain: Double(AudioMixerPolicy.gain(forVolume: 0.5)))
        #expect(abs(roundTrip - 0.5) < 0.0001)
        #expect(AudioMixerPolicy.volume(forGain: 1.5) == 1.0)
    }

    @Test("Unity bypass requires no engine when unmuted at 100% on system default output")
    func unityBypassPolicy() {
        let devices = ["BuiltInSpeakerDevice", "USB-DAC-UID"]

        // 100% volume, unmuted, system default output (selectedUID == nil) -> bypass
        #expect(!AudioMixerPolicy.requiresEngine(
            volume: 1.0,
            isMuted: false,
            selectedUID: nil,
            availableUIDs: devices
        ))

        // Lowered volume -> requires engine
        #expect(AudioMixerPolicy.requiresEngine(
            volume: 0.6,
            isMuted: false,
            selectedUID: nil,
            availableUIDs: devices
        ))

        // Muted at 100% -> requires engine
        #expect(AudioMixerPolicy.requiresEngine(
            volume: 1.0,
            isMuted: true,
            selectedUID: nil,
            availableUIDs: devices
        ))

        // Explicit route to connected device at 100% -> requires engine
        #expect(AudioMixerPolicy.requiresEngine(
            volume: 1.0,
            isMuted: false,
            selectedUID: "USB-DAC-UID",
            availableUIDs: devices
        ))

        // Explicit route to disconnected device at 100% -> falls back to system default -> bypass
        #expect(!AudioMixerPolicy.requiresEngine(
            volume: 1.0,
            isMuted: false,
            selectedUID: "Unplugged-TWS-UID",
            availableUIDs: devices
        ))
    }

    @Test("Disconnected output device falls back cleanly to system default and marks unavailable")
    func routeFallbackOnDisconnect() {
        let connected = ["BuiltInSpeakerDevice"]
        let selected = "Bluetooth-TWS-UID"

        #expect(AudioMixerPolicy.effectiveDeviceUID(selectedUID: selected, availableUIDs: connected) == nil)
        #expect(AudioMixerPolicy.isSelectedOutputUnavailable(selectedUID: selected, availableUIDs: connected))

        let reconnected = ["BuiltInSpeakerDevice", "Bluetooth-TWS-UID"]
        #expect(AudioMixerPolicy.effectiveDeviceUID(selectedUID: selected, availableUIDs: reconnected) == selected)
        #expect(!AudioMixerPolicy.isSelectedOutputUnavailable(selectedUID: selected, availableUIDs: reconnected))
    }

    @Test("BSD parent process chain rolls browser audio helpers up to owning regular app")
    func browserHelperRollup() {
        // 400 (Brave Audio Helper) -> 300 (Brave GPU Helper) -> 200 (Brave Browser regular app) -> 1 (launchd)
        let parents: [Int32: Int32] = [400: 300, 300: 200, 200: 1]
        let regularApps: Set<Int32> = [200]

        let resolved = AudioMixerPolicy.owningRegularAppPID(
            responsiblePID: 400,
            isRegularApp: { regularApps.contains($0) },
            parentPID: { parents[$0] ?? 0 }
        )
        #expect(resolved == 200)

        // Daemon not owned by any regular app returns nil
        let daemon = AudioMixerPolicy.owningRegularAppPID(
            responsiblePID: 500,
            isRegularApp: { regularApps.contains($0) },
            parentPID: { _ in 1 }
        )
        #expect(daemon == nil)
    }

    @Test("Process exclusion prevents Gliese self-tapping and protects active call AEC")
    func processExclusions() {
        #expect(AudioMixerPolicy.shouldExcludeProcess(bundleIdentifier: "com.rymaxw.gliese"))
        #expect(!AudioMixerPolicy.shouldExcludeProcess(bundleIdentifier: "com.spotify.client"))
        #expect(!AudioMixerPolicy.shouldExcludeProcess(bundleIdentifier: "us.zoom.xos", isCapturingMicrophoneInput: false))
        #expect(AudioMixerPolicy.shouldExcludeProcess(bundleIdentifier: "us.zoom.xos", isCapturingMicrophoneInput: true))
    }

    @Test("Engine build tracker fences superseded async builds to prevent duplicate taps")
    func buildTrackerFencing() {
        var tracker = AudioEngineBuildTracker()
        let first = tracker.beginBuild(for: "com.spotify.client")
        let second = tracker.beginBuild(for: "com.spotify.client")

        #expect(!tracker.isCurrentBuild(first, for: "com.spotify.client"))
        #expect(tracker.isCurrentBuild(second, for: "com.spotify.client"))

        tracker.cancelBuild(for: "com.spotify.client")
        #expect(!tracker.isCurrentBuild(second, for: "com.spotify.client"))
    }

    @Test("Engine render verdict and bounded stall recovery")
    func renderVerdictAndStallRecovery() {
        #expect(AudioMixerPolicy.engineRenderVerdict(renderedFrames: 0, elapsedSinceStart: 0.2) == .waiting)
        #expect(AudioMixerPolicy.engineRenderVerdict(renderedFrames: 512, elapsedSinceStart: 0.2) == .healthy)
        #expect(AudioMixerPolicy.engineRenderVerdict(renderedFrames: 0, elapsedSinceStart: 0.6) == .stalled)

        var recovery = AudioEngineStallRecovery()
        let row = "com.brave.Browser"
        for attempt in 1...AudioEngineStallRecovery.maxAttempts {
            let scheduled = recovery.scheduleRetryIfAllowed(for: row)
            #expect(scheduled)
            // Duplicate schedule while pending is ignored
            let duplicate = recovery.scheduleRetryIfAllowed(for: row)
            #expect(!duplicate)
            recovery.retryDidBegin(for: row)
            #expect(recovery.attempts(for: row) == attempt)
        }
        // Exhausted budget -> false
        let exhausted = recovery.scheduleRetryIfAllowed(for: row)
        #expect(!exhausted)

        // Healthy render clears counter
        recovery.markHealthy(for: row)
        #expect(recovery.attempts(for: row) == 0)
        let afterHealthy = recovery.scheduleRetryIfAllowed(for: row)
        #expect(afterHealthy)
    }

    @Test("Engine teardown delay holds briefly during track transitions and drops immediately on unplug")
    func teardownDelayPolicy() {
        #expect(AudioMixerPolicy.engineTeardownDelay(stillListedInApps: true, outputDeviceStillAvailable: true) == nil)
        #expect(AudioMixerPolicy.engineTeardownDelay(stillListedInApps: false, outputDeviceStillAvailable: true) == 0.5)
        #expect(AudioMixerPolicy.engineTeardownDelay(stillListedInApps: false, outputDeviceStillAvailable: false) == 0.0)
    }
}
