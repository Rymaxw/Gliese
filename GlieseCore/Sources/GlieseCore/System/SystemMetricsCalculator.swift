import Foundation

public struct CPUTickSample: Equatable, Sendable {
    public let user: UInt64
    public let system: UInt64
    public let idle: UInt64
    public let nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

public enum CPUMetricState: Equatable, Sendable {
    case collecting
    case available(totalUsagePercent: Double, userPercent: Double, systemPercent: Double)
    case unavailable
}

public struct CPUMeter: Sendable {
    private var previousSample: CPUTickSample?

    public init() {}

    public mutating func reset() {
        previousSample = nil
    }

    public mutating func record(_ sample: CPUTickSample) -> CPUMetricState {
        guard let prev = previousSample else {
            previousSample = sample
            return .collecting
        }

        // Handle counter reset or wrap after sleep/wake by re-anchoring baseline
        guard sample.user >= prev.user,
              sample.system >= prev.system,
              sample.idle >= prev.idle,
              sample.nice >= prev.nice else {
            previousSample = sample
            return .collecting
        }

        let dUser = sample.user - prev.user
        let dSystem = sample.system - prev.system
        let dIdle = sample.idle - prev.idle
        let dNice = sample.nice - prev.nice
        let totalTicks = dUser + dSystem + dIdle + dNice

        guard totalTicks > 0 else {
            return .collecting
        }

        previousSample = sample
        let activeTicks = dUser + dSystem + dNice
        let totalPct = min(100.0, max(0.0, (Double(activeTicks) / Double(totalTicks)) * 100.0))
        let userPct = min(100.0, max(0.0, (Double(dUser + dNice) / Double(totalTicks)) * 100.0))
        let sysPct = min(100.0, max(0.0, (Double(dSystem) / Double(totalTicks)) * 100.0))
        return .available(totalUsagePercent: totalPct, userPercent: userPct, systemPercent: sysPct)
    }
}

public struct VMPageCounts: Equatable, Sendable {
    public let internalPages: UInt64
    public let purgeablePages: UInt64
    public let wiredPages: UInt64
    public let compressorPages: UInt64
    public let externalPages: UInt64
    public let freePages: UInt64

    public init(
        internalPages: UInt64,
        purgeablePages: UInt64,
        wiredPages: UInt64,
        compressorPages: UInt64,
        externalPages: UInt64,
        freePages: UInt64
    ) {
        self.internalPages = internalPages
        self.purgeablePages = purgeablePages
        self.wiredPages = wiredPages
        self.compressorPages = compressorPages
        self.externalPages = externalPages
        self.freePages = freePages
    }
}

public struct MemorySnapshot: Equatable, Sendable {
    /// Activity Monitor-aligned breakdown:
    /// `usedBytes = appMemoryBytes + wiredBytes + compressedBytes`
    /// where `appMemoryBytes = max(0, internalPages - purgeablePages) * pageSizeBytes`.
    public let totalPhysicalBytes: UInt64
    public let usedBytes: UInt64
    public let appMemoryBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let cachedFilesBytes: UInt64
    public let usagePercent: Double

    public init(
        totalPhysicalBytes: UInt64,
        usedBytes: UInt64,
        appMemoryBytes: UInt64,
        wiredBytes: UInt64,
        compressedBytes: UInt64,
        cachedFilesBytes: UInt64,
        usagePercent: Double
    ) {
        self.totalPhysicalBytes = totalPhysicalBytes
        self.usedBytes = usedBytes
        self.appMemoryBytes = appMemoryBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.cachedFilesBytes = cachedFilesBytes
        self.usagePercent = usagePercent
    }
}

public struct StorageSnapshot: Equatable, Sendable {
    public let totalBytes: UInt64
    public let availableBytes: UInt64
    public let usedBytes: UInt64
    public let usagePercent: Double
    public let includesPurgeableSpace: Bool

    public init(
        totalBytes: UInt64,
        availableBytes: UInt64,
        usedBytes: UInt64,
        usagePercent: Double,
        includesPurgeableSpace: Bool
    ) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.usedBytes = usedBytes
        self.usagePercent = usagePercent
        self.includesPurgeableSpace = includesPurgeableSpace
    }
}

