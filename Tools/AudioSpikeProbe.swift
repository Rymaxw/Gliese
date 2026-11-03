import AppKit
import AVFoundation
import CoreAudio
import Darwin
import Foundation

/// CoreAudio device, process inventory, and live `CATapDescription` verification probe for T04 (`docs/spikes/audio.md`).
///
/// Modes (via `GLIESE_AUDIO_PROBE_MODE`):
/// - `inventory` (default): 100% read-only inspection of output devices and `kAudioHardwarePropertyProcessObjectList`.
/// - `tone-child`: internal helper mode that renders a quiet (`0.04` peak) 440 Hz sine wave via `AVAudioEngine`
///   so `live-tap` can test `CATapDescription` against a deterministic local process without playing music.
/// - `live-tap`: spawns `tone-child`, attaches `CATapDescription(stereoMixdownOfProcesses:)` + private aggregate
///   device + `AudioDeviceCreateIOProcIDWithBlock`, verifies Unity (`1.0`), 50% slider (`0.25` gain), Mute (`0.0`),
///   and clean teardown (`AudioDeviceStop`, `AudioDeviceDestroyIOProcID`, `AudioHardwareDestroyAggregateDevice`,
///   `AudioHardwareDestroyProcessTap`).
private func readProperty<T>(
    _ objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    initial: T
) -> T? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(objectID, &address) else { return nil }
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutablePointer(to: &value) { ptr in
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, ptr)
    }
    return status == noErr ? value : nil
}

private func readCFString(
    _ objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(objectID, &address) else { return nil }
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &value) { ptr in
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, ptr)
    }
    guard status == noErr, let cf = value?.takeUnretainedValue() else { return nil }
    return cf as String
}

private func readObjectIDArray(
    _ objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(objectID, &address) else { return [] }
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr,
          size >= MemoryLayout<AudioObjectID>.size else { return [] }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var array = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &array) == noErr else { return [] }
    return array
}

private func outputChannelCount(_ deviceID: AudioObjectID) -> Int {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
          size >= MemoryLayout<AudioBufferList>.size else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

private let responsibilityFunc: (@convention(c) (pid_t) -> pid_t)? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
        return nil
    }
    return unsafeBitCast(sym, to: (@convention(c) (pid_t) -> pid_t).self)
}()

private func parentPID(of pid: pid_t) -> pid_t {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return 0 }
    return info.kp_eproc.e_ppid
}

private func owningRegularApp(for pid: pid_t) -> NSRunningApplication? {
    guard pid > 0 else { return nil }
    let responsible = responsibilityFunc?(pid) ?? pid
    let startPID = responsible > 0 ? responsible : pid
    if let app = NSRunningApplication(processIdentifier: startPID), app.activationPolicy == .regular {
        return app
    }
    var current = startPID
    for _ in 0..<6 {
        current = parentPID(of: current)
        guard current > 1 else { return nil }
        if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
            return app
        }
    }
    return nil
}

private final class ProbeMetricsBox {
    private let lock = NSLock()
    private var gainValue: Float = 1.0
    private var renderCycles: Int = 0
    private var maxInputPeak: Float = 0.0
    private var maxOutputPeak: Float = 0.0

    func setGain(_ g: Float, resetStats: Bool) {
        lock.lock()
        gainValue = g
        if resetStats {
            renderCycles = 0
            maxInputPeak = 0.0
            maxOutputPeak = 0.0
        }
        lock.unlock()
    }

    func currentGain() -> Float {
        lock.lock()
        defer { lock.unlock() }
        return gainValue
    }

    func record(appliedGain: Float, inputPeak: Float, outputPeak: Float) {
        lock.lock()
        guard abs(appliedGain - gainValue) < 0.0001 else {
            lock.unlock()
            return
        }
        renderCycles += 1
        if inputPeak > maxInputPeak { maxInputPeak = inputPeak }
        if outputPeak > maxOutputPeak { maxOutputPeak = outputPeak }
        lock.unlock()
    }

