import Foundation
import Testing
@testable import GlieseCore

@Suite("SystemMetricsCalculator CPU, RAM, Storage & Battery Tests")
struct SystemMetricsCalculatorTests {

    @Test("CPUMeter returns .collecting on first sample, computes normalized delta, and handles counter reset")
    func cpuMeterLifecycle() {
        var meter = CPUMeter()
        let first = meter.record(CPUTickSample(user: 1000, system: 500, idle: 8500, nice: 0))
        #expect(first == .collecting)

        // Second sample: +200 user, +100 system, +700 idle => 30% total usage
        let second = meter.record(CPUTickSample(user: 1200, system: 600, idle: 9200, nice: 0))
        if case .available(let total, let user, let system) = second {
            #expect(abs(total - 30.0) < 0.001)
            #expect(abs(user - 20.0) < 0.001)
            #expect(abs(system - 10.0) < 0.001)
        } else {
            Issue.record("Expected .available")
        }

        // Counter reset after wake (lower tick values) -> re-anchors and returns .collecting
        let reset = meter.record(CPUTickSample(user: 100, system: 50, idle: 850, nice: 0))
        #expect(reset == .collecting)
    }

    @Test("MemorySnapshot uses host pageSizeBytes and never double-counts compressed or cached pages")
    func memoryCalculation() {
        let pageSize: UInt64 = 16384 // 16 KiB on Apple Silicon
        let totalRAM: UInt64 = 8 * 1024 * 1024 * 1024 // 8 GiB

        // 200,000 internal pages (20,000 purgeable) -> 180,000 app pages
        // 60,000 wired pages
        // 22,144 compressor pages
        // Total used pages = 180,000 + 60,000 + 22,144 = 262,144 pages = 4 GiB (50% of 8 GiB)
        let pages = VMPageCounts(
            internalPages: 200_000,
            purgeablePages: 20_000,
            wiredPages: 60_000,
            compressorPages: 22_144,
            externalPages: 80_000,
            freePages: 142_144
        )

        guard let snap = SystemMetricsCalculator.computeMemorySnapshot(
            totalPhysicalBytes: totalRAM,
            pageSizeBytes: pageSize,
            pages: pages
        ) else {
            Issue.record("Expected MemorySnapshot")
            return
        }

        #expect(snap.appMemoryBytes == 180_000 * pageSize)
        #expect(snap.wiredBytes == 60_000 * pageSize)
        #expect(snap.compressedBytes == 22_144 * pageSize)
        #expect(snap.usedBytes == 262_144 * pageSize)
        #expect(snap.cachedFilesBytes == 100_000 * pageSize)
        #expect(abs(snap.usagePercent - 50.0) < 0.01)
    }

    @Test("StorageSnapshot computes usedBytes and clamps availableBytes")
    func storageCalculation() {
        let total: Int64 = 250_000_000_000
        let avail: Int64 = 100_000_000_000
        guard let storage = SystemMetricsCalculator.computeStorageSnapshot(
            totalBytes: total,
            availableBytes: avail,
            includesPurgeableSpace: true
        ) else {
            Issue.record("Expected StorageSnapshot")
            return
        }
        #expect(storage.usedBytes == 150_000_000_000)
        #expect(abs(storage.usagePercent - 60.0) < 0.01)
        #expect(storage.includesPurgeableSpace)
    }
}