public struct MemoryLoadSample: Equatable, Sendable {
    public let physicalBytes: UInt64
    public let pageSizeBytes: UInt64
    public let activePages: UInt64
    public let wiredPages: UInt64
    public let compressedPages: UInt64
    public let freePages: UInt64
    public let inactivePages: UInt64

    public init(
        physicalBytes: UInt64,
        pageSizeBytes: UInt64,
        activePages: UInt64,
        wiredPages: UInt64,
        compressedPages: UInt64,
        freePages: UInt64,
        inactivePages: UInt64
    ) {
        self.physicalBytes = physicalBytes
        self.pageSizeBytes = pageSizeBytes
        self.activePages = activePages
        self.wiredPages = wiredPages
        self.compressedPages = compressedPages
        self.freePages = freePages
        self.inactivePages = inactivePages
    }
}

public struct MemoryMetricSnapshot: Equatable, Sendable {
    public enum PressureLevel: Equatable, Sendable {
        case normal
        case elevated
        case critical
    }

    public let totalBytes: UInt64
    public let usedBytes: UInt64
    public let appMemoryBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let usagePercent: Double
    public let pressureLevel: PressureLevel

    public init(
        totalBytes: UInt64,
        usedBytes: UInt64,
        appMemoryBytes: UInt64,
        wiredBytes: UInt64,
        compressedBytes: UInt64,
        usagePercent: Double,
        pressureLevel: PressureLevel
    ) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.appMemoryBytes = appMemoryBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.usagePercent = usagePercent
        self.pressureLevel = pressureLevel
    }
}

public struct StorageMetricSnapshot: Equatable, Sendable {
    public let totalBytes: UInt64
    public let availableBytes: UInt64
    public let usedBytes: UInt64
    public let usagePercent: Double

    public init(totalBytes: UInt64, availableBytes: UInt64, usedBytes: UInt64, usagePercent: Double) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.usedBytes = usedBytes
        self.usagePercent = usagePercent
    }
}

public struct BatteryMetricSnapshot: Equatable, Sendable {
    public let hasBattery: Bool
    public let percentage: Int?
    public let isCharging: Bool
    public let isPluggedIn: Bool
    public let statusLabel: String

    public init(
        hasBattery: Bool,
        percentage: Int?,
        isCharging: Bool,
        isPluggedIn: Bool,
        statusLabel: String
    ) {
        self.hasBattery = hasBattery
        self.percentage = percentage
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.statusLabel = statusLabel
    }
}

public enum BatteryMetricState: Equatable, Sendable {
    case present(percentage: Int, isCharging: Bool, isPluggedIn: Bool)
    case noBattery
    case unavailable
}

public enum SystemMetricsCalculator {
    public static func computeMemorySnapshot(
        totalPhysicalBytes: UInt64,
        pageSizeBytes: UInt64,
        pages: VMPageCounts
    ) -> MemorySnapshot? {
        guard totalPhysicalBytes > 0, pageSizeBytes > 0 else { return nil }

        let appPages = pages.internalPages > pages.purgeablePages
            ? (pages.internalPages - pages.purgeablePages)
            : 0
        let appBytes = appPages &* pageSizeBytes
        let wiredBytes = pages.wiredPages &* pageSizeBytes
        let compressedBytes = pages.compressorPages &* pageSizeBytes
        let rawUsed = appBytes &+ wiredBytes &+ compressedBytes
        let usedBytes = min(totalPhysicalBytes, rawUsed)
        let cachedBytes = (pages.purgeablePages &+ pages.externalPages) &* pageSizeBytes
        let pct = min(100.0, max(0.0, (Double(usedBytes) / Double(totalPhysicalBytes)) * 100.0))

        return MemorySnapshot(
            totalPhysicalBytes: totalPhysicalBytes,
            usedBytes: usedBytes,
            appMemoryBytes: appBytes,
            wiredBytes: wiredBytes,
            compressedBytes: compressedBytes,
            cachedFilesBytes: cachedBytes,
            usagePercent: pct
        )
    }

