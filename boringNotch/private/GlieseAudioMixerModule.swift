import AppKit
import AudioToolbox
import AVFoundation
import Combine
import CoreAudio
import Darwin
import Foundation
import GlieseCore
import SwiftUI

final class AtomicFloatBox: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var value: Float

    init(_ initial: Float) {
        self.value = initial
    }

    func load() -> Float {
        os_unfair_lock_lock(&lock)
        let v = value
        os_unfair_lock_unlock(&lock)
        return v
    }

    func store(_ newValue: Float) {
        os_unfair_lock_lock(&lock)
        value = newValue
        os_unfair_lock_unlock(&lock)
    }
}

final class GlieseAppTapEngine {
    let bundleIdentifier: String
    let targetDeviceUID: String
    let processObjectIDs: [AudioObjectID]
    let gainBox: AtomicFloatBox

    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private(set) var isRunning: Bool = false

    init(
        bundleIdentifier: String,
        targetDeviceUID: String,
        processObjectIDs: [AudioObjectID],
        initialGain: Float
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.targetDeviceUID = targetDeviceUID
        self.processObjectIDs = processObjectIDs
        self.gainBox = AtomicFloatBox(initialGain)
    }

    deinit {
        stop()
    }

    func start() -> Bool {
        guard #available(macOS 14.2, *) else { return false }
        guard !processObjectIDs.isEmpty else { return false }

        let tapDesc = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        tapDesc.uuid = UUID()
        tapDesc.name = "GlieseTap-\(bundleIdentifier)"
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .mutedWhenTapped

        var createdTapID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(tapDesc, &createdTapID) == noErr,
              createdTapID != kAudioObjectUnknown else {
            return false
        }
        self.tapID = createdTapID

        let aggUID = "com.rymaxw.gliese.mixer.\(UUID().uuidString)"
        let subDevices: [[String: Any]] = [[kAudioSubDeviceUIDKey: targetDeviceUID]]
        let subTaps: [[String: Any]] = [[
            kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
            kAudioSubTapDriftCompensationKey: true,
        ]]
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "GlieseMixer-\(bundleIdentifier)",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: targetDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: subTaps,
        ]

        var createdAggID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &createdAggID) == noErr,
              createdAggID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(createdTapID)
            self.tapID = AudioObjectID(kAudioObjectUnknown)
            return false
        }
        self.aggregateID = createdAggID

        let box = self.gainBox
        var createdIOProcID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(
            &createdIOProcID,
            createdAggID,
            nil
        ) { _, inInputData, _, outOutputData, _ in
            let g = box.load()
            let inBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let outBuffers = UnsafeMutableAudioBufferListPointer(outOutputData)
            let count = min(inBuffers.count, outBuffers.count)

            for idx in 0..<count {
                guard let inPtr = inBuffers[idx].mData?.assumingMemoryBound(to: Float.self),
                      let outPtr = outBuffers[idx].mData?.assumingMemoryBound(to: Float.self) else {
                    continue
                }
                let sampleCount = min(
                    Int(inBuffers[idx].mDataByteSize) / MemoryLayout<Float>.size,
                    Int(outBuffers[idx].mDataByteSize) / MemoryLayout<Float>.size
                )
                if g <= 0.00001 {
                    memset(outPtr, 0, sampleCount * MemoryLayout<Float>.size)
                } else {
                    for s in 0..<sampleCount {
                        outPtr[s] = inPtr[s] * g
                    }
                }
            }
        }

        guard ioStatus == noErr, let validIOProc = createdIOProcID else {
            AudioHardwareDestroyAggregateDevice(createdAggID)
            AudioHardwareDestroyProcessTap(createdTapID)
            self.aggregateID = AudioObjectID(kAudioObjectUnknown)
            self.tapID = AudioObjectID(kAudioObjectUnknown)
            return false
        }
        self.ioProcID = validIOProc

        guard AudioDeviceStart(createdAggID, validIOProc) == noErr else {
            AudioDeviceDestroyIOProcID(createdAggID, validIOProc)
            AudioHardwareDestroyAggregateDevice(createdAggID)
            AudioHardwareDestroyProcessTap(createdTapID)
            self.ioProcID = nil
            self.aggregateID = AudioObjectID(kAudioObjectUnknown)
            self.tapID = AudioObjectID(kAudioObjectUnknown)
            return false
        }

        self.isRunning = true
        return true
    }

    func stop() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            _ = AudioDeviceStop(aggregateID, ioProcID)
            _ = AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        self.ioProcID = nil

        if aggregateID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
            self.aggregateID = AudioObjectID(kAudioObjectUnknown)
        }

        if tapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) {
                _ = AudioHardwareDestroyProcessTap(tapID)
            }
            self.tapID = AudioObjectID(kAudioObjectUnknown)
        }
        self.isRunning = false
    }
}

