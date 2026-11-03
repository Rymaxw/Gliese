import Combine
import Darwin
import Foundation
import GlieseCore
import IOKit.ps
import SwiftUI

@MainActor
final class GlieseSystemMetricsManager: ObservableObject {
    static let shared = GlieseSystemMetricsManager()

    @Published private(set) var cpuState: CPUMetricState = .collecting
    @Published private(set) var memorySnapshot: MemoryMetricSnapshot?
    @Published private(set) var storageSnapshot: StorageMetricSnapshot?
    @Published private(set) var batterySnapshot: BatteryMetricSnapshot?

    private var cpuMeter = CPUMeter()
    private var sampleTimer: Timer?
    private var initialWarmupTask: Task<Void, Never>?

    private init() {
        sampleOnce()
    }

    func startSampling() {
        sampleOnce()
        if case .collecting = cpuState {
            initialWarmupTask?.cancel()
            initialWarmupTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                self?.sampleCPUOnly()
            }
        }
        guard sampleTimer == nil else { return }
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sampleOnce()
            }
        }
    }

    func stopSampling() {
        initialWarmupTask?.cancel()
        initialWarmupTask = nil
        sampleTimer?.invalidate()
        sampleTimer = nil
    }

    func sampleOnce() {
        sampleCPUOnly()
        memorySnapshot = readMemorySnapshot()
        storageSnapshot = readStorageSnapshot()
        batterySnapshot = readBatterySnapshot()
    }

    private func sampleCPUOnly() {
        if let tickSample = readCPUTickSample() {
            cpuState = cpuMeter.record(tickSample)
        } else {
            cpuState = .unavailable
        }
    }

    // MARK: - Mach / BSD / IOKit Readers (Read-Only)

    private func readCPUTickSample() -> CPUTickSample? {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0

        let kr = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUs,
            &cpuInfo,
            &numCPUInfo
        )
        guard kr == KERN_SUCCESS, let info = cpuInfo else {
            return nil
        }
        defer {
            let deallocSize = vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), deallocSize)
        }

        var totalUser: UInt64 = 0
        var totalSystem: UInt64 = 0
        var totalIdle: UInt64 = 0
        var totalNice: UInt64 = 0

        for i in 0..<Int(numCPUs) {
            let base = Int(CPU_STATE_MAX) * i
            totalUser &+= UInt64(max(0, info[base + Int(CPU_STATE_USER)]))
            totalSystem &+= UInt64(max(0, info[base + Int(CPU_STATE_SYSTEM)]))
            totalIdle &+= UInt64(max(0, info[base + Int(CPU_STATE_IDLE)]))
            totalNice &+= UInt64(max(0, info[base + Int(CPU_STATE_NICE)]))
        }

        return CPUTickSample(
            user: totalUser,
            system: totalSystem,
            idle: totalIdle,
            nice: totalNice
        )
    }

    private func readMemorySnapshot() -> MemoryMetricSnapshot? {
        var physicalMemory: UInt64 = 0
        var memSize = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &physicalMemory, &memSize, nil, 0) == 0,
              physicalMemory > 0 else {
            return nil
        }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let resolvedPageSize = UInt64(pageSize > 0 ? pageSize : 16_384)

        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        let sample = MemoryLoadSample(
            physicalBytes: physicalMemory,
            pageSizeBytes: resolvedPageSize,
            activePages: UInt64(vmStats.active_count),
            wiredPages: UInt64(vmStats.wire_count),
            compressedPages: UInt64(vmStats.compressor_page_count),
            freePages: UInt64(vmStats.free_count),
            inactivePages: UInt64(vmStats.inactive_count)
        )
        return SystemMetricsCalculator.computeMemory(sample)
    }

    private func readStorageSnapshot() -> StorageMetricSnapshot? {
        let rootURL = URL(fileURLWithPath: "/")
        guard let values = try? rootURL.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]),
        let total = values.volumeTotalCapacity, total > 0 else {
            return nil
        }

        let available: Int64
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            available = important
        } else if let regular = values.volumeAvailableCapacity {
            available = Int64(regular)
        } else {
            return nil
        }

        return SystemMetricsCalculator.computeStorage(
            totalBytes: UInt64(total),
            availableBytes: UInt64(max(0, available))
        )
    }

    private func readBatterySnapshot() -> BatteryMetricSnapshot {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let first = list.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, first)?.takeUnretainedValue() as? [String: Any] else {
            return SystemMetricsCalculator.computeBattery(
                hasBattery: false,
                currentCapacity: nil,
                maxCapacity: nil,
                isCharging: false,
                isPluggedIn: true,
                timeToEmptyMinutes: nil,
                timeToFullMinutes: nil
            )
        }

        let currentCap = desc[kIOPSCurrentCapacityKey as String] as? Int
        let maxCap = desc[kIOPSMaxCapacityKey as String] as? Int
        let isCharging = (desc[kIOPSIsChargingKey as String] as? Bool) ?? false
        let powerSourceState = (desc[kIOPSPowerSourceStateKey as String] as? String) ?? ""
        let isPluggedIn = (powerSourceState == kIOPSACPowerValue)
        let timeToEmpty = desc[kIOPSTimeToEmptyKey as String] as? Int
        let timeToFull = desc[kIOPSTimeToFullChargeKey as String] as? Int

        return SystemMetricsCalculator.computeBattery(
            hasBattery: true,
            currentCapacity: currentCap,
            maxCapacity: maxCap,
            isCharging: isCharging,
            isPluggedIn: isPluggedIn,
            timeToEmptyMinutes: timeToEmpty,
            timeToFullMinutes: timeToFull
        )
    }
}

