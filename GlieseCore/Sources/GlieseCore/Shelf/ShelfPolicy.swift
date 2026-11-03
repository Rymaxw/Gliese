import Foundation

public struct ShelfReferenceRecord: Equatable, Identifiable, Sendable {
    public enum Availability: String, Equatable, Sendable {
        case available
        case missingOrUnmounted
    }

    public let id: UUID
    public let canonicalFilePath: String
    public let displayName: String
    public let createdAt: Date
    public var availability: Availability

    public init(
        id: UUID = UUID(),
        canonicalFilePath: String,
        displayName: String,
        createdAt: Date = Date(),
        availability: Availability = .available
    ) {
        self.id = id
        self.canonicalFilePath = canonicalFilePath
        self.displayName = displayName
        self.createdAt = createdAt
        self.availability = availability
    }
}

public enum ShelfPolicy {
    public static let defaultMaxItems = 100

    public enum AddDecision: Equatable, Sendable {
        case added(ShelfReferenceRecord)
        case duplicateExisting(UUID)
        case rejectedNotFileURL
        case rejectedCapReached(maxItems: Int)
    }

    /// Normalizes a file URL using `.standardizedFileURL` (resolving `..` and `.` without following symlinks or reading file contents).
    public static func canonicalFilePath(for url: URL) -> String? {
        guard url.isFileURL else { return nil }
        let path = url.standardizedFileURL.path
        guard !path.isEmpty, path != "/" else { return nil }
        return path
    }

    public static func evaluateAdd(
        url: URL,
        existing: [ShelfReferenceRecord],
        maxItems: Int = ShelfPolicy.defaultMaxItems,
        now: Date = Date()
    ) -> AddDecision {
        guard let canonicalPath = canonicalFilePath(for: url) else {
            return .rejectedNotFileURL
        }
        if let match = existing.first(where: { $0.canonicalFilePath == canonicalPath }) {
            return .duplicateExisting(match.id)
        }
        guard existing.count < maxItems else {
            return .rejectedCapReached(maxItems: maxItems)
        }
        let name = url.lastPathComponent.isEmpty ? canonicalPath : url.lastPathComponent
        let record = ShelfReferenceRecord(
            canonicalFilePath: canonicalPath,
            displayName: name,
            createdAt: now,
            availability: .available
        )
        return .added(record)
    }
}