@MainActor
final class GlieseAudioMixerManager: ObservableObject {
    static let shared = GlieseAudioMixerManager()

    struct OutputDeviceItem: Identifiable, Equatable {
        let id: String // UID
        let objectID: AudioObjectID
        let name: String
        let isSystemDefault: Bool
    }

    struct AppMixerItem: Identifiable, Equatable {
        let id: String // bundleIdentifier
        var displayName: String
        var icon: NSImage?
        var pids: [Int32]
        var processObjectIDs: [AudioObjectID]
        var isRunningOutput: Bool
        var setting: AudioMixerPolicy.AppAudioSetting
        var routeResolution: AudioMixerPolicy.RouteResolution
        var hasActiveTapEngine: Bool

        static func == (lhs: AppMixerItem, rhs: AppMixerItem) -> Bool {
            lhs.id == rhs.id &&
            lhs.displayName == rhs.displayName &&
            lhs.pids == rhs.pids &&
            lhs.processObjectIDs == rhs.processObjectIDs &&
            lhs.isRunningOutput == rhs.isRunningOutput &&
            lhs.setting == rhs.setting &&
            lhs.routeResolution == rhs.routeResolution &&
            lhs.hasActiveTapEngine == rhs.hasActiveTapEngine
        }
    }

    @Published private(set) var outputDevices: [OutputDeviceItem] = []
    @Published private(set) var systemDefaultDeviceUID: String = ""
    @Published private(set) var systemDefaultDeviceName: String = "System Output"
    @Published private(set) var appItems: [AppMixerItem] = []

    private var settingsByBundle: [String: AudioMixerPolicy.AppAudioSetting] = [:]
    private var activeEngines: [String: GlieseAppTapEngine] = [:]
    private var tokenFence = AudioMixerPolicy.EngineTokenFence()
    private var refreshTimer: Timer?

    private init() {
        refreshInventory()
    }