// MARK: - Notch Read-Only System Telemetry View

struct GlieseSystemView: View {
    @ObservedObject var metrics = GlieseSystemMetricsManager.shared

    var body: some View {
        HStack(spacing: 8) {
            cpuCard
            memoryCard
            storageCard
            batteryCard
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .onAppear {
            metrics.startSampling()
        }
        .onDisappear {
            metrics.stopSampling()
        }
    }

    private var cpuCard: some View {
        metricCard(title: "CPU", icon: "cpu") {
            switch metrics.cpuState {
            case .collecting:
                Text("Sampling…")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                Text("Delta tick window")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.45))
            case .available(let total, let user, let sys):
                Text(String(format: "%.1f%%", total))
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                ProgressView(value: min(max(total, 0), 100), total: 100)
                    .controlSize(.small)
                Text(String(format: "U %.0f%% · S %.0f%%", user, sys))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            case .unavailable:
                Text("N/A")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private var memoryCard: some View {
        metricCard(title: "Memory", icon: "memorychip") {
            if let mem = metrics.memorySnapshot {
                Text(String(format: "%.0f%%", mem.usagePercent))
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(pressureColor(mem.pressureLevel))
                ProgressView(value: min(max(mem.usagePercent, 0), 100), total: 100)
                    .controlSize(.small)
                Text("\(formatGiB(mem.usedBytes)) / \(formatGiB(mem.totalBytes))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                Text("N/A")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private var storageCard: some View {
        metricCard(title: "Storage", icon: "internaldrive") {
            if let disk = metrics.storageSnapshot {
                Text(String(format: "%.0f%%", disk.usagePercent))
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                ProgressView(value: min(max(disk.usagePercent, 0), 100), total: 100)
                    .controlSize(.small)
                Text("\(formatGB(disk.availableBytes)) free")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                Text("N/A")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private var batteryCard: some View {
        metricCard(title: "Power", icon: "bolt.batteryblock") {
            if let bat = metrics.batterySnapshot {
                if let pct = bat.percentage {
                    Text("\(pct)%")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundStyle(bat.isCharging ? .green : .white)
                    ProgressView(value: Double(min(max(pct, 0), 100)), total: 100)
                        .controlSize(.small)
                } else {
                    Text("AC Power")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text(bat.statusLabel)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            } else {
                Text("N/A")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func metricCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
            }
            Spacer(minLength: 0)
            content()
        }
        .padding(9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func pressureColor(_ level: MemoryMetricSnapshot.PressureLevel) -> Color {
        switch level {
        case .normal: return .white
        case .elevated: return .yellow
        case .critical: return .red
        }
    }

    private func formatGiB(_ bytes: UInt64) -> String {
        let gib = Double(bytes) / 1_073_741_824.0
        return String(format: "%.1fG", gib)
    }

    private func formatGB(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_000_000_000.0
        return String(format: "%.0f GB", gb)
    }
}
