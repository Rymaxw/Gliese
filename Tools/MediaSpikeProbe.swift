import AppKit
import CoreServices
import Foundation
import ObjectiveC

/// Standalone multi-source Now Playing & Automation capability probe for T03 (`docs/spikes/media.md`).
/// Loaded into `/usr/bin/perl` via `Tools/media-spike-probe.pl` so `MediaRemote.framework` answers on macOS 15.4+ / 27.2.
///
/// Modes (via `GLIESE_MEDIA_PROBE_MODE` env var):
/// - `snapshot` (default): 100% read-only inspection of `MRMediaRemoteGetNowPlayingClient`,
///   `MRMediaRemoteGetNowPlayingClients`, per-PID `MRPlayerPath` info/state/commands, latency,
///   `.sdef` capabilities, and non-prompting TCC Automation status (`askUserIfNeeded: false`).
/// - `send-mr`: sends a single `MRMediaRemoteSendCommandToPlayer` command to `GLIESE_TARGET_PID`
///   and `GLIESE_TARGET_BUNDLE` (`GLIESE_MR_COMMAND`, optional `GLIESE_SEEK_SECONDS`).
private func resolveSymbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as type: T.Type) -> T? {
    guard let handle, let ptr = dlsym(handle, name) else { return nil }
    return unsafeBitCast(ptr, to: type)
}

private func makePlayerPath(pid: Int32, bundleID: String) -> NSObject? {
    guard let pathClass = NSClassFromString("MRPlayerPath") as? NSObject.Type,
          let clientClass = NSClassFromString("MRClient") as? NSObject.Type,
          let localPath = pathClass.perform(NSSelectorFromString("localPlayerPath"))?.takeUnretainedValue() as? NSObject,
          let path = localPath.copy() as? NSObject,
          let alloc = clientClass.perform(NSSelectorFromString("alloc"))?.takeRetainedValue(),
          let client = alloc.perform(NSSelectorFromString("initWithBundleIdentifier:"), with: bundleID)?.takeUnretainedValue() as? NSObject else {
        return nil
    }
    typealias SetPID = @convention(c) (AnyObject, Selector, Int32) -> Void
    let sel = NSSelectorFromString("setProcessIdentifier:")
    guard client.responds(to: sel),
          path.responds(to: NSSelectorFromString("setClient:")),
          path.responds(to: NSSelectorFromString("setPlayer:")) else {
        return nil
    }
    unsafeBitCast(client.method(for: sel), to: SetPID.self)(client, sel, pid)
    path.perform(NSSelectorFromString("setClient:"), with: client)
    path.perform(NSSelectorFromString("setPlayer:"), with: nil)
    return path
}

private func nonPromptingAutomationStatus(pid: Int32) -> (code: Int32, label: String) {
    guard pid > 0 else { return (-1, "invalid_pid") }
    let desc = NSAppleEventDescriptor(processIdentifier: pid)
    let status = AEDeterminePermissionToAutomateTarget(desc.aeDesc, typeWildCard, typeWildCard, false)
    switch status {
    case noErr:
        return (0, "granted")
    case OSStatus(errAEEventWouldRequireUserConsent):
        return (Int32(status), "requires_consent")
    case OSStatus(errAEEventNotPermitted):
        return (Int32(status), "denied")
    case OSStatus(procNotFound):
        return (Int32(status), "proc_not_found")
    default:
        return (Int32(status), "unavailable(\(status))")
    }
}