    func startMonitoring() {
        refreshInventory()
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshInventory()
            }
        }
    }

    func stopMonitoring() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func stopAllEngines() {
        stopMonitoring()
        for (_, engine) in activeEngines {
            engine.stop()
        }
        activeEngines.removeAll()
    }

    func setVolume(for bundleID: String, volume: Double) {
        var setting = settingsByBundle[bundleID] ?? AudioMixerPolicy.AppAudioSetting(bundleIdentifier: bundleID)
        setting.volume = AudioMixerPolicy.clampVolume(volume)
        if setting.volume > 0 && setting.isMuted {
            setting.isMuted = false
        }
        settingsByBundle[bundleID] = setting
        applyEngineState(for: bundleID)
    }

    func toggleMute(for bundleID: String) {
        var setting = settingsByBundle[bundleID] ?? AudioMixerPolicy.AppAudioSetting(bundleIdentifier: bundleID)
        setting.isMuted.toggle()
        settingsByBundle[bundleID] = setting
        applyEngineState(for: bundleID)
    }

    func setOutputDevice(for bundleID: String, deviceUID: String?) {
        var setting = settingsByBundle[bundleID] ?? AudioMixerPolicy.AppAudioSetting(bundleIdentifier: bundleID)
        setting.selectedDeviceUID = (deviceUID?.isEmpty == true) ? nil : deviceUID
        settingsByBundle[bundleID] = setting
        applyEngineState(for: bundleID)
    }

    func resetApp(_ bundleID: String) {
        settingsByBundle[bundleID] = AudioMixerPolicy.AppAudioSetting(
            bundleIdentifier: bundleID,
            volume: 1.0,
            isMuted: false,
            selectedDeviceUID: nil
        )
        applyEngineState(for: bundleID)
    }

    func refreshInventory() {
        let defaultID = readDefaultOutputDeviceID()
        let devices = enumerateOutputDevices(defaultID: defaultID)
        outputDevices = devices

        if let defDev = devices.first(where: { $0.isSystemDefault }) ?? devices.first {
            systemDefaultDeviceUID = defDev.id
            systemDefaultDeviceName = defDev.name
        }

        let availableUIDs = Set(devices.map(\.id))
        let selfPID = getpid()

        let discoveredApps = discoverAudioProcesses(selfPID: selfPID)
        var nextItems: [AppMixerItem] = []

        for entry in discoveredApps {
            let setting = settingsByBundle[entry.bundleID]
                ?? AudioMixerPolicy.AppAudioSetting(bundleIdentifier: entry.bundleID)
            settingsByBundle[entry.bundleID] = setting

            let resolution = AudioMixerPolicy.resolveRoute(
                selectedDeviceUID: setting.selectedDeviceUID,
                availableDeviceUIDs: availableUIDs
            )

            let needsEngine = AudioMixerPolicy.requiresTapEngine(
                for: setting,
                effectiveDeviceUID: resolution.effectiveDeviceUID,
                systemDefaultDeviceUID: systemDefaultDeviceUID
            ) && !entry.processObjectIDs.isEmpty

            synchronizeEngine(
                bundleID: entry.bundleID,
                setting: setting,
                resolution: resolution,
                processObjectIDs: entry.processObjectIDs,
                needsEngine: needsEngine
            )

            nextItems.append(
                AppMixerItem(
                    id: entry.bundleID,
                    displayName: entry.displayName,
                    icon: entry.icon,
                    pids: entry.pids,
                    processObjectIDs: entry.processObjectIDs,
                    isRunningOutput: entry.isRunningOutput,
                    setting: setting,
                    routeResolution: resolution,
                    hasActiveTapEngine: activeEngines[entry.bundleID]?.isRunning == true
                )
            )
        }

        // Stop engines for apps that quit
        let activeBundles = Set(nextItems.map(\.id))
        for (bundleID, engine) in activeEngines where !activeBundles.contains(bundleID) {
            engine.stop()
            activeEngines.removeValue(forKey: bundleID)
        }

        appItems = nextItems
    }

    // MARK: - Engine Synchronization

    private func applyEngineState(for bundleID: String) {
        guard let idx = appItems.firstIndex(where: { $0.id == bundleID }),
              let setting = settingsByBundle[bundleID] else { return }

        let availableUIDs = Set(outputDevices.map(\.id))
        let resolution = AudioMixerPolicy.resolveRoute(
            selectedDeviceUID: setting.selectedDeviceUID,
            availableDeviceUIDs: availableUIDs
        )
        let item = appItems[idx]
        let needsEngine = AudioMixerPolicy.requiresTapEngine(
            for: setting,
            effectiveDeviceUID: resolution.effectiveDeviceUID,
            systemDefaultDeviceUID: systemDefaultDeviceUID
        ) && !item.processObjectIDs.isEmpty

        synchronizeEngine(
            bundleID: bundleID,
            setting: setting,
            resolution: resolution,
            processObjectIDs: item.processObjectIDs,
            needsEngine: needsEngine
        )

        appItems[idx].setting = setting
        appItems[idx].routeResolution = resolution
        appItems[idx].hasActiveTapEngine = activeEngines[bundleID]?.isRunning == true
    }

    private func synchronizeEngine(
        bundleID: String,
        setting: AudioMixerPolicy.AppAudioSetting,
        resolution: AudioMixerPolicy.RouteResolution,
        processObjectIDs: [AudioObjectID],
        needsEngine: Bool
    ) {
        let token = tokenFence.issueToken(for: bundleID)
        guard tokenFence.isCurrent(token: token, for: bundleID) else { return }

        if !needsEngine {
            if let existing = activeEngines.removeValue(forKey: bundleID) {
                existing.stop()
            }
            return
        }

        let targetUID = resolution.effectiveDeviceUID ?? systemDefaultDeviceUID
        guard !targetUID.isEmpty else { return }
        let gain = AudioMixerPolicy.gainScalar(for: setting)

        if let existing = activeEngines[bundleID],
           existing.isRunning,
           existing.targetDeviceUID == targetUID,
           existing.processObjectIDs == processObjectIDs {
            existing.gainBox.store(gain)
            return
        }

        if let existing = activeEngines.removeValue(forKey: bundleID) {
            existing.stop()
        }

        let newEngine = GlieseAppTapEngine(
            bundleIdentifier: bundleID,
            targetDeviceUID: targetUID,
            processObjectIDs: processObjectIDs,
            initialGain: gain
        )
        if newEngine.start() {
            activeEngines[bundleID] = newEngine
        }
    }

    // MARK: - CoreAudio Discovery Helpers

    private struct DiscoveredAudioApp {
        let bundleID: String
        let displayName: String
        let icon: NSImage?
        var pids: [Int32]
        var processObjectIDs: [AudioObjectID]
        var isRunningOutput: Bool
    }

    private func discoverAudioProcesses(selfPID: Int32) -> [DiscoveredAudioApp] {
        let procObjects = readAudioObjectIDArray(
            AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList
        )

        var nodes: [Int32: AudioMixerPolicy.ProcessNode] = [:]
        var rawProcessEntries: [(objectID: AudioObjectID, pid: Int32, bundleID: String, isRunningOut: Bool)] = []

        for objID in procObjects {
            guard let pid: Int32 = readScalar(objID, selector: kAudioProcessPropertyPID), pid > 0 else {
                continue
            }
            let ppid = parentPID(of: pid)
            let bundleID = readCFString(objID, selector: kAudioProcessPropertyBundleID)
                ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                ?? ""
            let isRunningOut: UInt32 = readScalar(objID, selector: kAudioProcessPropertyIsRunningOutput) ?? 0
            nodes[pid] = AudioMixerPolicy.ProcessNode(
                pid: pid,
                ppid: ppid,
                bundleIdentifier: bundleID.isEmpty ? nil : bundleID
            )
            rawProcessEntries.append((objID, pid, bundleID, isRunningOut != 0))
        }

        var grouped: [String: DiscoveredAudioApp] = [:]

        for entry in rawProcessEntries {
            if AudioMixerPolicy.isSelfOrDescendant(pid: entry.pid, selfPID: selfPID, processTable: nodes) {
                continue
            }
            let canonicalBundle = resolveResponsibleBundleID(pid: entry.pid, rawBundleID: entry.bundleID, nodes: nodes)
            guard !canonicalBundle.isEmpty,
                  canonicalBundle != AudioMixerPolicy.glieseBundleID,
                  !canonicalBundle.hasPrefix("com.apple.coreaudio"),
                  canonicalBundle != "com.apple.systemsoundserverd" else {
                continue
            }

            let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: canonicalBundle).first
                ?? NSRunningApplication(processIdentifier: entry.pid)
            let name = runningApp?.localizedName ?? canonicalBundle.components(separatedBy: ".").last ?? canonicalBundle
            let icon = runningApp?.icon

            if var existing = grouped[canonicalBundle] {
                if !existing.pids.contains(entry.pid) {
                    existing.pids.append(entry.pid)
                }
                if !existing.processObjectIDs.contains(entry.objectID) {
                    existing.processObjectIDs.append(entry.objectID)
                }
                existing.isRunningOutput = existing.isRunningOutput || entry.isRunningOut
                grouped[canonicalBundle] = existing
            } else {
                grouped[canonicalBundle] = DiscoveredAudioApp(
                    bundleID: canonicalBundle,
                    displayName: name,
                    icon: icon,
                    pids: [entry.pid],
                    processObjectIDs: [entry.objectID],
                    isRunningOutput: entry.isRunningOut
                )
            }
        }

        // Ensure running primary media apps (Spotify, Brave, Safari) appear even when paused
        let pinnedMediaBundles = [
            MediaControlPolicy.spotifyBundleID,
            MediaControlPolicy.braveBundleID,
            MediaControlPolicy.safariBundleID,
        ]
        for bundleID in pinnedMediaBundles where grouped[bundleID] == nil {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                grouped[bundleID] = DiscoveredAudioApp(
                    bundleID: bundleID,
                    displayName: app.localizedName ?? bundleID,
                    icon: app.icon,
                    pids: [app.processIdentifier],
                    processObjectIDs: [],
                    isRunningOutput: false
                )
            }
        }

        return grouped.values.sorted { lhs, rhs in
            if lhs.isRunningOutput != rhs.isRunningOutput {
                return lhs.isRunningOutput && !rhs.isRunningOutput
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func resolveResponsibleBundleID(
        pid: Int32,
        rawBundleID: String,
        nodes: [Int32: AudioMixerPolicy.ProcessNode]
    ) -> String {
        let normalized = MediaControlPolicy.normalizeBundleIdentifier(rawBundleID)
        if normalized.hasSuffix(".helper") || normalized.contains(".Helper") {
            if let parent = nodes[pid]?.ppid,
               let parentApp = NSRunningApplication(processIdentifier: parent),
               let parentBundle = parentApp.bundleIdentifier {
                return MediaControlPolicy.normalizeBundleIdentifier(parentBundle)
            }
            if normalized.hasPrefix("com.brave.Browser") {
                return MediaControlPolicy.braveBundleID
            }
            if normalized.hasPrefix("com.spotify.client") {
                return MediaControlPolicy.spotifyBundleID
            }
        }
        return normalized
    }

    private func parentPID(of pid: Int32) -> Int32 {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }

    private func readDefaultOutputDeviceID() -> AudioObjectID {
        readScalar(
            AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice
        ) ?? AudioObjectID(kAudioObjectUnknown)
    }

    private func enumerateOutputDevices(defaultID: AudioObjectID) -> [OutputDeviceItem] {
        let allIDs = readAudioObjectIDArray(
            AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices
        )
        var result: [OutputDeviceItem] = []

        for devID in allIDs {
            guard hasOutputChannels(devID),
                  let uid = readCFString(devID, selector: kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix("com.rymaxw.gliese.mixer.") else {
                continue
            }
            let name = readCFString(devID, selector: kAudioObjectPropertyName) ?? uid
            result.append(
                OutputDeviceItem(
                    id: uid,
                    objectID: devID,
                    name: name,
                    isSystemDefault: devID == defaultID
                )
            )
        }
        return result
    }

    private func hasOutputChannels(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else {
            return false
        }
        let rawPtr = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPtr.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, rawPtr) == noErr else {
            return false
        }
        let bufferList = UnsafeMutableAudioBufferListPointer(rawPtr.assumingMemoryBound(to: AudioBufferList.self))
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private func readScalar<T>(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<T>.size)
        let ptr = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, ptr) == noErr else {
            return nil
        }
        return ptr.pointee
    }

    private func readCFString(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var unmanaged: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &unmanaged) { ptr in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let cfStr = unmanaged?.takeUnretainedValue() else {
            return nil
        }
        return cfStr as String
    }

    private func readAudioObjectIDArray(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var values = Array(repeating: AudioObjectID(0), count: count)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &values) == noErr else {
            return []
        }
        return values
    }
}