    func snapshot() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let ratio = maxInputPeak > 0.00001 ? Double(maxOutputPeak / maxInputPeak) : 0.0
        return [
            "appliedGain": Double(round(1000 * Double(gainValue)) / 1000),
            "renderCycles": renderCycles,
            "maxInputPeak": Double(round(100000 * Double(maxInputPeak)) / 100000),
            "maxOutputPeak": Double(round(100000 * Double(maxOutputPeak)) / 100000),
            "observedPeakRatio": Double(round(1000 * ratio) / 1000)
        ]
    }
}

let mode = ProcessInfo.processInfo.environment["GLIESE_AUDIO_PROBE_MODE"] ?? "inventory"

if mode == "tone-child" {
    let engine = AVAudioEngine()
    let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate > 0 ? sampleRate : 48000, channels: 2)!
    var phase: Double = 0.0
    let step = 2.0 * Double.pi * 440.0 / format.sampleRate
    let sourceNode = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
        let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for frame in 0..<Int(frameCount) {
            let sample = Float(sin(phase) * 0.04)
            phase += step
            if phase >= 2.0 * Double.pi { phase -= 2.0 * Double.pi }
            for buf in abl {
                guard let ptr = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let channels = Int(buf.mNumberChannels)
                if channels == 1 {
                    ptr[frame] = sample
                } else {
                    for ch in 0..<channels {
                        ptr[frame * channels + ch] = sample
                    }
                }
            }
        }
        return noErr
    }
    engine.attach(sourceNode)
    engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
    try? engine.start()
    Thread.sleep(forTimeInterval: 5.0)
    engine.stop()
    exit(0)
}

let systemObject = AudioObjectID(kAudioObjectSystemObject)
let defaultOutputID = readProperty(systemObject, selector: kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0)) ?? 0
let defaultSystemID = readProperty(systemObject, selector: kAudioHardwarePropertyDefaultSystemOutputDevice, initial: AudioObjectID(0)) ?? 0