@_cdecl("gliese_media_spike_entry")
public func glieseMediaSpikeEntry() {
    let t0 = ProcessInfo.processInfo.systemUptime
    let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)
    let mode = ProcessInfo.processInfo.environment["GLIESE_MEDIA_PROBE_MODE"] ?? "snapshot"

    typealias ReadClient = @convention(c) (DispatchQueue, @escaping @convention(block) (AnyObject?) -> Void) -> Void
    typealias ReadClients = @convention(c) (DispatchQueue, @escaping @convention(block) (NSArray?) -> Void) -> Void
    typealias GetPID = @convention(c) (AnyObject) -> Int32
    typealias GetStr = @convention(c) (AnyObject) -> Unmanaged<CFString>?
    typealias ReadInfo = @convention(c) (AnyObject, Bool, DispatchQueue, @escaping @convention(block) (NSDictionary?, UnsafeRawPointer?) -> Void) -> Void
    typealias ReadState = @convention(c) (AnyObject, DispatchQueue, @escaping @convention(block) (UInt32) -> Void) -> Void
    typealias ReadCmds = @convention(c) (AnyObject, DispatchQueue, @escaping @convention(block) (NSArray?) -> Void) -> Void
    typealias CmdID = @convention(c) (AnyObject) -> Int32
    typealias CmdEnabled = @convention(c) (AnyObject) -> Bool
    typealias SendCmd = @convention(c) (Int32, CFDictionary?, AnyObject, UInt32, DispatchQueue, @escaping @convention(block) (UInt32, NSArray?) -> Void) -> Bool
    typealias SendCmdToClient = @convention(c) (Int32, CFDictionary?, AnyObject?, AnyObject, UInt32, DispatchQueue, @escaping @convention(block) (UInt32, NSArray?) -> Void) -> Bool
    typealias SetPlayer = @convention(c) (AnyObject, DispatchQueue, @escaping @convention(block) (AnyObject?) -> Void) -> Void

    let q = DispatchQueue(label: "com.rymaxw.gliese.media-spike")

    if mode == "send-mr" {
        guard let pidStr = ProcessInfo.processInfo.environment["GLIESE_TARGET_PID"],
              let pid = Int32(pidStr),
              let bundle = ProcessInfo.processInfo.environment["GLIESE_TARGET_BUNDLE"],
              let cmdStr = ProcessInfo.processInfo.environment["GLIESE_MR_COMMAND"],
              let cmd = Int32(cmdStr),
              let path = makePlayerPath(pid: pid, bundleID: bundle),
              let send = resolveSymbol(handle, "MRMediaRemoteSendCommandToPlayer", as: SendCmd.self) else {
            print("{\"error\":\"invalid_send_mr_args\"}")
            return
        }
        var opts: [String: Any] = [:]
        if let seekStr = ProcessInfo.processInfo.environment["GLIESE_SEEK_SECONDS"],
           let seek = Double(seekStr),
           let sym = dlsym(handle, "kMRMediaRemoteOptionPlaybackPosition"),
           let key = sym.assumingMemoryBound(to: NSString?.self).pointee as String? {
            opts[key] = seek
        }
        if let itemID = ProcessInfo.processInfo.environment["GLIESE_ITEM_ID"],
           !itemID.isEmpty,
           let sym = dlsym(handle, "kMRMediaRemoteOptionNowPlayingContentItemID"),
           let key = sym.assumingMemoryBound(to: NSString?.self).pointee as String? {
            opts[key] = itemID
        }
        if ProcessInfo.processInfo.environment["GLIESE_SET_NOW_PLAYING_PLAYER"] == "1",
           let setPlayer = resolveSymbol(handle, "MRMediaRemoteSetNowPlayingPlayer", as: SetPlayer.self) {
            let sg = DispatchGroup()
            sg.enter()
            setPlayer(path, q) { _ in sg.leave() }
            _ = sg.wait(timeout: .now() + 1.0)
        }
        let g = DispatchGroup()
        var sendErr: UInt32 = 999
        var handlerCodes: [Int] = []
        g.enter()
        let accepted: Bool
        if ProcessInfo.processInfo.environment["GLIESE_SEND_TO_CLIENT"] == "1",
           let sendClient = resolveSymbol(handle, "MRMediaRemoteSendCommandToClient", as: SendCmdToClient.self),
           let client = path.perform(NSSelectorFromString("client"))?.takeUnretainedValue() {
            let origin = path.perform(NSSelectorFromString("origin"))?.takeUnretainedValue()
            accepted = sendClient(cmd, opts.isEmpty ? nil : opts as CFDictionary, origin, client, 0, q) { err, arr in
                sendErr = err
                handlerCodes = (arr as? [NSNumber])?.map(\.intValue) ?? []
                g.leave()
            }
        } else {
            accepted = send(cmd, opts.isEmpty ? nil : opts as CFDictionary, path, 0, q) { err, arr in
                sendErr = err
                handlerCodes = (arr as? [NSNumber])?.map(\.intValue) ?? []
                g.leave()
            }
        }
        _ = g.wait(timeout: .now() + 2.0)
        let delivered = accepted && sendErr == 0 && handlerCodes.contains(0)
        let out: [String: Any] = [
            "mode": "send-mr",
            "targetPID": pid,
            "targetBundle": bundle,
            "command": cmd,
            "accepted": accepted,
            "error": sendErr,
            "handlerCodes": handlerCodes,
            "delivered": delivered
        ]
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        return
    }

    guard let getClient = resolveSymbol(handle, "MRMediaRemoteGetNowPlayingClient", as: ReadClient.self),
          let getClients = resolveSymbol(handle, "MRMediaRemoteGetNowPlayingClients", as: ReadClients.self),
          let getPID = resolveSymbol(handle, "MRNowPlayingClientGetProcessIdentifier", as: GetPID.self),
          let readInfo = resolveSymbol(handle, "MRMediaRemoteGetNowPlayingInfoForPlayer", as: ReadInfo.self),
          let readState = resolveSymbol(handle, "MRMediaRemoteGetPlaybackStateForPlayer", as: ReadState.self),
          let readCmds = resolveSymbol(handle, "MRMediaRemoteGetSupportedCommandsForPlayer", as: ReadCmds.self),
          let cmdID = resolveSymbol(handle, "MRMediaRemoteCommandInfoGetCommand", as: CmdID.self),
          let cmdEnabled = resolveSymbol(handle, "MRMediaRemoteCommandInfoGetEnabled", as: CmdEnabled.self) else {
        print("{\"error\":\"missing_mediaremote_symbols\"}")
        return
    }
    let getBundle = resolveSymbol(handle, "MRNowPlayingClientGetBundleIdentifier", as: GetStr.self)
    let getParent = resolveSymbol(handle, "MRNowPlayingClientGetParentAppBundleIdentifier", as: GetStr.self)
    let getName = resolveSymbol(handle, "MRNowPlayingClientGetDisplayName", as: GetStr.self)

    let g = DispatchGroup()
    var systemPID: Int32 = 0
    var rawClients: [AnyObject] = []

    g.enter()
    getClient(q) { c in
        if let c { systemPID = getPID(c) }
        g.leave()
    }
    g.enter()
    getClients(q) { arr in
        rawClients = (arr as? [AnyObject]) ?? []
        g.leave()
    }
    _ = g.wait(timeout: .now() + 1.5)

    var clientRecords: [[String: Any]] = []
    for c in rawClients {
        let clientStart = ProcessInfo.processInfo.systemUptime
        let pid = getPID(c)
        let bundle = (getBundle?(c)?.takeUnretainedValue() as String?)
            ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            ?? ""
        let parent = getParent?(c)?.takeUnretainedValue() as String?
        let name = (getName?(c)?.takeUnretainedValue() as String?)
            ?? NSRunningApplication(processIdentifier: pid)?.localizedName
            ?? ""
        guard !bundle.isEmpty, let path = makePlayerPath(pid: pid, bundleID: bundle) else { continue }

        let cg = DispatchGroup()
        var title: String?
        var artist: String?
        var album: String?
        var itemID: String?
        var duration: Double?
        var elapsed: Double?
        var rate: Double?
        var stateVal: UInt32 = 0
        var enabledCommands: [Int32] = []

        cg.enter()
        readInfo(path, false, q) { info, _ in
            if let d = info as? [String: Any] {
                title = d["kMRMediaRemoteNowPlayingInfoTitle"] as? String
                artist = d["kMRMediaRemoteNowPlayingInfoArtist"] as? String
                album = d["kMRMediaRemoteNowPlayingInfoAlbum"] as? String
                itemID = d["kMRMediaRemoteNowPlayingInfoContentItemIdentifier"] as? String
                duration = (d["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue
                elapsed = (d["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue
                rate = (d["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue
            }
            cg.leave()
        }
        cg.enter()
        readState(path, q) { st in
            stateVal = st
            cg.leave()
        }
        cg.enter()
        readCmds(path, q) { cmds in
            if let arr = cmds as? [AnyObject] {
                enabledCommands = arr.filter { cmdEnabled($0) }.map { cmdID($0) }
            }
            cg.leave()
        }
        _ = cg.wait(timeout: .now() + 1.5)
        let latencyMs = (ProcessInfo.processInfo.systemUptime - clientStart) * 1000.0
        let tcc = nonPromptingAutomationStatus(pid: pid)

        var rec: [String: Any] = [:]
        rec["pid"] = pid
        rec["bundleID"] = bundle
        rec["parentBundleID"] = parent ?? NSNull()
        rec["displayName"] = name
        rec["isSystemCurrent"] = (pid == systemPID)
        rec["playbackState"] = stateVal
        rec["playbackRate"] = rate ?? NSNull()
        rec["title"] = title ?? NSNull()
        rec["artist"] = artist ?? NSNull()
        rec["album"] = album ?? NSNull()
        rec["itemIdentifier"] = itemID ?? NSNull()
        rec["duration"] = duration ?? NSNull()
        rec["elapsed"] = elapsed ?? NSNull()
        rec["enabledCommands"] = enabledCommands
        rec["queryLatencyMs"] = Double(round(100 * latencyMs) / 100)
        rec["automationTCC"] = tcc.label
        clientRecords.append(rec)
    }

    var targetAppStates: [[String: Any]] = []
    for targetBundle in ["com.spotify.client", "com.brave.Browser", "com.apple.Safari"] {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == targetBundle }
        if apps.isEmpty {
            targetAppStates.append([
                "bundleID": targetBundle,
                "running": false
            ])
        } else {
            for app in apps {
                let tcc = nonPromptingAutomationStatus(pid: app.processIdentifier)
                targetAppStates.append([
                    "bundleID": targetBundle,
                    "running": true,
                    "pid": app.processIdentifier,
                    "localizedName": app.localizedName ?? "",
                    "automationTCCCode": tcc.code,
                    "automationTCCLabel": tcc.label
                ])
            }
        }
    }

    let totalLatencyMs = (ProcessInfo.processInfo.systemUptime - t0) * 1000.0
    let output: [String: Any] = [
        "mode": mode,
        "systemNowPlayingPID": systemPID,
        "registeredClientCount": clientRecords.count,
        "registeredClients": clientRecords,
        "mandatoryTargetApps": targetAppStates,
        "totalProbeLatencyMs": Double(round(100 * totalLatencyMs) / 100)
    ]
    if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]),
       let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}