// MARK: - Notch Mixer Tab View

struct GlieseMixerView: View {
    @ObservedObject var mixer = GlieseAudioMixerManager.shared
    @ObservedObject var volumeManager = VolumeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            masterSystemRow
            Divider().overlay(Color.white.opacity(0.12))
            perAppSection
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            mixer.startMonitoring()
        }
        .onDisappear {
            mixer.stopMonitoring()
        }
    }

    private var masterSystemRow: some View {
        HStack(spacing: 10) {
            Button {
                volumeManager.toggleMuteAction()
            } label: {
                Image(systemName: volumeManager.isMuted || volumeManager.rawVolume <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(volumeManager.isMuted ? Color.orange : Color.white)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(volumeManager.isMuted ? "Unmute system output" : "Mute system output")

            VStack(alignment: .leading, spacing: 1) {
                Text("System Output")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text(mixer.systemDefaultDeviceName)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            .frame(width: 145, alignment: .leading)

            Slider(
                value: Binding(
                    get: { Double(volumeManager.isMuted ? 0 : volumeManager.rawVolume) },
                    set: { newVal in
                        volumeManager.setAbsolute(Float32(AudioMixerPolicy.clampVolume(newVal)))
                    }
                ),
                in: 0.0...1.0
            )
            .controlSize(.small)
            .accessibilityLabel("System output volume")

            Text("\(Int(round((volumeManager.isMuted ? 0 : volumeManager.rawVolume) * 100)))%")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 38, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var perAppSection: some View {
        if mixer.appItems.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("No active audio applications")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                Text("Start playback in Spotify, Brave, Safari, or any audio app to adjust per-app volume and output routing.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.48))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(mixer.appItems) { item in
                        appRow(item)
                    }
                }
            }
        }
    }

    private func appRow(_ item: GlieseAudioMixerManager.AppMixerItem) -> some View {
        HStack(spacing: 8) {
            Button {
                mixer.toggleMute(for: item.id)
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    if let icon = item.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 22, height: 22)
                    } else {
                        Image(systemName: "app.fill")
                            .font(.system(size: 16))
                            .frame(width: 22, height: 22)
                    }
                    if item.setting.isMuted {
                        Image(systemName: "speaker.slash.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.setting.isMuted ? "Unmute \(item.displayName)" : "Mute \(item.displayName)")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(item.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if item.isRunningOutput {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 5, height: 5)
                    }
                }
                if item.routeResolution.didFallbackToSystemDefault {
                    Text("Device disconnected — using System Default")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            .frame(width: 130, alignment: .leading)

            Slider(
                value: Binding(
                    get: { item.setting.isMuted ? 0.0 : item.setting.volume },
                    set: { newVal in
                        mixer.setVolume(for: item.id, volume: newVal)
                    }
                ),
                in: 0.0...1.0
            )
            .controlSize(.small)
            .accessibilityLabel("\(item.displayName) volume")

            Text("\(Int(round((item.setting.isMuted ? 0.0 : item.setting.volume) * 100)))%")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 36, alignment: .trailing)

            Menu {
                Button {
                    mixer.setOutputDevice(for: item.id, deviceUID: nil)
                } label: {
                    HStack {
                        Text("System Default (\(mixer.systemDefaultDeviceName))")
                        if item.setting.selectedDeviceUID == nil {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                Divider()
                ForEach(mixer.outputDevices) { dev in
                    Button {
                        mixer.setOutputDevice(for: item.id, deviceUID: dev.id)
                    } label: {
                        HStack {
                            Text(dev.name)
                            if item.setting.selectedDeviceUID == dev.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Text(shortRouteLabel(for: item))
                    .font(.system(size: 9.5, weight: .medium))
                    .lineLimit(1)
                    .frame(width: 105, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .accessibilityLabel("\(item.displayName) output device")
        }
        .padding(.vertical, 2)
    }

    private func shortRouteLabel(for item: GlieseAudioMixerManager.AppMixerItem) -> String {
        guard let selectedUID = item.setting.selectedDeviceUID else {
            return "Default Output"
        }
        if let dev = mixer.outputDevices.first(where: { $0.id == selectedUID }) {
            return dev.name
        }
        return "Default (Fallback)"
    }
}
