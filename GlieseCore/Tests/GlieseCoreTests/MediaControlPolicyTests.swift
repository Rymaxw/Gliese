import Foundation
import Testing
@testable import GlieseCore

@Suite("MediaControlPolicy & Source Command Isolation Tests")
struct MediaControlPolicyTests {

    @Test("System owner uses per-PID MRPlayerPath directly without Automation")
    func systemOwnerDirectMediaRemote() {
        let rev = UUID()
        let ctx = MediaControlPolicy.TargetContext(
            pid: 101,
            bundleIdentifier: MediaControlPolicy.braveBundleID,
            revision: rev,
            itemIdentifier: "ytm-track-1",
            isPlaying: true
        )

        let route = MediaControlPolicy.resolveDispatchRoute(
            command: .togglePlayPause,
            requested: ctx,
            currentSnapshot: ctx,
            isProcessRunningWithSameBundle: true,
            systemNowPlayingPID: 101
        )

        #expect(route == .mediaRemotePlayerPath(
            pid: 101,
            bundleIdentifier: MediaControlPolicy.braveBundleID,
            mrCommandID: 1, // Pause because isPlaying == true
            seekPosition: nil
        ))
    }

    @Test("Stale revision or terminated process is rejected before dispatch")
    func staleRevisionAndTerminatedProcessRejected() {
        let rev1 = UUID()
        let rev2 = UUID()
        let requested = MediaControlPolicy.TargetContext(
            pid: 202,
            bundleIdentifier: MediaControlPolicy.spotifyBundleID,
            revision: rev1,
            isPlaying: true
        )
        let newerSnapshot = MediaControlPolicy.TargetContext(
            pid: 202,
            bundleIdentifier: MediaControlPolicy.spotifyBundleID,
            revision: rev2,
            isPlaying: true
        )

        let staleRoute = MediaControlPolicy.resolveDispatchRoute(
            command: .nextTrack,
            requested: requested,
            currentSnapshot: newerSnapshot,
            isProcessRunningWithSameBundle: true,
            systemNowPlayingPID: 202
        )
        #expect(staleRoute == .rejected(.staleRevision))

        let deadRoute = MediaControlPolicy.resolveDispatchRoute(
            command: .nextTrack,
            requested: requested,
            currentSnapshot: requested,
            isProcessRunningWithSameBundle: false,
            systemNowPlayingPID: 202
        )
        #expect(deadRoute == .rejected(.processTerminatedOrMismatched))
    }

    @Test("Background Spotify falls back to PID-targeted AppleEvents or reports consent needed without touching system player")
    func backgroundSpotifyNeverTouchesActiveBrowser() {
        let rev = UUID()
        let spotifyCtx = MediaControlPolicy.TargetContext(
            pid: 300,
            bundleIdentifier: MediaControlPolicy.spotifyBundleID,
            revision: rev,
            isPlaying: false
        )

        // System player is Brave (PID 400), user is targeting pinned Spotify (PID 300)
        let consentRoute = MediaControlPolicy.resolveDispatchRoute(
            command: .togglePlayPause,
            requested: spotifyCtx,
            currentSnapshot: spotifyCtx,
            isProcessRunningWithSameBundle: true,
            systemNowPlayingPID: 400,
            directPlayerPathVerifiedForBackground: false,
            automationAccess: .requiresConsent
        )
        #expect(consentRoute == .rejected(.nonCurrentPlayerRequiresAutomationConsent(bundleIdentifier: MediaControlPolicy.spotifyBundleID)))

        let grantedRoute = MediaControlPolicy.resolveDispatchRoute(
            command: .togglePlayPause,
            requested: spotifyCtx,
            currentSnapshot: spotifyCtx,
            isProcessRunningWithSameBundle: true,
            systemNowPlayingPID: 400,
            directPlayerPathVerifiedForBackground: false,
            automationAccess: .granted
        )
        #expect(grantedRoute == .appleEventPlayer(
            pid: 300,
            bundleIdentifier: MediaControlPolicy.spotifyBundleID,
            command: .togglePlayPause
        ))
    }

    @Test("Safari WebKit GPU helper maps canonical bundle ID to com.apple.Safari while retaining helper PID for MediaRemote")
    func safariWebKitHelperCanonicalIdentity() {
        let rev = UUID()
        let safariHelper = MediaControlPolicy.TargetContext(
            pid: 512,
            bundleIdentifier: MediaControlPolicy.webKitGPUBundleID,
            parentBundleIdentifier: MediaControlPolicy.safariBundleID,
            revision: rev,
            isPlaying: true
        )
        #expect(safariHelper.canonicalApplicationBundleID == MediaControlPolicy.safariBundleID)

        let seekRoute = MediaControlPolicy.resolveDispatchRoute(
            command: .seek(seconds: 42.5),
            requested: safariHelper,
            currentSnapshot: safariHelper,
            isProcessRunningWithSameBundle: true,
            systemNowPlayingPID: 512
        )
        #expect(seekRoute == .mediaRemotePlayerPath(
            pid: 512,
            bundleIdentifier: MediaControlPolicy.webKitGPUBundleID,
            mrCommandID: 24,
            seekPosition: 42.5
        ))

        let invalidSeek = MediaControlPolicy.resolveDispatchRoute(
            command: .seek(seconds: -5.0),
            requested: safariHelper,
            currentSnapshot: safariHelper,
            isProcessRunningWithSameBundle: true,
            systemNowPlayingPID: 512
        )
        #expect(invalidSeek == .rejected(.invalidSeekPosition))

        // When Safari WebKit.GPU (512) is NOT systemNowPlayingPID (e.g. Brave 68935 owns it):
        // - If Safari JS from Apple Events is unavailable, reject instead of redirecting to Brave.
        let safariBackgroundUnavailable = MediaControlPolicy.resolveDispatchRoute(
            command: .play,
            requested: safariHelper,
            currentSnapshot: safariHelper,
            isProcessRunningWithSameBundle: true,
            systemNowPlayingPID: 68935,
            automationAccess: .unavailable
        )
        #expect(safariBackgroundUnavailable == .rejected(.unsupportedTransportForBackgroundSource(bundleIdentifier: MediaControlPolicy.safariBundleID)))

        // When Brave (68935) is NOT systemNowPlayingPID (e.g. Spotify 20684 owns it) and Automation is granted:
        let braveCtx = MediaControlPolicy.TargetContext(
            pid: 68935,
            bundleIdentifier: MediaControlPolicy.braveBundleID,
            revision: rev,
            isPlaying: false
        )
        let braveBackgroundRoute = MediaControlPolicy.resolveDispatchRoute(
            command: .seek(seconds: 75.0),
            requested: braveCtx,
            currentSnapshot: braveCtx,
            isProcessRunningWithSameBundle: true,
            systemNowPlayingPID: 20684,
            automationAccess: .granted
        )
        #expect(braveBackgroundRoute == .browserTabJavaScript(
            bundleIdentifier: MediaControlPolicy.braveBundleID,
            command: .seek(seconds: 75.0)
        ))
    }
}