    public static func computeStorageSnapshot(
        totalBytes: Int64,
        availableBytes: Int64,
        includesPurgeableSpace: Bool
    ) -> StorageSnapshot? {
        guard totalBytes > 0, availableBytes >= 0 else { return nil }
        let total = UInt64(totalBytes)
        let avail = min(total, UInt64(availableBytes))
        let used = total - avail
        let pct = min(100.0, max(0.0, (Double(used) / Double(total)) * 100.0))
        return StorageSnapshot(
            totalBytes: total,
            availableBytes: avail,
            usedBytes: used,
            usagePercent: pct,
            includesPurgeableSpace: includesPurgeableSpace
        )
    }

    public static func computeMemory(_ sample: MemoryLoadSample) -> MemoryMetricSnapshot? {
        guard sample.physicalBytes > 0, sample.pageSizeBytes > 0 else { return nil }
        let appBytes = sample.activePages &* sample.pageSizeBytes
        let wiredBytes = sample.wiredPages &* sample.pageSizeBytes
        let compressedBytes = sample.compressedPages &* sample.pageSizeBytes
        let rawUsed = appBytes &+ wiredBytes &+ compressedBytes
        let used = min(sample.physicalBytes, rawUsed)
        let pct = min(100.0, max(0.0, (Double(used) / Double(sample.physicalBytes)) * 100.0))

        let pressure: MemoryMetricSnapshot.PressureLevel
        if pct >= 85.0 {
            pressure = .critical
        } else if pct >= 70.0 {
            pressure = .elevated
        } else {
            pressure = .normal
        }

        return MemoryMetricSnapshot(
            totalBytes: sample.physicalBytes,
            usedBytes: used,
            appMemoryBytes: appBytes,
            wiredBytes: wiredBytes,
            compressedBytes: compressedBytes,
            usagePercent: pct,
            pressureLevel: pressure
        )
    }

    public static func computeStorage(totalBytes: UInt64, availableBytes: UInt64) -> StorageMetricSnapshot? {
        guard totalBytes > 0 else { return nil }
        let avail = min(totalBytes, availableBytes)
        let used = totalBytes - avail
        let pct = min(100.0, max(0.0, (Double(used) / Double(totalBytes)) * 100.0))
        return StorageMetricSnapshot(
            totalBytes: totalBytes,
            availableBytes: avail,
            usedBytes: used,
            usagePercent: pct
        )
    }

    public static func computeBattery(
        hasBattery: Bool,
        currentCapacity: Int?,
        maxCapacity: Int?,
        isCharging: Bool,
        isPluggedIn: Bool,
        timeToEmptyMinutes: Int?,
        timeToFullMinutes: Int?
    ) -> BatteryMetricSnapshot {
        guard hasBattery, let current = currentCapacity, let maxCap = maxCapacity, maxCap > 0 else {
            return BatteryMetricSnapshot(
                hasBattery: false,
                percentage: nil,
                isCharging: false,
                isPluggedIn: isPluggedIn,
                statusLabel: isPluggedIn ? "Power Adapter" : "No Battery"
            )
        }

        let computed = Int((Double(current) / Double(maxCap)) * 100.0)
        let pct = min(100, max(0, computed))
        let label: String
        if isCharging {
            if let fullMin = timeToFullMinutes, fullMin > 0 {
                label = "\(fullMin)m until full"
            } else {
                label = "Charging"
            }
        } else if isPluggedIn {
            label = "Fully Charged"
        } else if let emptyMin = timeToEmptyMinutes, emptyMin > 0 {
            let h = emptyMin / 60
            let m = emptyMin % 60
            label = h > 0 ? "\(h)h \(m)m remaining" : "\(m)m remaining"
        } else {
            label = "Discharging"
        }

        return BatteryMetricSnapshot(
            hasBattery: true,
            percentage: pct,
            isCharging: isCharging,
            isPluggedIn: isPluggedIn,
            statusLabel: label
        )
    }
}