if mode == "live-tap" {
    guard #available(macOS 14.2, *), defaultOutputID != 0 else {
        print("{\"error\":\"no_default_output_or_unsupported_macos\"}")
        exit(1)
    }
    let outputUID = readCFString(defaultOutputID, selector: kAudioDevicePropertyDeviceUID) ?? ""
    let outputName = readCFString(defaultOutputID, selector: kAudioObjectPropertyName) ?? ""

    // Spawn tone-child so we have a dedicated, deterministic CoreAudio output process to tap
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    var env = ProcessInfo.processInfo.environment
    env["GLIESE_AUDIO_PROBE_MODE"] = "tone-child"
    child.environment = env
    try child.run()
    let childPID = child.processIdentifier

    var childProcObjID: AudioObjectID = 0
    for _ in 0..<30 {
        Thread.sleep(forTimeInterval: 0.05)
        let objs = readObjectIDArray(systemObject, selector: kAudioHardwarePropertyProcessObjectList)
        if let match = objs.first(where: { (readProperty($0, selector: kAudioProcessPropertyPID, initial: pid_t(0)) ?? 0) == childPID }) {
            let running = (readProperty(match, selector: kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0) != 0
            if running {
                childProcObjID = match
                break
            }
        }
    }

    guard childProcObjID != 0 else {
        child.terminate()
        print("{\"error\":\"tone_child_process_object_not_found\",\"childPID\":\(childPID)}")
        exit(1)
    }

    let tapDesc = CATapDescription(stereoMixdownOfProcesses: [childProcObjID])
    tapDesc.muteBehavior = .mutedWhenTapped
    tapDesc.isPrivate = true

    var tapID: AudioObjectID = 0
    let createTapStatus = AudioHardwareCreateProcessTap(tapDesc, &tapID)

    var tapASBD = AudioStreamBasicDescription()
    let tapFormatRead = readProperty(tapID, selector: kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
    if let tf = tapFormatRead {
        tapASBD = tf
    }

    let aggUID = "com.rymaxw.gliese.spike.\(UUID().uuidString)"
    let aggDict: [String: Any] = [
        kAudioAggregateDeviceNameKey: "Gliese Spike Tap Aggregate",
        kAudioAggregateDeviceUIDKey: aggUID,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceMainSubDeviceKey: outputUID,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
        kAudioAggregateDeviceTapListKey: [[
            kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
            kAudioSubTapDriftCompensationKey: true
        ]],
        kAudioAggregateDeviceTapAutoStartKey: true
    ]

    var aggregateID: AudioObjectID = 0
    let createAggregateStatus = AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggregateID)
    let aggInputStreams = readObjectIDArray(aggregateID, selector: kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
    let aggOutputStreams = readObjectIDArray(aggregateID, selector: kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
    let aggSampleRate = readProperty(aggregateID, selector: kAudioDevicePropertyNominalSampleRate, initial: Float64(0)) ?? 0

    let metrics = ProbeMetricsBox()
    var ioProcID: AudioDeviceIOProcID?
    let createIOProcStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, inInputData, _, outOutputData, _ in
        let inBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        let outBuffers = UnsafeMutableAudioBufferListPointer(outOutputData)
        let g = metrics.currentGain()

        var inPeak: Float = 0.0
        var outPeak: Float = 0.0

        if let srcBuf = inBuffers.first, let srcPtr = srcBuf.mData?.assumingMemoryBound(to: Float.self) {
            let sampleCount = Int(srcBuf.mDataByteSize) / MemoryLayout<Float>.size
            for i in 0..<sampleCount {
                let s = abs(srcPtr[i])
                if s > inPeak { inPeak = s }
            }
            for dstIdx in 0..<outBuffers.count {
                guard let dstPtr = outBuffers[dstIdx].mData?.assumingMemoryBound(to: Float.self) else { continue }
                let dstCount = min(sampleCount, Int(outBuffers[dstIdx].mDataByteSize) / MemoryLayout<Float>.size)
                for i in 0..<dstCount {
                    let v = srcPtr[i] * g
                    dstPtr[i] = v
                    let av = abs(v)
                    if av > outPeak { outPeak = av }
                }
            }
        } else {
            for dstIdx in 0..<outBuffers.count {
                if let dstRaw = outBuffers[dstIdx].mData {
                    memset(dstRaw, 0, Int(outBuffers[dstIdx].mDataByteSize))
                }
            }
        }
        metrics.record(appliedGain: g, inputPeak: inPeak, outputPeak: outPeak)
    }

    let startStatus: OSStatus
    if let ioProcID, createTapStatus == noErr, createAggregateStatus == noErr, createIOProcStatus == noErr {
        startStatus = AudioDeviceStart(aggregateID, ioProcID)
    } else {
        startStatus = -1
    }

    // Phase 1: Unity gain (1.0)
    metrics.setGain(1.0, resetStats: true)
    Thread.sleep(forTimeInterval: 0.35)
    let phase1 = metrics.snapshot()

    // Phase 2: 50% volume slider -> quadratic loudness gain = 0.25
    metrics.setGain(0.25, resetStats: true)
    Thread.sleep(forTimeInterval: 0.35)
    let phase2 = metrics.snapshot()

    // Phase 3: Muted -> gain = 0.0
    metrics.setGain(0.0, resetStats: true)
    Thread.sleep(forTimeInterval: 0.35)
    let phase3 = metrics.snapshot()

    // Phase 4: Clean synchronous teardown
    let stopStatus = (ioProcID != nil && aggregateID != 0) ? AudioDeviceStop(aggregateID, ioProcID) : noErr
    let destroyIOProcStatus = (ioProcID != nil && aggregateID != 0) ? AudioDeviceDestroyIOProcID(aggregateID, ioProcID!) : noErr
    let destroyAggregateStatus = (aggregateID != 0) ? AudioHardwareDestroyAggregateDevice(aggregateID) : noErr
    let destroyTapStatus = (tapID != 0) ? AudioHardwareDestroyProcessTap(tapID) : noErr

    child.terminate()
    child.waitUntilExit()

    let remainingDevices = readObjectIDArray(systemObject, selector: kAudioHardwarePropertyDevices)
    let orphanAggregateRemains = remainingDevices.contains(aggregateID)

    let report: [String: Any] = [
        "mode": "live-tap",
        "outputDeviceName": outputName,
        "outputDeviceUID": outputUID,
        "tappedChildPID": childPID,
        "tappedProcessObjectID": childProcObjID,
        "createTapStatus": createTapStatus,
        "tapFormatSampleRate": tapASBD.mSampleRate,
        "tapFormatChannels": tapASBD.mChannelsPerFrame,
        "createAggregateStatus": createAggregateStatus,
        "aggInputStreamCount": aggInputStreams.count,
        "aggOutputStreamCount": aggOutputStreams.count,
        "aggSampleRate": aggSampleRate,
        "createIOProcStatus": createIOProcStatus,
        "startDeviceStatus": startStatus,
        "phase1UnityGain": phase1,
        "phase2QuadraticHalfVolume": phase2,
        "phase3Muted": phase3,
        "teardown": [
            "stopDeviceStatus": stopStatus,
            "destroyIOProcStatus": destroyIOProcStatus,
            "destroyAggregateStatus": destroyAggregateStatus,
            "destroyTapStatus": destroyTapStatus,
            "orphanAggregateRemains": orphanAggregateRemains
        ]
    ]

    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
       let str = String(data: data, encoding: .utf8) {
        print(str)
    }
    exit(0)
}

let deviceIDs = readObjectIDArray(systemObject, selector: kAudioHardwarePropertyDevices)

var outputDevices: [[String: Any]] = []
for devID in deviceIDs {
    let outChannels = outputChannelCount(devID)
    guard outChannels > 0 else { continue }
    let uid = readCFString(devID, selector: kAudioDevicePropertyDeviceUID) ?? ""
    let name = readCFString(devID, selector: kAudioObjectPropertyName) ?? ""
    let transport = readProperty(devID, selector: kAudioDevicePropertyTransportType, initial: UInt32(0)) ?? 0
    let sampleRate = readProperty(devID, selector: kAudioDevicePropertyNominalSampleRate, initial: Float64(0)) ?? 0
    outputDevices.append([
        "audioObjectID": devID,
        "uid": uid,
        "name": name,
        "outputChannels": outChannels,
        "nominalSampleRate": sampleRate,
        "transportType": transport,
        "isDefaultOutput": devID == defaultOutputID,
        "isDefaultSystemOutput": devID == defaultSystemID
    ])
}

let processObjectIDs = readObjectIDArray(systemObject, selector: kAudioHardwarePropertyProcessObjectList)
var audioProcesses: [[String: Any]] = []
for procObjID in processObjectIDs {
    let pid = readProperty(procObjID, selector: kAudioProcessPropertyPID, initial: pid_t(0)) ?? 0
    let bundleID = readCFString(procObjID, selector: kAudioProcessPropertyBundleID) ?? ""
    let runningOut = (readProperty(procObjID, selector: kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0) != 0
    let runningIn = (readProperty(procObjID, selector: kAudioProcessPropertyIsRunningInput, initial: UInt32(0)) ?? 0) != 0
    let owner = owningRegularApp(for: pid)
    audioProcesses.append([
        "processObjectID": procObjID,
        "pid": pid,
        "bundleID": bundleID,
        "isRunningOutput": runningOut,
        "isRunningInput": runningIn,
        "owningRegularAppPID": owner?.processIdentifier ?? NSNull(),
        "owningRegularAppBundleID": owner?.bundleIdentifier ?? NSNull(),
        "owningRegularAppName": owner?.localizedName ?? NSNull()
    ])
}

let result: [String: Any] = [
    "defaultOutputDeviceObjectID": defaultOutputID,
    "defaultSystemOutputDeviceObjectID": defaultSystemID,
    "outputDeviceCount": outputDevices.count,
    "outputDevices": outputDevices,
    "audioProcessObjectCount": audioProcesses.count,
    "audioProcesses": audioProcesses
]

if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
   let str = String(data: data, encoding: .utf8) {
    print(str)
}
